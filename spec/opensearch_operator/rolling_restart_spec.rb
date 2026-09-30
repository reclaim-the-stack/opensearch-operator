# frozen_string_literal: true

RSpec.describe OpensearchOperator::RollingRestart do
  def exclude_setting = described_class::EXCLUDE_SETTING

  def simulate(environment, cluster)
    @environment = environment
    @cluster = cluster
    allow(Kubernetes).to receive_messages(statefulsets: environment.statefulsets, pods: environment.pods_resource)
    described_class.new(cluster, environment.client)
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
      rolling_restart = simulate(SimulatedEnvironment.new(replicas: 5), SimulatedCluster.new(3))

      settled = run_ticks(rolling_restart, 5)

      expect_settled_at(replicas: 3)
      expect(settled.last).to be true
      expect(@environment.total_shards).to eq 20
      expect(@cluster.event_reasons).to eq %w[ScaleDownStarted ScaleDownRemovingPods ScaleDownCompleted]
      expect(@cluster.phases).to include("Scaling down: migrating 8 shards off opensearch-demo-3, opensearch-demo-4")
      expect(@environment.calls).to include("POST _cluster/voting_config_exclusions opensearch-demo-3,opensearch-demo-4")
      expect(deleted_pods).to be_empty
    end

    it "cancels when the replicas are raised back while the shards are migrating" do
      rolling_restart = simulate(SimulatedEnvironment.new(replicas: 5), SimulatedCluster.new(3))

      run_ticks(rolling_restart, 4) { |tick| @cluster.replicas = 5 if tick == 2 }

      expect_settled_at(replicas: 5)
      expect(@environment.total_shards).to eq 20
      expect(@cluster.event_reasons).to eq %w[ScaleDownStarted ScaleDownCancelled]
      expect(statefulset_patches).to be_empty
    end

    it "keeps the leaving nodes while a primary shard is unassigned, even once they're drained" do
      environment = SimulatedEnvironment.new(replicas: 4)
      environment.unassigned_primaries = 1
      rolling_restart = simulate(environment, SimulatedCluster.new(3))

      run_ticks(rolling_restart, 4)
      expect(statefulset_patches).to be_empty
      expect(@cluster.phases.last).to eq "Scaling down: blocked by 1 unassigned primary shards, keeping opensearch-demo-3"

      environment.unassigned_primaries = 0
      run_ticks(rolling_restart, 3)
      expect_settled_at(replicas: 3)
    end

    it "keeps a dead leaving node's volume when it held the only copy of a primary" do
      environment = SimulatedEnvironment.new(replicas: 5)
      environment.kill(4)
      environment.shards["opensearch-demo-4"] = 0
      environment.unassigned_primaries = 1
      rolling_restart = simulate(environment, SimulatedCluster.new(3))

      run_ticks(rolling_restart, 5)

      expect(environment.statefulset_replicas).to eq 5
      expect(@cluster.phases.last)
        .to eq "Scaling down: blocked by 1 unassigned primary shards, keeping opensearch-demo-3, opensearch-demo-4"
    end

    it "waits for the remaining nodes to be ready before draining" do
      environment = SimulatedEnvironment.new(replicas: 5)
      environment.ready(1, ready: false)
      rolling_restart = simulate(environment, SimulatedCluster.new(3))

      run_ticks(rolling_restart, 2)
      expect(environment.persistent).not_to have_key(exclude_setting)
      expect(@cluster.phases.last).to eq "Scaling down: waiting for opensearch-demo-1 to join the cluster"

      environment.ready(1)
      run_ticks(rolling_restart, 1)
      expect(environment.persistent[exclude_setting]).to eq "opensearch-demo-3,opensearch-demo-4"
    end

    it "follows the replicas when they change mid drain" do
      rolling_restart = simulate(SimulatedEnvironment.new(replicas: 5), SimulatedCluster.new(3))

      run_ticks(rolling_restart, 6) { |tick| @cluster.replicas = 4 if tick == 1 }

      expect_settled_at(replicas: 4)
      expect(@environment.total_shards).to eq 20
      settings = { persistent: { exclude_setting => "opensearch-demo-4" }, transient: { exclude_setting => nil } }
      expect(@environment.calls).to include("PUT _cluster/settings #{settings.to_json}")
    end

    it "removes the leaving pods rather than restarting them when a rollout is pending too" do
      environment = SimulatedEnvironment.new(replicas: 5)
      environment.update_revision = "rev2"
      rolling_restart = simulate(environment, SimulatedCluster.new(3))

      run_ticks(rolling_restart, 9)

      expect_settled_at(replicas: 3)
      expect(environment.total_shards).to eq 20
      expect(deleted_pods).to eq %w[opensearch-demo-2 opensearch-demo-1 opensearch-demo-0]
      expect(environment.pods.map { |pod| pod.dig("metadata", "labels", "controller-revision-hash") }).to all(eq "rev2")
      expect(@cluster.event_reasons.last).to eq "RollingRestartCompleted"
    end

    it "clears the exclusions after an operator restart once the removed nodes left" do
      environment = SimulatedEnvironment.new(replicas: 4)
      run_ticks(simulate(environment, SimulatedCluster.new(3)), 3)
      expect(environment.statefulset_replicas).to eq 3

      run_ticks(described_class.new(@cluster, environment.client), 3)

      expect_settled_at(replicas: 3)
    end

    it "carries on with the drain after an operator restart" do
      environment = SimulatedEnvironment.new(replicas: 5)
      run_ticks(simulate(environment, SimulatedCluster.new(3)), 2)

      run_ticks(described_class.new(@cluster, environment.client), 5)

      expect_settled_at(replicas: 3)
      expect(environment.total_shards).to eq 20
    end

    it "removes pods of a scale up which never got scheduled right away, since they hold nothing" do
      environment = SimulatedEnvironment.new(replicas: 3)
      environment.new_pods_pending = true
      rolling_restart = simulate(environment, SimulatedCluster.new(5))
      run_ticks(rolling_restart, 3)
      expect(environment.statefulset_replicas).to eq 5

      @cluster.replicas = 3
      run_ticks(rolling_restart, 3)

      expect_settled_at(replicas: 3)
      expect(environment.total_shards).to eq 12
    end

    it "doesn't wait for a dead leaving node whose pod never finishes terminating" do
      environment = SimulatedEnvironment.new(replicas: 7)
      environment.kill(6)
      environment.shards["opensearch-demo-6"] = 0 # its shards were rebuilt elsewhere while it was down
      environment.stuck_terminating << 6
      rolling_restart = simulate(environment, SimulatedCluster.new(3))

      run_ticks(rolling_restart, 8)

      expect_settled_at(replicas: 3)
      expect(environment.total_shards).to eq 24
    end

    it "converges back up when the replicas are raised while the tick waits for the voting exclusions" do
      environment = SimulatedEnvironment.new(replicas: 5)
      rolling_restart = simulate(environment, SimulatedCluster.new(3))
      environment.on_voting_exclusion = -> { @cluster.replicas = 5 }

      run_ticks(rolling_restart, 7) { |tick| environment.on_voting_exclusion = nil if tick == 3 }

      expect_settled_at(replicas: 5)
      expect(environment.total_shards).to eq 20
    end

    it "removes at most 10 nodes per step, the default limit of voting configuration exclusions" do
      rolling_restart = simulate(SimulatedEnvironment.new(replicas: 15, shards_per_node: 2), SimulatedCluster.new(3))

      run_ticks(rolling_restart, 12)

      expect_settled_at(replicas: 3)
      expect(statefulset_patches).to eq ["PATCH statefulset replicas=5", "PATCH statefulset replicas=3"]
      expect(@environment.total_shards).to eq 30
    end

    it "clears a transient exclude._name set by hand, which would take precedence over the drain's" do
      environment = SimulatedEnvironment.new(replicas: 4)
      environment.transient[exclude_setting] = "opensearch-demo-1"
      rolling_restart = simulate(environment, SimulatedCluster.new(3))

      run_ticks(rolling_restart, 1)
      expect(environment.transient).not_to have_key(exclude_setting)

      run_ticks(rolling_restart, 5)
      expect_settled_at(replicas: 3)
    end

    it "restarts the yellow tolerance of an earlier rollout" do
      rolling_restart = simulate(SimulatedEnvironment.new(replicas: 4), SimulatedCluster.new(3))
      rolling_restart.instance_variable_set(:@waiting_for_green_since, 1.hour.ago)

      run_ticks(rolling_restart, 1)

      expect(rolling_restart.instance_variable_get(:@waiting_for_green_since)).to be_nil
    end
  end

  describe "scaling up" do
    it "raises the StatefulSet replicas right away" do
      rolling_restart = simulate(SimulatedEnvironment.new(replicas: 3), SimulatedCluster.new(5))

      run_ticks(rolling_restart, 3)

      expect_settled_at(replicas: 5)
      expect(@cluster.event_reasons).to eq ["ScaleUp"]
      expect(@cluster.phases.first).to eq "Scaling up from 3 to 5 pods"
    end
  end

  describe "rolling restarts" do
    let(:environment) { SimulatedEnvironment.new(replicas: 3).tap { |environment| environment.update_revision = "rev2" } }

    it "restarts one pod at a time, highest ordinal first and the cluster manager last" do
      rolling_restart = simulate(environment, SimulatedCluster.new(3))

      run_ticks(rolling_restart, 5)

      expect_settled_at(replicas: 3)
      expect(deleted_pods).to eq %w[opensearch-demo-2 opensearch-demo-1 opensearch-demo-0]
      expect(@environment.calls.grep(/allocation.enable/).first).to include('"primaries"')
      expect(@cluster.event_reasons)
        .to eq %w[RollingRestartStarted PodRestarted PodRestarted PodRestarted RollingRestartCompleted]
    end

    it "doesn't restart pods while the cluster is red" do
      environment.status = "red"
      rolling_restart = simulate(environment, SimulatedCluster.new(3))

      run_ticks(rolling_restart, 3)

      expect(deleted_pods).to be_empty
      expect(@cluster.event_reasons).to eq %w[RollingRestartStarted RollingRestartBlocked]
      expect(@cluster.phases.last).to eq "Rolling restart: blocked by red cluster health (3 pods remaining)"
    end

    it "proceeds on a yellow cluster without recovering shards after YELLOW_TOLERANCE" do
      environment.status = "yellow"
      rolling_restart = simulate(environment, SimulatedCluster.new(3))

      run_ticks(rolling_restart, 2)
      expect(deleted_pods).to be_empty

      travel described_class::YELLOW_TOLERANCE + 1.second
      run_ticks(rolling_restart, 1)
      expect(deleted_pods).to eq ["opensearch-demo-2"]
      expect(@cluster.event_reasons).to include("RollingRestartProceedingOnYellow")
    end
  end
end
