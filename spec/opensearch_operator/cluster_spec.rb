# frozen_string_literal: true

RSpec.describe OpensearchOperator::Cluster do
  subject(:cluster) { OpensearchOperator::Cluster.new(manifest) }

  let(:manifest) { cluster_manifest }

  # What a tick of the rolling restart does: report the StatefulSet generation it read, then its phase
  def tick(phase, statefulset_generation: fake_kubernetes.statefulset_generation)
    cluster.evaluated_statefulset_generation = statefulset_generation
    cluster.update_phase(phase)
  end

  describe "#name" do
    it "returns the name from metadata" do
      expect(cluster.name).to eq "example"
    end
  end

  describe "#namespace" do
    it "returns the namespace from metadata" do
      expect(cluster.namespace).to eq "default"
    end
  end

  describe "#uid" do
    it "returns the uid from metadata" do
      expect(cluster.uid).to eq "123e4567-e89b-12d3-a456-426614174000"
    end
  end

  describe "#spec" do
    it "returns the spec hash" do
      expect(cluster.spec).to be_a Hash
      expect(cluster.spec["image"]).to eq "opensearchproject/opensearch:3.1.0"
    end
  end

  describe "#image" do
    it "returns the image from spec" do
      expect(cluster.image).to eq "opensearchproject/opensearch:3.1.0"
    end
  end

  describe "#replicas" do
    it "returns the replicas from spec" do
      expect(cluster.replicas).to eq 3
    end
  end

  describe "#disk_size" do
    it "returns the diskSize from spec" do
      expect(cluster.disk_size).to eq "5Gi"
    end
  end

  describe "#version" do
    it "returns the version extracted from image" do
      expect(cluster.version).to eq "3.1.0"
    end
  end

  describe "rendered manifests" do
    # Review the diff after a template change, then regenerate the files with UPDATE_MANIFEST_SNAPSHOTS=1 bundle exec rspec.
    # A change to the StatefulSet's pod template restarts every pod of existing clusters (see Cluster::MANIFEST_VERSION).
    snapshots = {
      "example" => {},
      "example-in-another-namespace-with-repositories-and-config" => {
        namespace: "team-a",
        snapshotRepositories: [
          {
            "name" => "backups", "type" => "s3", "bucket" => "opensearch-backups", "base_path" => "example",
            "accessKeyId" => { "name" => "backups-credentials", "key" => "access_key" },
            "secretAccessKey" => { "name" => "backups-credentials", "key" => "secret_key" },
            "policies" => [{ "name" => "daily", "schedule" => "0 3 * * *", "max_age" => "7d" }]
          },
        ],
        config: { "indices.query.bool.max_clause_count" => 4096 },
      },
    }

    snapshots.each do |snapshot, variant|
      it "match spec/fixtures/manifests/#{snapshot}.yaml" do
        fake_kubernetes
        fake_watcher
        OpensearchOperator::Cluster.new(cluster_manifest(**variant)).reconsile

        # Secrets and ConfigMaps are left out, they hold generated passwords and certificates
        documents = fake_kubernetes.applied.values_at(:services, :statefulsets, :deployments).flatten
        rendered = documents.map { |document| YAML.dump(document) }.join
        path = "spec/fixtures/manifests/#{snapshot}.yaml"
        File.write(path, rendered) if ENV["UPDATE_MANIFEST_SNAPSHOTS"]
        expect(rendered).to eq File.read(path)
      end
    end
  end

  describe "the applied StatefulSet" do
    before do
      fake_kubernetes
      fake_watcher
    end

    def applied_statefulset = fake_kubernetes.applied[:statefulsets].last

    def applied_disk_size
      applied_statefulset.dig("spec", "volumeClaimTemplates", 0, "spec", "resources", "requests", "storage")
    end

    it "uses the spec's replicas and disk size for a new StatefulSet" do
      cluster.reconsile

      expect(applied_statefulset.dig("spec", "replicas")).to eq 3
      expect(applied_disk_size).to eq "5Gi"
    end

    it "keeps the replicas and the disk size of an existing StatefulSet, which the rolling restart and the volumes own" do
      fake_kubernetes.existing_statefulset = {
        "spec" => {
          "replicas" => 5,
          "updateStrategy" => { "type" => "OnDelete" },
          "volumeClaimTemplates" => [{ "spec" => { "resources" => { "requests" => { "storage" => "10Gi" } } } }],
        },
      }

      cluster.reconsile

      expect(applied_statefulset.dig("spec", "replicas")).to eq 5
      expect(applied_disk_size).to eq "10Gi"
      expect(fake_kubernetes.statefulset_patches).to be_empty
    end

    it "moves an existing StatefulSet off the RollingUpdate strategy first, since apply can't remove its partition" do
      update_strategy = { "type" => "RollingUpdate", "rollingUpdate" => { "partition" => 0 } }
      fake_kubernetes.existing_statefulset = { "spec" => { "replicas" => 3, "updateStrategy" => update_strategy } }

      cluster.reconsile

      expect(fake_kubernetes.statefulset_patches).to eq [{ spec: { updateStrategy: { type: "OnDelete", rollingUpdate: nil } } }]
      expect(applied_statefulset.dig("spec", "updateStrategy")).to eq("type" => "OnDelete")
    end

    it "applies nothing when the existing StatefulSet can't be read" do
      allow(fake_kubernetes.statefulsets).to receive(:get).and_raise(Kubernetes::Error, "Get opensearch-example failed: 503")

      expect { cluster.reconsile }.to raise_error(Kubernetes::Error, /503/)
      expect(fake_kubernetes.applied[:statefulsets]).to be_empty
    end

    it "sizes the heap at half the memory limit" do
      manifest["spec"]["resources"] = { "limits" => { "memory" => "4608Mi" }, "requests" => { "memory" => "4608Mi" } }
      cluster.reconsile

      environment = applied_statefulset.dig("spec", "template", "spec", "containers", 0, "env")
      expect(environment).to include("name" => "OPENSEARCH_JAVA_OPTS", "value" => "-Xms2304m -Xmx2304m")
    end
  end

  describe "snapshot repositories" do
    let(:snapshot) do
      Class.new do
        attr_reader :created, :failures
        attr_accessor :on_create

        def initialize
          @created = []
          @failures = Hash.new(0)
        end

        def create_repository(params)
          name = params.fetch(:repository)
          on_create&.call
          if failures[name].positive?
            failures[name] -= 1
            raise OpenSearch::Transport::Transport::Errors::InternalServerError, "[500] verification failed for #{name}"
          end
          @created << name
        end
      end.new
    end
    let(:http) do
      Class.new do
        attr_reader :requests
        attr_accessor :listing_failures

        def initialize
          @requests = []
          @listing_failures = 0
        end

        def get(path, params: {})
          @requests << [:get, path, params]
          if listing_failures.positive?
            self.listing_failures -= 1
            raise Faraday::ConnectionFailed, "connection refused"
          end

          { "policies" => [] }
        end

        def post(path, **) = @requests << [:post, path]
      end.new
    end
    let(:repository_names) { %w[primary] }
    let(:manifest) do
      policies = [{ "name" => "daily", "schedule" => "0 3 * * *", "max_age" => "7d" }]
      repositories = repository_names.map { |name| { "name" => name, "bucket" => "bucket-#{name}", "policies" => policies } }
      cluster_manifest(snapshotRepositories: repositories)
    end
    let(:watcher) do
      info = { "cluster_uuid" => "Q7rVjM5BSnefOwj1a8d2Tw" }
      fake_watcher(client: Struct.new(:snapshot, :http, :info).new(snapshot, http, info))
    end
    let(:rolling_restart) { instance_double(OpensearchOperator::RollingRestart, tick: true) }

    before do
      fake_kubernetes
      watcher
      allow(OpensearchOperator::RollingRestart).to receive(:new).and_return(rolling_restart)
      travel_to Time.utc(2026, 9, 30, 12)
      cluster.initialize_or_trigger_watcher
      travel 1.second # the upsert is due once its time has passed
    end

    def created_policies = http.requests.select { |request| request.first == :post }.map(&:last)

    # However long the cluster keeps polling, nothing gets upserted any more
    def expect_no_pending_upsert
      expect do
        travel described_class::SNAPSHOT_REPOSITORIES_MAX_RETRY_INTERVAL + 1.second
        watcher.poll
      end.not_to(change { [snapshot.created.size, http.requests.size] })
    end

    def change_spec_during_the_next_upsert
      snapshot.on_create = lambda do
        snapshot.on_create = nil
        cluster.initialize_or_trigger_watcher
      end
    end

    it "only upserts once the rolling restart reports a settled cluster" do
      allow(rolling_restart).to receive(:tick).and_return(false)
      watcher.poll
      expect(snapshot.created).to be_empty

      allow(rolling_restart).to receive(:tick).and_return(true)
      watcher.poll
      expect(snapshot.created).to eq ["primary"]
      expect(created_policies).to eq ["/_plugins/_sm/policies/primary-daily"]
      expect(http.requests.first).to eq [:get, "/_plugins/_sm/policies", { size: 1000 }]
    end

    context "with two repositories, one of them failing" do
      let(:repository_names) { %w[primary secondary] }

      before { snapshot.failures["primary"] = 1 }

      it "upserts the other one, then retries after the interval and reports the recovery" do
        watcher.poll
        expect(snapshot.created).to eq ["secondary"]
        expect(created_policies).to eq ["/_plugins/_sm/policies/secondary-daily"]
        expect(fake_kubernetes.events.last).to include("reason" => "SnapshotRepositoriesFailed", "type" => "Warning")
        expect(fake_kubernetes.events.last["message"])
          .to eq "Failed to upsert snapshot repositories primary (see the operator logs), retrying at 2026-09-30T12:05:01Z"

        travel described_class::SNAPSHOT_REPOSITORIES_RETRY_INTERVAL - 1.second
        watcher.poll
        expect(snapshot.created).to eq ["secondary"]

        travel 2.seconds
        watcher.poll
        expect(snapshot.created).to eq %w[secondary primary secondary]
        expect(fake_kubernetes.events.last).to include(
          "reason" => "SnapshotRepositoriesRecovered",
          "message" => "Upserted all snapshot repositories and policies after 1 failed attempt",
        )
        expect_no_pending_upsert
      end
    end

    it "backs off from 5 minutes up to an hour while the failures last" do
      snapshot.failures["primary"] = 100
      delays = Array.new(7) do
        watcher.poll
        retrying_at = Time.iso8601(fake_kubernetes.events.last.fetch("message")[/retrying at (\S+)\z/, 1])
        delay = retrying_at - Time.now
        travel_to retrying_at + 1.second
        delay
      end

      expect(delays.map { |delay| delay / 60 }).to eq [5, 10, 20, 40, 60, 60, 60]
      expect(fake_kubernetes.events.map { |event| event["reason"] }).to eq ["SnapshotRepositoriesFailed"] * 7
    end

    it "retries a failing policies listing like a failing repository" do
      http.listing_failures = 1
      watcher.poll
      expect(fake_kubernetes.events.last).to include("reason" => "SnapshotRepositoriesFailed")

      travel described_class::SNAPSHOT_REPOSITORIES_RETRY_INTERVAL + 1.second
      watcher.poll
      expect(created_policies).to eq ["/_plugins/_sm/policies/primary-daily"]
      expect_no_pending_upsert
    end

    it "upserts again when the spec changes in the middle of an upsert" do
      change_spec_during_the_next_upsert
      watcher.poll

      travel 10.seconds
      watcher.poll
      expect(snapshot.created).to eq %w[primary primary]
      expect_no_pending_upsert
    end

    it "keeps the immediate upsert of a spec change which arrives during a failing upsert" do
      snapshot.failures["primary"] = 1
      change_spec_during_the_next_upsert
      watcher.poll

      travel 10.seconds
      watcher.poll
      expect(snapshot.created).to eq ["primary"]
    end

    it "upserts right away after a spec change during the retry delay" do
      snapshot.failures["primary"] = 1
      watcher.poll
      travel 10.seconds
      watcher.poll
      expect(snapshot.created).to be_empty

      cluster.initialize_or_trigger_watcher
      travel 1.second
      watcher.poll
      expect(snapshot.created).to eq ["primary"]
    end

    context "without repositories" do
      let(:repository_names) { [] }

      it "makes no requests" do
        watcher.poll

        expect(http.requests).to be_empty
        expect(fake_kubernetes.events).to be_empty
      end
    end
  end

  describe "status conditions" do
    before do
      fake_kubernetes
      fake_watcher
      travel_to Time.utc(2026, 9, 30, 12)
    end

    def condition(type) = fake_kubernetes.condition(type)
    def summary(type) = condition(type)&.values_at("status", "reason", "observedGeneration")

    # A watch event with the given generation, whose failures the watch handler logs
    def update(generation)
      cluster.update(cluster_manifest(generation:))
    rescue Kubernetes::Error
      nil
    end

    context "with a new cluster" do
      before { cluster.reconsile }

      it "publishes Reconciled with the observed state" do
        expect(fake_kubernetes.status_patches.last.keys)
          .to contain_exactly("conditions", "observedGeneration", "operatorManifestVersion")
        expect(summary("Reconciled")).to eq ["True", "Reconciled", 1]
      end

      it "publishes Ready once both the health and a phase for the applied StatefulSet are known" do
        expect(condition("Ready")).to be_nil
        fake_watcher.report("green")
        expect(fake_kubernetes.status_patches.last.keys).to contain_exactly("health", "nodes", "version")
        expect(condition("Ready")).to be_nil

        tick("Running")
        expect(condition("Ready").values_at("status", "reason", "message", "observedGeneration"))
          .to eq ["True", "Running", "Cluster health is green", 1]
        expect(fake_kubernetes.status_patches.last["phase"]).to eq "Running"
      end
    end

    context "with a running cluster" do
      before do
        cluster.reconsile
        fake_watcher.report("green")
        tick("Running")
      end

      it "is Progressing during a rolling restart, moving lastTransitionTime only when the status flips" do
        ready_since = condition("Ready")["lastTransitionTime"]
        reconciled_since = condition("Reconciled")["lastTransitionTime"]

        travel 1.minute
        tick("Rolling restart: restarting opensearch-example-2 (2 pods remaining)")
        expect(condition("Ready").values_at("status", "reason", "message"))
          .to eq ["False", "Progressing", "Rolling restart: restarting opensearch-example-2 (2 pods remaining)"]
        expect(condition("Ready")["lastTransitionTime"]).not_to eq ready_since
        expect(condition("Reconciled")["lastTransitionTime"]).to eq reconciled_since
        progressing_since = condition("Ready")["lastTransitionTime"]

        travel 10.seconds
        tick("Rolling restart: waiting for opensearch-example-2 to join the cluster (2 pods remaining)")
        expect(condition("Ready")["lastTransitionTime"]).to eq progressing_since

        tick("Running")
        expect(summary("Ready")).to eq ["True", "Running", 1]
      end

      it "waits for the rolling restart to work with a StatefulSet which the reconciliation changed" do
        fake_kubernetes.statefulset_generation = 2
        update(2)
        expect(condition("Ready").values_at("status", "reason", "observedGeneration", "message"))
          .to eq ["False", "Progressing", 2, "Applying generation 2"]

        tick("Running", statefulset_generation: 1) # a tick which read the StatefulSet before the apply
        expect(summary("Ready")).to eq ["False", "Progressing", 2]

        tick("Rolling restart: restarting opensearch-example-2 (2 pods remaining)")
        expect(condition("Ready")["message"]).to eq "Rolling restart: restarting opensearch-example-2 (2 pods remaining)"

        tick("Running")
        expect(summary("Ready")).to eq ["True", "Running", 2]
      end

      it "stays Ready through a spec change which leaves the StatefulSet as it is" do
        update(2)

        expect(summary("Ready")).to eq ["True", "Running", 2]
      end

      it "doesn't take the phase of an earlier StatefulSet for the new one when a tick fails before reporting its phase" do
        fake_kubernetes.statefulset_generation = 2
        update(2)
        cluster.evaluated_statefulset_generation = 2 # the tick then raises before update_phase
        fake_watcher.report("yellow")
        expect(summary("Ready")).to eq ["False", "Progressing", 2]

        tick("Running")
        expect(summary("Ready")).to eq ["True", "Running", 2]
      end

      it "reflects the health" do
        expected = { "red" => %w[False HealthRed], "unreachable" => %w[False Unreachable], "yellow" => %w[True Running] }
        expected.each do |health, (status, reason)|
          fake_watcher.report(health)
          expect(condition("Ready").values_at("status", "reason")).to eq([status, reason]), health
        end
        expect(condition("Ready")["message"]).to eq "Cluster health is yellow"
      end

      it "is not Ready while being deleted" do
        cluster.update_phase("Deleting")

        expect(summary("Ready")).to eq ["False", "Deleting", 1]
      end

      it "patches the phase again after a failed patch" do
        fake_kubernetes.status_patch_error = "Patch failed: 500 etcdserver: request timed out"
        tick("Scaling up from 3 to 4 pods")
        fake_kubernetes.status_patch_error = nil

        expect { tick("Scaling up from 3 to 4 pods") }.to change { fake_kubernetes.status_patches.size }.by(1)
        expect(summary("Ready")).to eq ["False", "Progressing", 1]
      end

      context "when reconciling a generation fails" do
        before { fake_kubernetes.statefulset_apply_error = "Apply failed: 422 volumeClaimTemplates is immutable" }

        it "raises for the watch handler to log, publishing the failure in the conditions and a Warning event" do
          failure = "Kubernetes::Error: Apply failed: 422 volumeClaimTemplates is immutable"
          patches_before = fake_kubernetes.status_patches.size

          expect { cluster.update(cluster_manifest(generation: 2)) }
            .to raise_error(Kubernetes::Error, /volumeClaimTemplates is immutable/)

          expect(condition("Reconciled").values_at("status", "reason", "observedGeneration", "message"))
            .to eq ["False", "ReconcileFailed", 2, failure]
          expect(summary("Ready")).to eq ["False", "ReconcileFailed", 2]
          expect(fake_kubernetes.status_patches.drop(patches_before).map(&:keys)).to eq [["conditions"]]
          expect(fake_kubernetes.events).to eq [
            { "reason" => "ReconcileFailed", "type" => "Warning", "message" => "Failed to reconcile generation 2: #{failure}" },
          ]
        end

        it "retries at most once a minute, reporting a repeated failure only once" do
          update(2)
          attempts = fake_kubernetes.applied[:statefulsets].size
          patches = fake_kubernetes.status_patches.size

          update(2) # eg. the MODIFIED event of the status update reporting the failure
          expect(fake_kubernetes.applied[:statefulsets].size).to eq attempts

          travel described_class::RECONCILE_RETRY_INTERVAL + 1.second
          update(2)
          expect(fake_kubernetes.applied[:statefulsets].size).to eq attempts + 1
          expect(fake_kubernetes.status_patches.size).to eq patches
          expect(fake_kubernetes.events.size).to eq 1
        end

        it "publishes a different failure with its own event" do
          update(2)
          fake_kubernetes.statefulset_apply_error = "Apply failed: 500 etcdserver: request timed out"
          travel described_class::RECONCILE_RETRY_INTERVAL + 1.second
          update(2)

          expect(condition("Reconciled")["message"]).to eq "Kubernetes::Error: Apply failed: 500 etcdserver: request timed out"
          expect(fake_kubernetes.events.size).to eq 2
        end

        it "reconciles the next generation right away, becoming Ready again" do
          update(2)
          fake_kubernetes.statefulset_apply_error = nil
          update(3)

          expect(summary("Reconciled")).to eq ["True", "Reconciled", 3]
          expect(fake_kubernetes.status_patches.last["observedGeneration"]).to eq 3
          tick("Running")
          expect(summary("Ready")).to eq ["True", "Running", 3]
        end
      end
    end

    context "when the operator restarted" do
      let(:published) do
        common = { "status" => "True", "observedGeneration" => 3, "lastTransitionTime" => "2026-09-01T00:00:00Z" }
        [
          common.merge("type" => "Reconciled", "reason" => "Reconciled", "message" => "Generation 3 is applied"),
          common.merge("type" => "Ready", "reason" => "Running", "message" => "Cluster health is green"),
        ]
      end
      let(:manifest) do
        status = { "observedGeneration" => 3, "operatorManifestVersion" => described_class::MANIFEST_VERSION }
        cluster_manifest(generation: 3, status: status.merge("conditions" => published))
      end

      it "publishes nothing while the conditions are unchanged" do
        cluster.reconsile
        fake_watcher.report("green")
        tick("Running")

        expect(fake_kubernetes.status_patches.map(&:keys)).to eq [%w[health nodes version], ["phase"]]
      end

      it "keeps the published transition times when only a message changes" do
        cluster.reconsile
        fake_watcher.report("green")
        tick("Running")
        fake_watcher.report("yellow")

        expect(condition("Ready").values_at("status", "message", "lastTransitionTime"))
          .to eq ["True", "Cluster health is yellow", "2026-09-01T00:00:00Z"]
        expect(condition("Reconciled")["lastTransitionTime"]).to eq "2026-09-01T00:00:00Z"
      end

      it "doesn't report a failure again which was published before the restart" do
        failure = "Kubernetes::Error: Apply failed: 422 volumeClaimTemplates is immutable"
        failed = published.map do |condition|
          condition.merge("status" => "False", "reason" => "ReconcileFailed", "message" => failure, "observedGeneration" => 4)
        end
        fake_kubernetes.statefulset_apply_error = "Apply failed: 422 volumeClaimTemplates is immutable"
        status = { "observedGeneration" => 3, "conditions" => failed }
        restarted = OpensearchOperator::Cluster.new(cluster_manifest(generation: 4, status:))

        expect { restarted.reconsile }.to raise_error(Kubernetes::Error)
        expect(fake_kubernetes.events).to be_empty
        expect(fake_kubernetes.status_patches).to be_empty
      end
    end
  end

  describe "bootstrap" do
    let(:cluster_info) { { "cluster_uuid" => "Q7rVjM5BSnefOwj1a8d2Tw" } }
    let(:rolling_restart) { instance_double(OpensearchOperator::RollingRestart, tick: false) }

    before do
      fake_kubernetes
      fake_watcher(client: Struct.new(:info).new(cluster_info))
      allow(OpensearchOperator::RollingRestart).to receive(:new).and_return(rolling_restart)
      cluster.reconsile
    end

    def records
      fake_kubernetes.applied[:configmaps].select { |manifest| manifest.dig("metadata", "name").end_with?("-bootstrap") }
    end

    it "records the UUID of the formed cluster for the startup script of its pods" do
      fake_watcher.poll

      expect(records.size).to eq 1
      expect(records.last["data"]).to eq("cluster_uuid" => "Q7rVjM5BSnefOwj1a8d2Tw", "resource_uid" => cluster.uid)
      expect(records.last.dig("metadata", "ownerReferences", 0)).to include("kind" => "OpenSearch", "uid" => cluster.uid)
    end

    it "waits until the cluster has formed" do
      cluster_info["cluster_uuid"] = "_na_"
      fake_watcher.poll
      expect(records).to be_empty

      cluster_info["cluster_uuid"] = "Q7rVjM5BSnefOwj1a8d2Tw"
      fake_watcher.poll
      expect(records.size).to eq 1
    end

    it "writes the record on every poll, so a deleted ConfigMap comes back right away, logging new UUIDs" do
      2.times { fake_watcher.poll }
      cluster_info["cluster_uuid"] = "w8b1AbYwSdO6cS0Lk_p5Qg"
      fake_watcher.poll

      expect(records.map { |record| record.dig("data", "cluster_uuid") })
        .to eq %w[Q7rVjM5BSnefOwj1a8d2Tw Q7rVjM5BSnefOwj1a8d2Tw w8b1AbYwSdO6cS0Lk_p5Qg]
      expect(log_output.scan(%r{Recorded the bootstrap of default/example, cluster UUID (\S+)}).flatten)
        .to eq %w[Q7rVjM5BSnefOwj1a8d2Tw w8b1AbYwSdO6cS0Lk_p5Qg]
    end

    it "retries a failure on the next poll, without holding up the rolling restart" do
      allow(fake_kubernetes.configmaps).to receive(:apply).and_raise(Kubernetes::Error, "Apply failed: 503")
      fake_watcher.poll
      expect(rolling_restart).to have_received(:tick)
      expect(log_output).to include "Failed to record the bootstrap of default/example: Kubernetes::Error: Apply failed: 503"

      allow(fake_kubernetes.configmaps).to receive(:apply).and_call_original
      fake_watcher.poll
      expect(records.size).to eq 1
    end
  end

  describe "pod disruption budget" do
    let(:rolling_restart) { instance_double(OpensearchOperator::RollingRestart, tick: false) }

    before do
      fake_kubernetes
      fake_watcher
      allow(OpensearchOperator::RollingRestart).to receive(:new).and_return(rolling_restart)
      cluster.reconsile
    end

    def budgets = fake_kubernetes.applied[:pod_disruption_budgets]
    def applied_max_unavailable = budgets.map { |budget| budget.dig("spec", "maxUnavailable") }

    it "allows one eviction once the cluster is green and settled, and waits until both are known" do
      fake_watcher.report("green")
      expect(budgets).to be_empty

      tick("Running")
      expect(budgets.last["metadata"]).to include("name" => "opensearch-example", "namespace" => "default")
      expect(budgets.last.dig("metadata", "ownerReferences", 0)).to include("kind" => "OpenSearch", "uid" => cluster.uid)
      pod_labels = { "app.kubernetes.io/name" => "opensearch", "opensearch.reclaim-the-stack.com/cluster" => "example" }
      expect(budgets.last["spec"]).to eq("maxUnavailable" => 1, "selector" => { "matchLabels" => pod_labels })
    end

    it "allows none while the cluster isn't green, applying only changes" do
      fake_watcher.report("green")
      tick("Running")
      %w[yellow green red unreachable green].each { |health| fake_watcher.report(health) }

      expect(applied_max_unavailable).to eq [1, 0, 1, 0, 1]
    end

    it "allows none during rolling restarts and scaling" do
      fake_watcher.report("green")
      tick("Running")
      tick("Rolling restart: restarting opensearch-example-2 (2 pods remaining)")
      tick("Rolling restart: waiting for opensearch-example-2 to join the cluster (2 pods remaining)")
      tick("Running")
      tick("Scaling up from 3 to 4 pods")

      expect(applied_max_unavailable).to eq [1, 0, 1, 0]
    end

    it "allows none after a reconciliation changed the StatefulSet, until the rolling restart works with it" do
      fake_watcher.report("green")
      tick("Running")
      fake_kubernetes.statefulset_generation = 2
      cluster.update(cluster_manifest(generation: 2))
      expect(applied_max_unavailable).to eq [1, 0]

      tick("Running")
      expect(applied_max_unavailable).to eq [1, 0, 1]
    end

    it "follows the phase of the rolling restart while publishing it fails" do
      fake_watcher.report("green")
      tick("Running")
      fake_kubernetes.status_patch_error = "Patch failed: 500 etcdserver: request timed out"
      tick("Rolling restart: restarting opensearch-example-2 (2 pods remaining)")
      fake_watcher.poll

      expect(applied_max_unavailable).to eq [1, 0]
    end

    it "leaves the budget of a cluster being deleted alone" do
      fake_watcher.report("green")
      tick("Running")
      cluster.update_phase("Deleting")

      expect(applied_max_unavailable).to eq [1]
    end

    it "retries a failed update on the next poll" do
      allow(fake_kubernetes.pod_disruption_budgets).to receive(:apply).and_raise(Kubernetes::Error, "Apply failed: 503")
      fake_watcher.report("green")
      tick("Running")
      expect(log_output).to include "PodDisruptionBudget of default/example: Kubernetes::Error: Apply failed: 503"

      allow(fake_kubernetes.pod_disruption_budgets).to receive(:apply).and_call_original
      fake_watcher.poll
      expect(applied_max_unavailable).to eq [1]
    end
  end
end
