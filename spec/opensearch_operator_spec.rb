# frozen_string_literal: true

RSpec.describe OpensearchOperator do
  subject(:operator) { OpensearchOperator.new }

  # Hands the events to the operator's watch handler, like a watch whose stream ends after them
  def run(*events)
    allow(OpensearchOperator::CLUSTERS_RESOURCE).to receive(:watch) { |&handler| events.each { |event| handler.call(event) } }
    allow(operator).to receive(:setup_signal_traps) # would replace the signal handlers of RSpec
    operator.run
  end

  def event(type, name, generation: 1, deleting: false)
    metadata = { "name" => name, "namespace" => "default", "uid" => "uid-#{name}", "generation" => generation }
    metadata["deletionTimestamp"] = "2026-09-29T14:12:37Z" if deleting
    { "type" => type, "object" => { "metadata" => metadata, "spec" => {} } }
  end

  context "with clusters which record the calls they get" do
    let(:calls) { [] }

    before do
      allow(Sentry).to receive(:capture_exception)
      allow(OpensearchOperator::Cluster).to receive(:new) do |manifest|
        name = manifest.dig("metadata", "name")
        calls << [:new, name]
        instance_double(OpensearchOperator::Cluster, uid: manifest.dig("metadata", "uid")).tap do |cluster|
          allow(cluster).to receive(:reconsile) do
            calls << [:reconsile, name]
            raise Kubernetes::Error, "Apply failed: 422 volumeClaimTemplates is immutable" if name == "broken"
          end
          allow(cluster).to receive(:update) do |updated_manifest|
            calls << [:update, name, updated_manifest.dig("metadata", "generation")]
          end
          allow(cluster).to receive(:finalize) { calls << [:finalize, name] }
          allow(cluster).to receive(:update_phase) { |phase| calls << [:update_phase, name, phase] }
        end
      end
    end

    def lifecycle_logs = log_output.scan(/(?:Finalized|Stopped managing) .*$/)

    it "keeps handling the events of the other clusters when handling one of them fails" do
      run(event("ADDED", "broken"), event("ADDED", "healthy"), event("MODIFIED", "healthy", generation: 2))

      expect(calls).to eq [
        [:new, "broken"], [:reconsile, "broken"], [:new, "healthy"], [:reconsile, "healthy"], [:update, "healthy", 2]
      ]
      expect(Sentry).to have_received(:capture_exception).once.with(an_instance_of(Kubernetes::Error))
      expect(log_output).to include "Failed to handle ADDED event for default/broken: Kubernetes::Error: Apply failed: 422"
    end

    it "keeps tracking a cluster whose first reconciliation failed, which retains the failure for the retries" do
      run(event("ADDED", "broken"), event("MODIFIED", "broken"), event("DELETED", "broken"))

      expect(calls).to eq [[:new, "broken"], [:reconsile, "broken"], [:update, "broken", 1], [:finalize, "broken"]]
    end

    describe "deleting clusters" do
      it "stops managing a cluster once its deletion starts, which finalizers like Argo CD's foregroundDeletion hold up" do
        run(
          event("ADDED", "example"),
          event("MODIFIED", "example"), # eg. the status patch of the reconciliation
          event("MODIFIED", "example", generation: 2, deleting: true), # the deletion started
          event("MODIFIED", "example", generation: 2, deleting: true), # eg. the owned resources are gone
          event("DELETED", "example", generation: 2, deleting: true),
        )

        expect(calls).to eq [
          [:new, "example"], [:reconsile, "example"], [:update, "example", 1], [:finalize, "example"],
          [:update_phase, "example", "Deleting"]
        ]
        expect(lifecycle_logs).to eq ["Stopped managing default/example, its deletion has started"]
        expect(Sentry).not_to have_received(:capture_exception)
      end

      it "ignores a cluster which is already being deleted when the operator starts" do
        run(event("ADDED", "example", deleting: true), event("DELETED", "example", deleting: true))

        expect(calls).to be_empty
        expect(lifecycle_logs).to be_empty
        expect(Sentry).not_to have_received(:capture_exception)
      end

      it "finalizes a cluster deleted without finalizers" do
        run(event("ADDED", "example"), event("DELETED", "example"))

        expect(calls).to eq [[:new, "example"], [:reconsile, "example"], [:finalize, "example"]]
        expect(lifecycle_logs).to eq ["Finalized default/example"]
        expect(Sentry).not_to have_received(:capture_exception)
      end
    end
  end

  context "with a new cluster whose first reconciliation fails" do
    let(:added) { { "type" => "ADDED", "object" => cluster_manifest } }

    before do
      fake_kubernetes.statefulset_apply_error = "Apply failed: 500 etcdserver: request timed out"
      fake_watcher
      travel_to Time.utc(2026, 9, 30, 12)
      run(added)
    end

    it "retries at most once per retry interval, reporting the failure once" do
      run(added, added) # eg. the MODIFIED events of the status patch which published the failure
      expect(fake_kubernetes.applied[:statefulsets].size).to eq 1

      travel OpensearchOperator::Cluster::RECONCILE_RETRY_INTERVAL + 1.second
      run(added) # the next watch resync
      expect(fake_kubernetes.applied[:statefulsets].size).to eq 2
      expect(fake_kubernetes.events.map { |event| event["reason"] }).to eq ["ReconcileFailed"]
    end

    it "reconciles it on a resync once the cause is gone" do
      fake_kubernetes.statefulset_apply_error = nil
      travel OpensearchOperator::Cluster::RECONCILE_RETRY_INTERVAL + 1.second
      run(added)

      expect(fake_kubernetes.condition("Reconciled")).to include("status" => "True", "observedGeneration" => 1)
      expect(fake_kubernetes.status_patches.last).to include("observedGeneration" => 1)
    end
  end
end
