# frozen_string_literal: true

RSpec.describe OpensearchOperator::RollingRestart do
  def exclude_setting = described_class::EXCLUDE_SETTING

  # A RollingRestart of a cluster which wants desired_replicas, against a simulated StatefulSet with replicas pods
  def simulate(replicas:, desired_replicas:, shards_per_node: 4)
    @environment = SimulatedEnvironment.new(replicas:, shards_per_node:)
    @cluster = SimulatedCluster.new(desired_replicas)
    allow(Kubernetes).to receive_messages(statefulsets: @environment.statefulsets, pods: @environment.pods_resource)
    described_class.new(@cluster, @environment.client)
  end

  # Ticks against the simulated environment, advancing it after each tick, and returns what each tick returned
  def run_ticks(rolling_restart, count, &before_tick)
    Array.new(count) do |tick|
      before_tick&.call(tick)
      settled = rolling_restart.tick(@environment.health, @environment.nodes)
      @environment.advance
      settled
    end
  end

  def expect_settled_at(replicas:)
    expect(@environment.violations).to be_empty
    expect(@environment.statefulset_replicas).to eq replicas
    expect(@environment.persistent).not_to have_key(exclude_setting)
    expect(@environment.transient).not_to have_key(exclude_setting)
    expect(@environment.voting_exclusions).to be_empty
    expect(@cluster.phases.last).to eq "Running"
  end

  def statefulset_patches = @environment.calls.grep(/\APATCH statefulset/)
  def deleted_pods = @environment.calls.grep(/\ADELETE pod/).map { |call| call.delete_prefix("DELETE pod ") }

  describe "scaling down" do
    it "migrates the shards off the leaving nodes and excludes them from voting before removing them" do
      settled = run_ticks(simulate(replicas: 5, desired_replicas: 3), 5)

      expect_settled_at(replicas: 3)
      expect(settled.last).to be true
      expect(@environment.total_shards).to eq 20
      expect(@cluster.event_reasons).to eq %w[ScaleDownStarted ScaleDownRemovingPods ScaleDownCompleted]
      expect(@cluster.phases).to include("Scaling down: migrating 8 shards off opensearch-demo-3, opensearch-demo-4")
      expect(@environment.calls).to include("POST _cluster/voting_config_exclusions opensearch-demo-3,opensearch-demo-4")
      expect(deleted_pods).to be_empty
    end

    it "cancels when the replicas are raised back while the shards are migrating" do
      run_ticks(simulate(replicas: 5, desired_replicas: 3), 4) { |tick| @cluster.replicas = 5 if tick == 2 }

      expect_settled_at(replicas: 5)
      expect(@environment.total_shards).to eq 20
      expect(@cluster.event_reasons).to eq %w[ScaleDownStarted ScaleDownCancelled]
      expect(statefulset_patches).to be_empty
    end

    it "keeps the leaving nodes while a primary shard is unassigned, even once they're drained" do
      rolling_restart = simulate(replicas: 4, desired_replicas: 3)
      @environment.unassigned_primaries = 1

      run_ticks(rolling_restart, 4)
      expect(statefulset_patches).to be_empty
      expect(@cluster.phases.last).to eq "Scaling down: blocked by 1 unassigned primary shards, keeping opensearch-demo-3"

      @environment.unassigned_primaries = 0
      run_ticks(rolling_restart, 3)
      expect_settled_at(replicas: 3)
    end

    it "keeps a dead leaving node's volume when it held the only copy of a primary" do
      rolling_restart = simulate(replicas: 5, desired_replicas: 3)
      @environment.kill(4)
      @environment.shards["opensearch-demo-4"] = 0
      @environment.unassigned_primaries = 1

      run_ticks(rolling_restart, 5)

      expect(@environment.statefulset_replicas).to eq 5
      expect(@cluster.phases.last)
        .to eq "Scaling down: blocked by 1 unassigned primary shards, keeping opensearch-demo-3, opensearch-demo-4"
    end

    it "waits for the remaining nodes to be ready before draining" do
      rolling_restart = simulate(replicas: 5, desired_replicas: 3)
      @environment.ready(1, ready: false)

      run_ticks(rolling_restart, 2)
      expect(@environment.persistent).not_to have_key(exclude_setting)
      expect(@cluster.phases.last).to eq "Scaling down: waiting for opensearch-demo-1 to join the cluster"

      @environment.ready(1)
      run_ticks(rolling_restart, 1)
      expect(@environment.persistent[exclude_setting]).to eq "opensearch-demo-3,opensearch-demo-4"
    end

    it "follows the replicas when they change mid drain" do
      run_ticks(simulate(replicas: 5, desired_replicas: 3), 6) { |tick| @cluster.replicas = 4 if tick == 1 }

      expect_settled_at(replicas: 4)
      expect(@environment.total_shards).to eq 20
      settings = { persistent: { exclude_setting => "opensearch-demo-4" }, transient: { exclude_setting => nil } }
      expect(@environment.calls).to include("PUT _cluster/settings #{settings.to_json}")
    end

    it "removes the leaving pods rather than restarting them when a rollout is pending too" do
      rolling_restart = simulate(replicas: 5, desired_replicas: 3)
      @environment.update_revision = "rev2"

      run_ticks(rolling_restart, 9)

      expect_settled_at(replicas: 3)
      expect(@environment.total_shards).to eq 20
      expect(deleted_pods).to eq %w[opensearch-demo-2 opensearch-demo-1 opensearch-demo-0]
      expect(@environment.pods.map { |pod| pod.dig("metadata", "labels", "controller-revision-hash") }).to all(eq "rev2")
      expect(@cluster.event_reasons.last).to eq "RollingRestartCompleted"
    end

    it "clears the exclusions after an operator restart once the removed nodes left" do
      run_ticks(simulate(replicas: 4, desired_replicas: 3), 3)
      expect(@environment.statefulset_replicas).to eq 3

      run_ticks(described_class.new(@cluster, @environment.client), 3)

      expect_settled_at(replicas: 3)
    end

    it "carries on with the drain after an operator restart" do
      run_ticks(simulate(replicas: 5, desired_replicas: 3), 2)

      run_ticks(described_class.new(@cluster, @environment.client), 5)

      expect_settled_at(replicas: 3)
      expect(@environment.total_shards).to eq 20
    end

    it "removes pods of a scale up which never got scheduled right away, since they hold nothing" do
      rolling_restart = simulate(replicas: 3, desired_replicas: 5)
      @environment.new_pods_pending = true
      run_ticks(rolling_restart, 3)
      expect(@environment.statefulset_replicas).to eq 5

      @cluster.replicas = 3
      run_ticks(rolling_restart, 3)

      expect_settled_at(replicas: 3)
      expect(@environment.total_shards).to eq 12
    end

    it "doesn't wait for a dead leaving node whose pod never finishes terminating" do
      rolling_restart = simulate(replicas: 7, desired_replicas: 3)
      @environment.kill(6)
      @environment.shards["opensearch-demo-6"] = 0 # its shards were rebuilt elsewhere while it was down
      @environment.stuck_terminating << 6

      run_ticks(rolling_restart, 8)

      expect_settled_at(replicas: 3)
      expect(@environment.total_shards).to eq 24
    end

    it "converges back up when the replicas are raised while the tick waits for the voting exclusions" do
      rolling_restart = simulate(replicas: 5, desired_replicas: 3)
      @environment.on_voting_exclusion = -> { @cluster.replicas = 5 }

      run_ticks(rolling_restart, 7) { |tick| @environment.on_voting_exclusion = nil if tick == 3 }

      expect_settled_at(replicas: 5)
      expect(@environment.total_shards).to eq 20
    end

    it "removes at most 10 nodes per step, the default limit of voting configuration exclusions" do
      run_ticks(simulate(replicas: 15, desired_replicas: 3, shards_per_node: 2), 12)

      expect_settled_at(replicas: 3)
      expect(statefulset_patches).to eq ["PATCH statefulset replicas=5", "PATCH statefulset replicas=3"]
      expect(@environment.total_shards).to eq 30
    end

    it "clears a transient exclude._name set by hand, which would take precedence over the drain's" do
      rolling_restart = simulate(replicas: 4, desired_replicas: 3)
      @environment.transient[exclude_setting] = "opensearch-demo-1"

      run_ticks(rolling_restart, 1)
      expect(@environment.transient).not_to have_key(exclude_setting)

      run_ticks(rolling_restart, 5)
      expect_settled_at(replicas: 3)
    end
  end

  describe "scaling up" do
    it "raises the StatefulSet replicas right away" do
      run_ticks(simulate(replicas: 3, desired_replicas: 5), 3)

      expect_settled_at(replicas: 5)
      expect(@cluster.event_reasons).to eq ["ScaleUp"]
      expect(@cluster.phases.first).to eq "Scaling up from 3 to 5 pods"
    end
  end

  describe "rolling restarts" do
    before do
      @rolling_restart = simulate(replicas: 3, desired_replicas: 3)
      @environment.update_revision = "rev2" # every pod runs an earlier revision
    end

    it "restarts one pod at a time, highest ordinal first and the cluster manager last" do
      run_ticks(@rolling_restart, 5)

      expect_settled_at(replicas: 3)
      expect(deleted_pods).to eq %w[opensearch-demo-2 opensearch-demo-1 opensearch-demo-0]
      expect(@environment.calls.grep(/allocation.enable/).first).to include('"primaries"')
      expect(@cluster.event_reasons)
        .to eq %w[RollingRestartStarted PodRestarted PodRestarted PodRestarted RollingRestartCompleted]
    end

    it "reports a restart before deleting the pod, so the PodDisruptionBudget allows no evictions by then" do
      phases_at_deletion = []
      @environment.on_pod_delete = -> { phases_at_deletion << @cluster.phases.last }

      run_ticks(@rolling_restart, 5)

      expect(phases_at_deletion.size).to eq 3
      expect(phases_at_deletion).to all(start_with("Rolling restart: restarting"))
    end

    it "reports the restart of a pod which left the cluster before deleting it too" do
      @environment.kill(1)
      phases_at_deletion = []
      @environment.on_pod_delete = -> { phases_at_deletion << @cluster.phases.last }

      run_ticks(@rolling_restart, 1)

      expect(phases_at_deletion).to eq ["Rolling restart: restarting opensearch-demo-1 (2 pods remaining)"]
    end

    it "doesn't restart pods while the cluster is red" do
      @environment.status = "red"

      run_ticks(@rolling_restart, 3)

      expect(deleted_pods).to be_empty
      expect(@cluster.event_reasons).to eq %w[RollingRestartStarted RollingRestartBlocked]
      expect(@cluster.phases.last).to eq "Rolling restart: blocked by red cluster health (3 pods remaining)"
    end

    it "proceeds on a yellow cluster without recovering shards after YELLOW_TOLERANCE" do
      @environment.status = "yellow"

      run_ticks(@rolling_restart, 2)
      expect(deleted_pods).to be_empty

      travel described_class::YELLOW_TOLERANCE + 1.second
      run_ticks(@rolling_restart, 1)
      expect(deleted_pods).to eq ["opensearch-demo-2"]
      expect(@cluster.event_reasons).to include("RollingRestartProceedingOnYellow")
    end

    it "re-enables replica allocation when a restarted pod doesn't rejoin within REPLICA_ALLOCATION_TIMEOUT" do
      @environment.new_pods_pending = true # the deleted pod comes back, but never joins
      run_ticks(@rolling_restart, 1)
      expect(@environment.persistent[described_class::ALLOCATION_SETTING]).to eq "primaries"

      run_ticks(@rolling_restart, 3)
      travel described_class::REPLICA_ALLOCATION_TIMEOUT - 1.minute
      run_ticks(@rolling_restart, 1)
      expect(@environment.persistent[described_class::ALLOCATION_SETTING]).to eq "primaries"

      travel 2.minutes
      run_ticks(@rolling_restart, 1)
      expect(@environment.persistent).not_to have_key(described_class::ALLOCATION_SETTING)
      expect(@cluster.event_reasons.last).to eq "ReplicaAllocationReenabled"
      expect(deleted_pods).to eq ["opensearch-demo-2"]

      # Not read again while the node stays away
      expect { run_ticks(@rolling_restart, 3) }.not_to(change { @environment.calls.count("GET _cluster/settings") })
    end

    it "leaves replica allocation which was re-enabled in the meantime alone" do
      @environment.new_pods_pending = true
      run_ticks(@rolling_restart, 2)
      @environment.persistent.delete(described_class::ALLOCATION_SETTING) # eg. by hand

      travel described_class::REPLICA_ALLOCATION_TIMEOUT + 1.second
      expect { run_ticks(@rolling_restart, 1) }.not_to(change { @environment.calls.grep(/allocation\.enable/).size })
      expect(@cluster.event_reasons).not_to include("ReplicaAllocationReenabled")
      expect { run_ticks(@rolling_restart, 3) }.not_to(change { @environment.calls.count("GET _cluster/settings") })
    end

    it "leaves replica allocation disabled outside of rollouts alone, eg. for maintenance of a node" do
      environment = SimulatedEnvironment.new(replicas: 3)
      rolling_restart = described_class.new(SimulatedCluster.new(3), environment.client)
      allow(Kubernetes).to receive_messages(statefulsets: environment.statefulsets, pods: environment.pods_resource)
      environment.persistent[described_class::ALLOCATION_SETTING] = "primaries"
      environment.kill(2)

      rolling_restart.tick(environment.health, environment.nodes)
      travel described_class::REPLICA_ALLOCATION_TIMEOUT + 1.second
      rolling_restart.tick(environment.health, environment.nodes)

      expect(environment.persistent[described_class::ALLOCATION_SETTING]).to eq "primaries"
    end

    it "re-enables replica allocation which an earlier operator run left disabled for a missing node" do
      @environment.new_pods_pending = true
      run_ticks(@rolling_restart, 3)

      restarted = described_class.new(@cluster, @environment.client)
      run_ticks(restarted, 1)
      travel described_class::REPLICA_ALLOCATION_TIMEOUT - 1.minute
      run_ticks(restarted, 1)
      expect(@environment.persistent[described_class::ALLOCATION_SETTING]).to eq "primaries"
      travel 1.minute + 1.second
      run_ticks(restarted, 1)

      expect(@environment.persistent).not_to have_key(described_class::ALLOCATION_SETTING)
      expect(@cluster.event_reasons.last).to eq "ReplicaAllocationReenabled"
    end

    it "waits for green afresh after a scale down interrupted it" do
      @environment.status = "yellow"
      run_ticks(@rolling_restart, 2)
      expect(@cluster.phases.last).to start_with "Rolling restart: waiting for green cluster health"

      travel described_class::YELLOW_TOLERANCE - 1.minute
      @cluster.replicas = 2
      run_ticks(@rolling_restart, 6)
      expect(@cluster.event_reasons).to include("ScaleDownCompleted")

      travel 2.minutes # past the tolerance counted from before the scale down
      run_ticks(@rolling_restart, 1)
      expect(deleted_pods).to be_empty
      expect(@cluster.event_reasons).not_to include("RollingRestartProceedingOnYellow")
    end
  end
end
