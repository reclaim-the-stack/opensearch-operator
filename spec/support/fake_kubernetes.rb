# frozen_string_literal: true

# Stands in for the parts of the Kubernetes API a reconciliation of a Cluster talks to. It records applied manifests,
# status patches and created events. See FakeKubernetesHelpers#fake_kubernetes.
class FakeKubernetes
  PASSWORDS = %w[
    admin_password anomalyadmin_password kibanaserver_password logstash_password readall_password
    snapshotrestore_password metrics_password
  ].to_h { |key| [key, Base64.strict_encode64("password-#{key}")] }.freeze

  # Records applied manifests, the given methods implement anything else
  class Resource
    def initialize(kind, applied, **methods)
      @kind = kind
      @applied = applied
      methods.each { |name, implementation| define_singleton_method(name, &implementation) }
    end

    def apply(manifest)
      @applied[@kind] << manifest
      manifest
    end
  end

  attr_reader :applied, :events, :status_patches
  attr_accessor :existing_statefulset, :statefulset_generation, :statefulset_apply_error, :status_patch_error

  def initialize
    @applied = Hash.new { |hash, kind| hash[kind] = [] }
    @events = []
    @status_patches = []
    @existing_statefulset = { "code" => 404 }
    @statefulset_generation = 1
  end

  def secrets
    @secrets ||= Resource.new(
      :secrets,
      @applied,
      get: ->(_name, namespace:) { { "data" => PASSWORDS } },
      exists?: ->(_name, namespace:) { true },
    )
  end

  def configmaps = @configmaps ||= Resource.new(:configmaps, @applied)
  def services = @services ||= Resource.new(:services, @applied)
  def deployments = @deployments ||= Resource.new(:deployments, @applied)

  def statefulsets
    fake = self
    @statefulsets ||= Resource.new(
      :statefulsets,
      @applied,
      get: ->(_name, namespace:) { fake.existing_statefulset },
      # Like the API server, answers with the StatefulSet's generation
      apply: lambda do |manifest|
        fake.applied[:statefulsets] << manifest
        raise Kubernetes::Error, fake.statefulset_apply_error if fake.statefulset_apply_error

        manifest.merge("metadata" => manifest.fetch("metadata").merge("generation" => fake.statefulset_generation))
      end,
    )
  end

  def event_resource
    events = @events
    @event_resource ||= Resource.new(
      :events,
      @applied,
      create: ->(manifest) { events << manifest.slice("reason", "type", "message") },
    )
  end

  def patch_status(params)
    raise Kubernetes::Error, @status_patch_error if @status_patch_error

    @status_patches << JSON.parse(params.to_json).fetch("status")
    {}
  end

  # The condition of the given type in the latest status patch which carried conditions
  def condition(type)
    conditions = @status_patches.filter_map { |status| status["conditions"] }.last
    conditions.to_a.find { |condition| condition["type"] == type }
  end
end

module FakeKubernetesHelpers
  def fake_kubernetes
    @fake_kubernetes ||= FakeKubernetes.new.tap do |fake|
      allow(Kubernetes).to receive_messages(
        secrets: fake.secrets, configmaps: fake.configmaps, services: fake.services, deployments: fake.deployments,
        statefulsets: fake.statefulsets, events: fake.event_resource
      )
      allow(OpensearchOperator::CLUSTERS_RESOURCE).to receive(:patch) do |_name, namespace:, subresource: nil, params: {}|
        fake.patch_status(params)
      end
    end
  end
end

RSpec.configure { |config| config.include FakeKubernetesHelpers }
