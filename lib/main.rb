# frozen_string_literal: true

require "bundler/setup"

require "json"
require "logger"

require "active_support/all"
require "concurrent"

begin
  require "debug"
rescue LoadError
  # only available in development / test environments
end

require_relative "opensearch_operator/template"
require_relative "opensearch_operator/opensearch_watcher"
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
  HEALTH_POLL_INTERVAL = 15

  def initialize
    @clusters = Concurrent::Hash.new # uid => cluster
    @cluster_watchers = Concurrent::Hash.new # uid => OpensearchWatcher
    @stopping = false
    @monitor_thread = nil
  end

  def run
    setup_signal_traps
    # Initial list to get current resourceVersion
    clusters_response = CLUSTERS_RESOURCE.list

    initial_clusters = clusters_response.fetch("items")

    initial_clusters.each do |cluster|
      reconcile(cluster)
    end

    resource_version = clusters_response.dig("metadata", "resourceVersion")
    LOGGER.info "class=OpensearchOperator action=watching resource_version=#{resource_version}"

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
    uid = cluster_uid(cluster)

    existing_cluster = @clusters[uid]

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
      # CLUSTER_URL_OVERRIDE can be used for testing with port-forwarded clusters
      cluster_url = ENV["CLUSTER_URL_OVERRIDE"] || "http://opensearch-#{name}.#{namespace}.svc.cluster.local:9200"
      watcher = OpensearchWatcher.new(cluster_url).run do |new_state, changed_keys|
        update_status(uid, new_state, changed_keys)
      end
      @cluster_watchers[uid] = watcher
    end

    @clusters[uid] = cluster

    ensure_statefulset(namespace, name, cluster)
    ensure_service(namespace, name, cluster)
    ensure_dashboards_deployment(namespace, name, cluster)
    ensure_dashboards_service(namespace, name, cluster)
  end

  def finalize(cluster)
    cluster_uid(cluster)
    @clusters.delete(uid)
    watcher = @cluster_watchers.delete(uid)
    watcher&.stop

    LOGGER.info "Finalized #{cluster.dig('metadata', 'namespace')}/#{cluster.dig('metadata', 'name')}"
  end

  KEYS_AFFECTING_STATUS = %i[status number_of_nodes version].freeze

  # TODO: Maybe we should label which pod is master / manager?
  def update_status(cluster_uid, new_state, changed_keys)
    return unless changed_keys.intersect?(KEYS_AFFECTING_STATUS)

    cluster = @clusters[cluster_uid]
    return unless cluster

    namespace = cluster.dig("metadata", "namespace")
    name = cluster.dig("metadata", "name")

    params = {
      status: {
        health: new_state[:status]&.capitalize,
        nodes: new_state[:number_of_nodes],
        version: new_state[:version],
      },
    }

    CLUSTERS_RESOURCE.patch(name, namespace:, subresource: "status", params:)
  rescue StandardError => e
    LOGGER.error "Failed to update status for #{namespace}/#{name}: #{e.class}: #{e.message}"
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

  def cluster_uid(cluster)
    cluster.dig("metadata", "uid")
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
