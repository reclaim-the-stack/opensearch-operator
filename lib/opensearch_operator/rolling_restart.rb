# frozen_string_literal: true

class OpensearchOperator
  # Restarts OpenSearch pods one at a time, gated on cluster health, and scales the StatefulSet up and down safely.
  #
  # The StatefulSet uses the OnDelete update strategy, so Kubernetes never restarts pods on its own when
  # the pod template changes. The built in RollingUpdate strategy only waits for pod readiness before
  # moving on to the next pod, and readiness merely means the node process is up. Shard recovery is
  # typically still in progress at that point (cluster yellow) and terminating the next pod can leave
  # shards without any live copy (cluster red).
  #
  # Lowering the StatefulSet replicas right away would be even worse: the Parallel pod management policy
  # terminates all leaving pods at once and the whenScaled: Delete retention policy deletes their volumes,
  # losing every shard that only had copies on the leaving nodes, as well as the cluster manager quorum when
  # half or more of the voting nodes leave. Hence the StatefulSet replicas are only ever changed here, once the
  # leaving nodes have handed off their shards and cluster manager votes. Cluster#ensure_statefulset keeps the
  # current replicas of an existing StatefulSet.
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
  #
  # Scale down procedure, which takes precedence over rollouts since restarting leaving pods is wasted effort
  # 1. Wait for the remaining nodes to be part of the cluster. The leaving nodes (highest ordinals) don't have to be,
  #    eg. pods of a scale up which never got scheduled or a pod stuck on a dead Kubernetes node.
  # 2. Exclude the leaving nodes from shard allocation and wait for the cluster state to show no shards on them
  # 3. Unless a primary shard is unassigned, exclude up to MAX_VOTING_CONFIG_EXCLUSIONS leaving nodes from the voting
  #    configuration and lower the StatefulSet replicas accordingly, repeating until the spec replicas are reached
  # 4. Once the removed nodes have left the cluster, clear the allocation and voting configuration exclusions
  class RollingRestart
    # How long to tolerate a yellow cluster before restarting the next pod anyway. Only applies when no
    # shard recovery is in flight, ie. the remaining unassigned shards are stuck for reasons that won't
    # resolve by waiting (exhausted allocation retries, more replicas than nodes, shard handling bugs).
    # Recovering shards always block the rollout since restarting another node could turn the cluster red.
    YELLOW_TOLERANCE = 5.minutes

    # OpenSearch's default cluster.max_voting_config_exclusions, larger scale downs remove the nodes in steps
    MAX_VOTING_CONFIG_EXCLUSIONS = 10

    ALLOCATION_SETTING = "cluster.routing.allocation.enable"
    # NOTE: Managed by the scale down procedure, node names excluded by hand get cleared
    EXCLUDE_SETTING = "cluster.routing.allocation.exclude._name"

    def initialize(cluster, client)
      @cluster = cluster
      @client = client
      @in_progress = false
      @settings_verified = false
      @waiting_for_green_since = nil
      @blocked_by_red_reported = false
      @scale_down = nil # :started, then :removed_pods once the StatefulSet replicas have been lowered
    end

    # Returns true when the cluster is settled, ie. no rollout or scaling is pending and health is green
    def tick(health, nodes)
      statefulset = Kubernetes.statefulsets.get!(@cluster.statefulset_name, namespace: @cluster.namespace)

      # The StatefulSet controller hasn't processed the latest spec yet, updateRevision could be stale
      return false if statefulset.dig("status", "observedGeneration") != statefulset.dig("metadata", "generation")

      replicas = statefulset.dig("spec", "replicas")
      # Read once since the spec can change mid tick, the replicas we scale down to must match the nodes we drained
      desired_replicas = @cluster.replicas
      update_revision = statefulset.dig("status", "updateRevision")

      # Adding nodes is safe right away, unlike removing them
      if desired_replicas > replicas
        Kubernetes.statefulsets.patch(
          @cluster.statefulset_name,
          namespace: @cluster.namespace,
          params: { spec: { replicas: desired_replicas } },
        )
        @cluster.emit_event("ScaleUp", "Scaling the StatefulSet up from #{replicas} to #{desired_replicas} pods")
        @cluster.update_phase("Scaling up from #{replicas} to #{desired_replicas} pods")
        return false
      end

      expected_pod_names = (0...replicas).map { |ordinal| "#{@cluster.statefulset_name}-#{ordinal}" }
      # A scale down removes the highest ordinals
      remaining_pod_names = expected_pod_names.first(desired_replicas)
      leaving_pod_names = expected_pod_names.drop(desired_replicas)

      # NOTE: The cluster label alone also matches the dashboards pods, hence the additional name label
      # Pods beyond the StatefulSet replicas are left over from a scale down step
      pods, removed_pods = Kubernetes.pods.list(
        namespace: @cluster.namespace,
        params: { labelSelector: "app.kubernetes.io/name=opensearch,opensearch.reclaim-the-stack.com/cluster=#{@cluster.name}" },
      ).fetch("items").partition { |pod| expected_pod_names.include?(pod.dig("metadata", "name")) }
      pod_names = pods.map { |pod| pod.dig("metadata", "name") }
      joined_node_names = nodes.map { |node| node.fetch("name") }
      # Removed pods only matter while their nodes are part of the cluster, eg. a pod on a dead Kubernetes node remains
      # terminating until the Kubernetes node is deleted
      removed_node_names = removed_pods.map { |pod| pod.dig("metadata", "name") } & joined_node_names

      # Leaving pods are removed rather than restarted
      stale_pods = pods.select do |pod|
        remaining_pod_names.include?(pod.dig("metadata", "name")) &&
          pod.dig("metadata", "labels", "controller-revision-hash") != update_revision
      end

      unavailable_pod_names = expected_pod_names - pod_names
      unavailable_pod_names += pods.select do |pod|
        ready = pod.dig("status", "conditions").to_a.any? { |condition| condition["type"] == "Ready" && condition["status"] == "True" }
        pod.dig("metadata", "deletionTimestamp") || !ready
      end.map { |pod| pod.dig("metadata", "name") }

      if stale_pods.any? && !@in_progress
        @in_progress = true
        stale_revisions = stale_pods.map { |pod| pod.dig("metadata", "labels", "controller-revision-hash") }.uniq.join(", ")
        @cluster.emit_event(
          "RollingRestartStarted",
          "#{stale_pods.size} of #{remaining_pod_names.size} pods need to be restarted to go from StatefulSet revision " \
          "#{stale_revisions} to #{update_revision}",
        )
      end

      # Their voting configuration exclusions get cleared by the next scale down step, or once the scale down is done
      if removed_node_names.any?
        @cluster.update_phase("Scaling down: waiting for #{removed_node_names.sort.join(', ')} to leave the cluster")
        return false
      end

      if leaving_pod_names.any?
        # The rollout picks up again once the scale down is done, the yellow tolerance must start counting afresh then
        @waiting_for_green_since = nil
        leaving_names = leaving_pod_names.join(", ")

        # The remaining nodes take over the shards and the cluster manager votes of the leaving ones
        waiting_for_pod_names = remaining_pod_names & (unavailable_pod_names | (remaining_pod_names - joined_node_names))
        if waiting_for_pod_names.any?
          @cluster.update_phase("Scaling down: waiting for #{waiting_for_pod_names.sort.join(', ')} to join the cluster")
          return false
        end

        unless @scale_down
          @scale_down = :started
          @cluster.emit_event(
            "ScaleDownStarted",
            "Migrating shards off #{leaving_names} before scaling down from #{replicas} to #{desired_replicas} pods",
          )
        end

        settings = @client.cluster.get_settings(flat_settings: true)
        # Shards can't migrate while replica allocation is disabled, eg. by an operator crash in the middle of a rollout step
        if settings.dig("persistent", ALLOCATION_SETTING) == "primaries"
          @client.cluster.put_settings(body: { persistent: { ALLOCATION_SETTING => nil } })
          LOGGER.info "Re-enabled replica shard allocation for #{@cluster.namespace}/#{@cluster.name}"
        end
        # NOTE: A transient value would take precedence over the persistent one
        excluded_node_names = leaving_pod_names.join(",")
        if settings.dig("persistent", EXCLUDE_SETTING) != excluded_node_names || settings.dig("transient", EXCLUDE_SETTING)
          @client.cluster.put_settings(
            body: { persistent: { EXCLUDE_SETTING => excluded_node_names }, transient: { EXCLUDE_SETTING => nil } },
          )
        end

        # The cluster state is authoritative, unlike eg. _cat/allocation which leaves out nodes failing to respond to its
        # node stats requests. Taking a node missing from the response for an empty one would delete its shards along
        # with its volume.
        cluster_state = @client.cluster.state(
          metric: "nodes,routing_nodes",
          filter_path: "nodes.*.name,routing_nodes.nodes.*.state,routing_nodes.unassigned.primary",
        )
        # Includes shards relocating to or from the leaving nodes, nodes which have left the cluster hold no shards
        shards_on_leaving_nodes = cluster_state.fetch("nodes")
          .select { |_node_id, node| leaving_pod_names.include?(node.fetch("name")) }
          .sum { |node_id, _node| cluster_state.dig("routing_nodes", "nodes", node_id).to_a.size }
        unassigned_primaries = cluster_state.dig("routing_nodes", "unassigned").to_a.count { |shard| shard.fetch("primary") }

        if shards_on_leaving_nodes.positive?
          @cluster.update_phase("Scaling down: migrating #{shards_on_leaving_nodes} shards off #{leaving_names}")
          return false
        end

        # Recovering them might require shard data which only remains on the leaving nodes, eg. one which went down
        if unassigned_primaries.positive?
          @cluster.update_phase(
            "Scaling down: blocked by #{unassigned_primaries} unassigned primary shards, keeping #{leaving_names}",
          )
          return false
        end

        removing_pod_names = leaving_pod_names.last(MAX_VOTING_CONFIG_EXCLUSIONS)
        removing_names = removing_pod_names.join(", ")
        scaled_down_replicas = replicas - removing_pod_names.size
        @cluster.update_phase("Scaling down: removing #{removing_names} from the voting configuration")
        # Exclusions of nodes removed by a previous step count towards the limit
        @client.cluster.delete_voting_config_exclusions(wait_for_removal: false)
        # Blocks until the nodes are out of the voting configuration so removing them can't cost the cluster its quorum
        @client.cluster.post_voting_config_exclusions(node_names: removing_pod_names)
        Kubernetes.statefulsets.patch(
          @cluster.statefulset_name,
          namespace: @cluster.namespace,
          params: { spec: { replicas: scaled_down_replicas } },
        )
        @scale_down = :removed_pods
        @cluster.emit_event(
          "ScaleDownRemovingPods",
          "Scaling the StatefulSet down from #{replicas} to #{scaled_down_replicas} pods after migrating all shards off " \
          "#{removing_names} and excluding them from the voting configuration",
        )
        @cluster.update_phase("Scaling down: removing #{removing_names}")
        return false
      end

      all_nodes_present = unavailable_pod_names.empty? && health.fetch("number_of_nodes") == replicas

      unless all_nodes_present
        # A stale pod which is the only unavailable one and whose node has left the cluster (crashlooping, unschedulable,
        # on a dead node) can't be waited for, and a corrected spec can only take effect by recreating it.
        stuck_pod = stale_pods.find do |pod|
          unavailable_pod_names == [pod.dig("metadata", "name")] &&
            pod.dig("metadata", "deletionTimestamp").nil? &&
            health.fetch("number_of_nodes") < replicas
        end

        if stuck_pod
          stuck_pod_name = stuck_pod.dig("metadata", "name")
          Kubernetes.pods.delete(stuck_pod_name, namespace: @cluster.namespace)
          @cluster.emit_event(
            "PodRestarted",
            "Deleted unavailable pod #{stuck_pod_name} (revision #{stuck_pod.dig('metadata', 'labels', 'controller-revision-hash')}) " \
            "which is not part of the cluster, #{stale_pods.size - 1} pods remaining",
          )
          @cluster.update_phase("Rolling restart: restarting #{stuck_pod_name} (#{stale_pods.size - 1} pods remaining)")
        elsif @in_progress
          waiting_for = unavailable_pod_names.any? ? unavailable_pod_names.sort.join(", ") : "#{health.fetch('number_of_nodes')}/#{replicas} nodes"
          @cluster.update_phase("Rolling restart: waiting for #{waiting_for} to join the cluster (#{stale_pods.size} pods remaining)")
        end

        return false
      end

      # All nodes are present so shard allocation must not remain disabled, regardless of how it got disabled
      # (eg. operator crash after deleting a pod). Outside of rollouts a single check after operator start suffices.
      if @in_progress || !@settings_verified
        settings = @client.cluster.get_settings(flat_settings: true)
        if settings.dig("persistent", ALLOCATION_SETTING) == "primaries"
          @client.cluster.put_settings(body: { persistent: { ALLOCATION_SETTING => nil } })
          LOGGER.info "Re-enabled replica shard allocation for #{@cluster.namespace}/#{@cluster.name}"
        end
      end

      # Lifts the exclusions once a scale down is done, or cancelled by raising the replicas again. Outside of scale downs a
      # single check after operator start suffices, it covers an operator crash half way through a scale down.
      if @scale_down || !@settings_verified
        settings ||= @client.cluster.get_settings(flat_settings: true)
        if settings.dig("persistent", EXCLUDE_SETTING) || settings.dig("transient", EXCLUDE_SETTING)
          @client.cluster.put_settings(body: { persistent: { EXCLUDE_SETTING => nil }, transient: { EXCLUDE_SETTING => nil } })
        end
        # All pods are present and none are leaving at this point, so every excluded node is either gone or staying
        @client.cluster.delete_voting_config_exclusions(wait_for_removal: false)

        if @scale_down == :removed_pods
          @cluster.emit_event(
            "ScaleDownCompleted",
            "Scale down finished with #{replicas} pods, cleared the shard allocation and voting configuration exclusions",
          )
        elsif @scale_down
          @cluster.emit_event(
            "ScaleDownCancelled",
            "Replicas were raised back to #{replicas} before any pods were removed, cleared the shard allocation exclusion",
          )
        end
        @scale_down = nil
        @settings_verified = true
      end

      status = health.fetch("status")

      if stale_pods.empty? && !@in_progress
        @waiting_for_green_since = nil
        @blocked_by_red_reported = false
        @cluster.update_phase("Running")
        return status == "green"
      end

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
        return false
      end
      @blocked_by_red_reported = false

      if status == "yellow"
        recovering = health.fetch("initializing_shards") + health.fetch("relocating_shards") + health.fetch("delayed_unassigned_shards")
        # The tolerance only starts counting once recovery has stopped making progress
        @waiting_for_green_since = nil if recovering.positive?
        @waiting_for_green_since ||= Time.now
        waited = Time.now - @waiting_for_green_since

        if recovering.positive? || waited < YELLOW_TOLERANCE
          @cluster.update_phase(
            "Rolling restart: waiting for green cluster health (#{health.fetch('unassigned_shards')} unassigned, " \
            "#{health.fetch('initializing_shards')} initializing, #{health.fetch('relocating_shards')} relocating shards, " \
            "#{stale_pods.size} pods remaining)",
          )
          return false
        end

        if stale_pods.any?
          @cluster.emit_event(
            "RollingRestartProceedingOnYellow",
            "Cluster health has been yellow for #{waited.round} seconds with #{health.fetch('unassigned_shards')} unassigned shards " \
            "and no shard recovery in progress, proceeding with restart of the next pod anyway",
            type: "Warning",
          )
        end
      end
      @waiting_for_green_since = nil

      if stale_pods.empty?
        @in_progress = false
        @cluster.emit_event(
          "RollingRestartCompleted",
          "All #{replicas} pods are running StatefulSet revision #{update_revision}, cluster health is #{status}",
        )
        @cluster.update_phase("Running")
        return status == "green"
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
      false
    end
  end
end
