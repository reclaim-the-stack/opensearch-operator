# frozen_string_literal: true

require "bundler/setup"

require "active_support/all"
require "json"
require "logger"

begin
  require "debug"
rescue LoadError
  # only available in development / test environments
end

require_relative "opensearch_operator/version"
require_relative "opensearch_operator/template"
require_relative "kubernetes"

Kubernetes.field_manager = "opensearch-operator"

$stdout.sync = true
LOGGER = Logger.new $stdout, level: Logger.const_get((ENV["LOG_LEVEL"] || "DEBUG").upcase)

class OpensearchOperator
  CLUSTERS_RESOURCE = Kubernetes::Resource.new(
    "opensearchclusters",
    group: "opensearch.reclaim-the-stack.com",
    version: "v1alpha1",
  )

  def initialize
    @clusters = []
    @stopping = false
  end

  def run
    setup_signal_traps
    # Initial list to get current resourceVersion
    clusters_response = CLUSTERS_RESOURCE.list

    @clusters = clusters_response.fetch("items")

    @clusters.each do |cluster|
      reconcile(cluster)
    end

    resource_version = clusters_response.dig("metadata", "resourceVersion")
    LOGGER.info "Starting watch on OpenSearchClusters from resource_version=#{resource_version}"

    until @stopping
      CLUSTERS_RESOURCE.watch(resource_version:) do |event|
        break if @stopping

        type = event.fetch("type")
        cluster = event.fetch("object")
        name = cluster.dig("metadata", "name")
        resource_version = cluster.dig("metadata", "resourceVersion")

        LOGGER.info "event=#{type} name=#{name} resource_version=#{resource_version}"

        case type
        when "ADDED", "MODIFIED"
          reconcile(cluster)
        when "DELETED"
          finalize(cluster)
        when "ERROR"
          message = "Watch ERROR event: #{event}"
          LOGGER.error message
          raise message
        end
      end
    end

    LOGGER.info "Shutdown complete"
  end

  def setup_signal_traps
    @stopping = false
    %w[INT TERM].each do |sig|
      Signal.trap(sig) do
        next if @stopping

        puts "Received #{sig}, initiating shutdown..."
        @stopping = true
        exit # TODO: Gracefully
      end
    end
  end

  private

  def reconcile(cluster)
    namespace = cluster.dig("metadata", "namespace")
    name = cluster.dig("metadata", "name")

    existing_cluster = @clusters.find do |existing_cluster|
      existing_cluster.dig("metadata", "uid") == cluster.dig("metadata", "uid")
    end

    if existing_cluster
      if existing_cluster.equal?(cluster)
        # This is the initial list, we'll proceed to ensure resources exist
      elsif existing_cluster["spec"] == cluster["spec"]
        LOGGER.info "No changes in spec for #{namespace}/#{name}, skipping"
        return
      else
        LOGGER.info "Spec changed for #{namespace}/#{name}, reconsiling"
      end
    else
      @clusters << cluster
    end

    ensure_statefulset(namespace, name, cluster)
    ensure_service(namespace, name, cluster)
    ensure_dashboards_deployment(namespace, name, cluster)
    ensure_dashboards_service(namespace, name, cluster)

    # Update status
    # TODO: Move to a separate watch loops
    statefulset = Kubernetes.statefulsets.get(name, namespace:)

    spec = cluster.fetch("spec")

    image = spec.fetch("image")
    version = image.split(":").last
    replicas = spec.fetch("replicas")

    ready = statefulset.dig("status", "readyReplicas") || 0
    phase = ready >= replicas ? "Ready" : "Reconciling"

    patch = {
      status: {
        phase:,
        nodes: ready,
        version:,
      },
    }

    LOGGER.info "Updating status of #{namespace}/#{name} to phase=#{phase}, nodes=#{ready}"
    CLUSTERS_RESOURCE.patch(name, namespace:, subresource: "status", params: patch)
  end

  def finalize(cluster)
    # For now: do nothing (let GC handle child resources or add OwnerReferences).
    # Optional: implement PVC cleanup behind a finalizer.
    LOGGER.info "Finalized #{cluster.dig('metadata', 'namespace')}/#{cluster.dig('metadata', 'name')}"
  end

  def ensure_service(namespace, name, cluster)
    owner_references = owner_references(cluster).to_json

    service = Template["service"].render(
      name:,
      namespace:,
      owner_references:,
    )

    Kubernetes.services.apply(service)
  end

  def ensure_dashboards_service(namespace, name, cluster)
    owner_references_json = owner_references(cluster).to_json

    service = Template["dashboards_service"].render(
      name:,
      namespace:,
      owner_references: owner_references_json,
    )

    Kubernetes.services.apply(service)
  end

  def ensure_dashboards_deployment(namespace, name, cluster)
    spec = cluster.fetch("spec")

    image = spec.fetch("image")
    version = image.include?(":") ? image.split(":").last : "latest"
    dashboards_image = "opensearchproject/opensearch-dashboards:#{version}"
    opensearch_hosts = "http://opensearch-#{name}:9200"
    owner_references_json = owner_references(cluster).to_json

    deployment = Template["dashboards_deployment"].render(
      name:,
      namespace:,
      dashboards_image:,
      opensearch_hosts:,
      owner_references: owner_references_json,
    )

    Kubernetes.deployments.apply(deployment)
  end

  def ensure_statefulset(namespace, name, cluster)
    spec = cluster.fetch("spec")

    creation_timestamp_epoch = Time.parse(cluster.dig("metadata", "creationTimestamp")).to_i
    image = spec.fetch("image")
    version = image.split(":").last
    replicas = spec.fetch("replicas")
    disk_size = spec.fetch("diskSize")
    node_selector = spec["nodeSelector"].to_json
    tolerations = spec["tolerations"].to_json
    resources = spec["resources"].to_json
    owner_references = owner_references(cluster).to_json

    statefulset = Template["statefulset"].render(
      name:,
      namespace:,
      creation_timestamp_epoch:,
      image:,
      version:,
      replicas:,
      disk_size:,
      node_selector:,
      tolerations:,
      resources:,
      owner_references:,
    )

    Kubernetes.statefulsets.apply(statefulset)
  end

  def owner_references(cluster)
    [
      {
        "apiVersion" => cluster.fetch("apiVersion"),
        "kind" => cluster.fetch("kind"),
        "name" => cluster.dig("metadata", "name"),
        "uid" => cluster.dig("metadata", "uid"),
        "controller" => true,
        "blockOwnerDeletion" => true,
      },
    ]
  end
end

OpensearchOperator.new.run if $PROGRAM_NAME == __FILE__
