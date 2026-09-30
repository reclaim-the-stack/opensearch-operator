# frozen_string_literal: true

# Simulates what RollingRestart acts on: a StatefulSet with OnDelete updates, its pods, and the shards and voting
# configuration of the OpenSearch cluster they form. #advance plays what the StatefulSet controller, the kubelet and
# OpenSearch do between two ticks. Lowering the replicas records violations of the scale down's safety guarantees.
class SimulatedEnvironment
  EXCLUDE_SETTING = "cluster.routing.allocation.exclude._name"

  attr_accessor :statefulset_replicas, :generation, :observed_generation, :update_revision, :pods, :persistent, :transient,
    :shards, :voting_exclusions, :status, :calls, :unassigned_primaries, :new_pods_pending, :on_voting_exclusion,
    :stuck_terminating
  attr_reader :violations

  def initialize(replicas:, shards_per_node: 4)
    @statefulset_replicas = replicas
    @generation = 1
    @observed_generation = 1
    @update_revision = "rev1"
    @pods = (0...replicas).map { |ordinal| new_pod(ordinal, "rev1") }
    @persistent = {}
    @transient = {}
    @shards = (0...replicas).to_h { |ordinal| [pod_name_for(ordinal), shards_per_node] }
    @voting_exclusions = []
    @status = "green"
    @calls = []
    @unassigned_primaries = 0
    @new_pods_pending = false
    @stuck_terminating = [] # ordinals whose Kubernetes node is gone, so their pods never finish terminating
    @violations = []
  end

  def pod_name_for(ordinal) = "opensearch-demo-#{ordinal}"

  def new_pod(ordinal, revision, ready: true, joined: true)
    {
      "metadata" => { "name" => pod_name_for(ordinal), "labels" => { "controller-revision-hash" => revision } },
      "status" => { "conditions" => [{ "type" => "Ready", "status" => ready ? "True" : "False" }] },
      "joined" => joined, # simulation only: whether the pod's OpenSearch node is part of the cluster
    }
  end

  def pod(ordinal) = @pods.find { |pod| pod_name(pod) == pod_name_for(ordinal) }
  def pod_name(pod) = pod.dig("metadata", "name")
  def ordinal(name) = name.split("-").last.to_i
  def node_names = @pods.select { |pod| pod["joined"] && !pod.dig("metadata", "deletionTimestamp") }.map { |pod| pod_name(pod) }
  def total_shards = @shards.values.sum
  def excluded = (@transient[EXCLUDE_SETTING] || @persistent[EXCLUDE_SETTING]).to_s.split(",")

  def ready(ordinal, ready: true)
    pod(ordinal)["status"]["conditions"] = [{ "type" => "Ready", "status" => ready ? "True" : "False" }]
  end

  # The node leaves the cluster (eg. a dead Kubernetes node) while its pod stays around unavailable
  def kill(ordinal)
    pod(ordinal)["joined"] = false
    ready(ordinal, ready: false)
  end

  def health
    {
      "status" => @status, "number_of_nodes" => node_names.size, "unassigned_shards" => @unassigned_primaries,
      "initializing_shards" => 0, "relocating_shards" => 0, "delayed_unassigned_shards" => 0
    }
  end

  def nodes = node_names.map { |name| { "name" => name, "cluster_manager" => name.end_with?("-0") ? "*" : "-" } }

  # GET _cluster/state/nodes,routing_nodes with the operator's filter_path, which leaves out empty arrays
  def cluster_state
    node_shards = node_names.to_h { |name| ["id-#{name}", [{ "state" => "STARTED" }] * @shards.fetch(name, 0)] }
    node_shards.reject! { |_node_id, shards| shards.empty? }
    routing_nodes = {}
    routing_nodes["nodes"] = node_shards if node_shards.any?
    routing_nodes["unassigned"] = [{ "primary" => true }] * @unassigned_primaries if @unassigned_primaries.positive?
    state = { "nodes" => node_names.to_h { |name| ["id-#{name}", { "name" => name }] } }
    state["routing_nodes"] = routing_nodes if routing_nodes.any?
    state
  end

  def scale_statefulset(replicas)
    if replicas < @statefulset_replicas
      removed = (replicas...@statefulset_replicas).map { |ordinal| pod_name_for(ordinal) }
      with_shards = removed.select { |name| @shards.fetch(name, 0).positive? }
      @violations << "removed #{with_shards.join(', ')} while holding shards" if with_shards.any?
      voting = (removed & node_names) - @voting_exclusions
      @violations << "removed #{voting.join(', ')} while in the voting configuration" if voting.any?
    end
    @statefulset_replicas = replicas
    @generation += 1
  end

  def advance
    @pods.reject! { |pod| pod.dig("metadata", "deletionTimestamp") && !@stuck_terminating.include?(ordinal(pod_name(pod))) }
    # Restarted pods recover their shards from their volume, removed pods (ordinals beyond the replicas) lose them
    @shards.select! { |name, _| @pods.any? { |pod| pod_name(pod) == name } || ordinal(name) < @statefulset_replicas }

    if @observed_generation != @generation
      @observed_generation = @generation
      @pods.each { |pod| pod["metadata"]["deletionTimestamp"] = "now" if ordinal(pod_name(pod)) >= @statefulset_replicas }
    end

    # OnDelete: deleted pods come back on the update revision
    (0...@statefulset_replicas).each do |ordinal|
      next if pod(ordinal)

      @pods << new_pod(ordinal, @update_revision, ready: !@new_pods_pending, joined: !@new_pods_pending)
      @shards[pod_name_for(ordinal)] ||= 0
    end

    # Shards move off excluded nodes, two per node and tick
    targets = node_names - excluded
    excluded.each do |name|
      next unless node_names.include?(name) && @shards[name]&.positive?

      moved = [@shards[name], 2].min
      @shards[name] -= moved
      moved.times { |index| @shards[targets[index % targets.size]] += 1 }
    end
  end

  # The Kubernetes resources and the OpenSearch client RollingRestart uses, backed by this environment
  def statefulsets
    environment = self
    Object.new.tap do |statefulsets|
      statefulsets.define_singleton_method(:get!) do |_name, namespace:|
        {
          "metadata" => { "generation" => environment.generation },
          "spec" => { "replicas" => environment.statefulset_replicas },
          "status" => {
            "observedGeneration" => environment.observed_generation,
            "updateRevision" => environment.update_revision,
          },
        }
      end
      statefulsets.define_singleton_method(:patch) do |_name, namespace:, params:|
        environment.calls << "PATCH statefulset replicas=#{params.dig(:spec, :replicas)}"
        environment.scale_statefulset(params.dig(:spec, :replicas))
      end
    end
  end

  def pods_resource
    environment = self
    Object.new.tap do |pods|
      pods.define_singleton_method(:list) { |namespace:, params:| { "items" => environment.pods } }
      pods.define_singleton_method(:delete) do |name, namespace:|
        environment.calls << "DELETE pod #{name}"
        environment.pods.find { |pod| pod.dig("metadata", "name") == name }["metadata"]["deletionTimestamp"] = "now"
      end
    end
  end

  def client
    environment = self
    cluster = Object.new
    cluster.define_singleton_method(:get_settings) do |flat_settings:|
      { "persistent" => environment.persistent.dup, "transient" => environment.transient.dup }
    end
    cluster.define_singleton_method(:put_settings) do |body:|
      environment.calls << "PUT _cluster/settings #{body.to_json}"
      { persistent: environment.persistent, transient: environment.transient }.each do |scope, settings|
        body.fetch(scope, {}).each { |key, value| value.nil? ? settings.delete(key) : settings[key] = value }
      end
    end
    cluster.define_singleton_method(:state) { |metric:, filter_path:| environment.cluster_state }
    cluster.define_singleton_method(:post_voting_config_exclusions) do |node_names:|
      environment.calls << "POST _cluster/voting_config_exclusions #{Array(node_names).join(',')}"
      exclusions = environment.voting_exclusions | Array(node_names)
      raise ArgumentError, "exceeds cluster.max_voting_config_exclusions [10] with #{exclusions.size}" if exclusions.size > 10

      environment.voting_exclusions = exclusions
      environment.on_voting_exclusion&.call
    end
    cluster.define_singleton_method(:delete_voting_config_exclusions) do |wait_for_removal:|
      environment.calls << "DELETE _cluster/voting_config_exclusions"
      environment.voting_exclusions = []
    end
    indices = Object.new
    indices.define_singleton_method(:flush) { environment.calls << "POST _flush" }
    client = Object.new
    client.define_singleton_method(:cluster) { cluster }
    client.define_singleton_method(:indices) { indices }
    client
  end
end

# The parts of a Cluster which RollingRestart uses, recording its events and phases
class SimulatedCluster
  attr_accessor :replicas, :evaluated_statefulset_generation
  attr_reader :events, :phases

  def initialize(replicas)
    @replicas = replicas
    @events = []
    @phases = []
  end

  def name = "demo"
  def namespace = "default"
  def statefulset_name = "opensearch-demo"
  def emit_event(reason, message, type: "Normal") = @events << [reason, type, message]
  def event_reasons = @events.map(&:first)

  def update_phase(phase)
    @phases << phase unless @phases.last == phase
  end
end
