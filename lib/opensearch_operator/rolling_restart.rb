# frozen_string_literal: true

class OpensearchOperator
  # Restarts OpenSearch pods one at a time, gated on cluster health.
  #
  # The StatefulSet uses the OnDelete update strategy, so Kubernetes never restarts pods on its own when
  # the pod template changes. The built in RollingUpdate strategy only waits for pod readiness before
  # moving on to the next pod, and readiness merely means the node process is up. Shard recovery is
  # typically still in progress at that point (cluster yellow) and terminating the next pod can leave
  # shards without any live copy (cluster red).
  #
  # The logic is level triggered: every tick re-reads the StatefulSet, the pods and the cluster health
  # and derives the single next action from that. This way it survives operator restarts, spec changes
  # mid rollout and manually deleted pods without relying on persisted state.
  #
  # Rollout procedure per pod, following https://docs.opensearch.org/latest/migrate-or-upgrade/rolling-upgrade/
  # 1. Wait for all pods to be ready and all nodes to have joined the cluster
  # 2. Re-enable replica shard allocation in case it was disabled by a previous step
  # 3. Wait for green cluster health (see YELLOW_TOLERANCE for the exception)
  # 4. Disable replica shard allocation, flush, delete the pod (highest ordinal first, cluster manager last)
  class RollingRestart
    # How long to tolerate a yellow cluster before restarting the next pod anyway. Only applies when no
    # shard recovery is in flight, ie. the remaining unassigned shards are stuck for reasons that won't
    # resolve by waiting (exhausted allocation retries, more replicas than nodes, shard handling bugs).
    # Recovering shards always block the rollout since restarting another node could turn the cluster red.
    YELLOW_TOLERANCE = 5.minutes

    ALLOCATION_SETTING = "cluster.routing.allocation.enable"

    def initialize(cluster, client)
      @cluster = cluster
      @client = client
      @in_progress = false
      @waiting_for_green_since = nil
      @blocked_by_red_reported = false
    end

    def tick(health, nodes)
      statefulset = Kubernetes.statefulsets.get(@cluster.statefulset_name, namespace: @cluster.namespace)
      return if statefulset["code"] == 404

      # The StatefulSet controller hasn't processed the latest spec yet, updateRevision could be stale
      return if statefulset.dig("status", "observedGeneration") != statefulset.dig("metadata", "generation")

      replicas = statefulset.dig("spec", "replicas")
      update_revision = statefulset.dig("status", "updateRevision")

      # NOTE: The cluster label alone also matches the dashboards pods, hence the additional name label
      pods = Kubernetes.pods.list(
        namespace: @cluster.namespace,
        params: { labelSelector: "app.kubernetes.io/name=opensearch,opensearch.reclaim-the-stack.com/cluster=#{@cluster.name}" },
      ).fetch("items")

      stale_pods = pods.reject { |pod| pod.dig("metadata", "labels", "controller-revision-hash") == update_revision }

      expected_pod_names = (0...replicas).map { |ordinal| "#{@cluster.statefulset_name}-#{ordinal}" }
      unavailable_pod_names = expected_pod_names - pods.map { |pod| pod.dig("metadata", "name") }
      unavailable_pod_names += pods.select do |pod|
        ready = pod.dig("status", "conditions").to_a.any? { |condition| condition["type"] == "Ready" && condition["status"] == "True" }
        pod.dig("metadata", "deletionTimestamp") || !ready
      end.map { |pod| pod.dig("metadata", "name") }

      all_nodes_present = unavailable_pod_names.empty? && health.fetch("number_of_nodes") == replicas

      if stale_pods.any? && !@in_progress
        @in_progress = true
        stale_revisions = stale_pods.map { |pod| pod.dig("metadata", "labels", "controller-revision-hash") }.uniq.join(", ")
        @cluster.emit_event(
          "RollingRestartStarted",
          "#{stale_pods.size} of #{replicas} pods need to be restarted to go from StatefulSet revision #{stale_revisions} to #{update_revision}",
        )
      end

      unless all_nodes_present
        if @in_progress
          waiting_for = unavailable_pod_names.any? ? unavailable_pod_names.sort.join(", ") : "#{health.fetch('number_of_nodes')}/#{replicas} nodes"
          @cluster.update_phase("Rolling restart: waiting for #{waiting_for} to join the cluster (#{stale_pods.size} pods remaining)")
        end
        return
      end

      # All nodes are present so shard allocation must not remain disabled, regardless of how it got disabled
      # (eg. operator crash after deleting a pod).
      settings = @client.cluster.get_settings(flat_settings: true)
      if settings.dig("persistent", ALLOCATION_SETTING) == "primaries"
        @client.cluster.put_settings(body: { persistent: { ALLOCATION_SETTING => nil } })
        LOGGER.info "Re-enabled replica shard allocation for #{@cluster.namespace}/#{@cluster.name}"
      end

      if stale_pods.empty? && !@in_progress
        @waiting_for_green_since = nil
        @blocked_by_red_reported = false
        @cluster.update_phase("Running")
        return
      end

      status = health.fetch("status")

      if status == "red"
        unless @blocked_by_red_reported
          @blocked_by_red_reported = true
          @cluster.emit_event(
            "RollingRestartBlocked",
            "Cluster health is red (#{health.fetch('unassigned_shards')} unassigned shards), not restarting any more pods until primaries are assigned",
            type: "Warning",
          )
        end
        @cluster.update_phase("Rolling restart: blocked by red cluster health (#{stale_pods.size} pods remaining)")
        return
      end
      @blocked_by_red_reported = false

      if status == "yellow"
        @waiting_for_green_since ||= Time.now
        waited = Time.now - @waiting_for_green_since
        recovering = health.fetch("initializing_shards") + health.fetch("relocating_shards") + health.fetch("delayed_unassigned_shards")

        if recovering.positive? || waited < YELLOW_TOLERANCE
          @cluster.update_phase(
            "Rolling restart: waiting for green cluster health (#{health.fetch('unassigned_shards')} unassigned, " \
            "#{health.fetch('initializing_shards')} initializing, #{health.fetch('relocating_shards')} relocating shards, " \
            "#{stale_pods.size} pods remaining)",
          )
          return
        end

        @cluster.emit_event(
          "RollingRestartProceedingOnYellow",
          "Cluster health has been yellow for #{waited.round} seconds with #{health.fetch('unassigned_shards')} unassigned shards " \
          "and no shard recovery in progress, continuing the rolling restart anyway",
          type: "Warning",
        )
      end
      @waiting_for_green_since = nil

      if stale_pods.empty?
        @in_progress = false
        @cluster.emit_event(
          "RollingRestartCompleted",
          "All #{replicas} pods are running StatefulSet revision #{update_revision}, cluster health is #{status}",
        )
        @cluster.update_phase("Running")
        return
      end

      # Restart highest ordinal first, cluster manager last, to minimize the number of cluster manager elections
      cluster_manager = nodes.find { |node| node["cluster_manager"] == "*" }&.fetch("name")
      pod = stale_pods.min_by do |candidate|
        candidate_name = candidate.dig("metadata", "name")
        candidate_name == cluster_manager ? [1, 0] : [0, -candidate_name.split("-").last.to_i]
      end
      pod_name = pod.dig("metadata", "name")
      pod_revision = pod.dig("metadata", "labels", "controller-revision-hash")

      # Prevents the cluster from rebuilding replicas elsewhere while the node is down (default delay is 1 minute
      # and a pod restart takes longer than that). The returning node recovers its replicas from local disk instead.
      @client.cluster.put_settings(body: { persistent: { ALLOCATION_SETTING => "primaries" } })
      # Not strictly required (OpenSearch flushes on graceful shutdown) but optimizes terminate -> recovery, same as ECK does
      @client.indices.flush
      Kubernetes.pods.delete(pod_name, namespace: @cluster.namespace)

      remaining = stale_pods.size - 1
      @cluster.emit_event(
        "PodRestarted",
        "Deleted pod #{pod_name} (revision #{pod_revision}) after disabling replica shard allocation and flushing, " \
        "#{remaining} pods remaining#{pod_name == cluster_manager ? ' (this was the cluster manager)' : ''}",
      )
      @cluster.update_phase("Rolling restart: restarting #{pod_name} (#{remaining} pods remaining)")
    end
  end
end
