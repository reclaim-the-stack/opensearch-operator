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

require_relative "opensearch_operator/certificate_generator"
require_relative "opensearch_operator/cluster"
require_relative "opensearch_operator/template"
require_relative "opensearch_operator/opensearch_watcher"
require_relative "kubernetes"

Kubernetes.field_manager = "opensearch-operator"

$stdout.sync = true
LOGGER = Logger.new $stdout, level: Logger.const_get((ENV["LOG_LEVEL"] || "DEBUG").upcase)

class OpensearchOperator
  CLUSTERS_RESOURCE = Kubernetes::Resource.new(
    "opensearches",
    group: "opensearch.reclaim-the-stack.com",
    version: "v1alpha1",
  )
  HEALTH_POLL_INTERVAL = 15

  def initialize
    @clusters = Concurrent::Hash.new # uid => cluster
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

    CLUSTERS_RESOURCE.watch(resource_version:) do |event|
      break if @stopping

      type = event.fetch("type")
      cluster_manifest = event.fetch("object")
      name = cluster_manifest.dig("metadata", "name")
      resource_version = cluster_manifest.dig("metadata", "resourceVersion")

      LOGGER.info "event=#{type} name=#{name} resource_version=#{resource_version}"

      case type
      when "ADDED", "MODIFIED"
        reconcile(cluster_manifest)
      when "DELETED"
        finalize(cluster_manifest)
      when "ERROR"
        message = "Watch ERROR event: #{event}"
        LOGGER.error message
        raise message
      end
    end
  end

  private

  def reconcile(cluster_manifest)
    uid = cluster_manifest.fetch("metadata").fetch("uid")

    existing_cluster = @clusters[uid]

    if existing_cluster
      existing_cluster.update(cluster_manifest)
    else
      cluster = Cluster.new(cluster_manifest)
      cluster.reconsile
      @clusters[cluster.uid] = cluster
    end
  end

  def finalize(cluster_manifest)
    uid = cluster_manifest.fetch("metadata").fetch("uid")
    cluster = @clusters.delete(uid)

    cluster&.finalize

    LOGGER.info "Finalized #{cluster.namespace}/#{cluster.name}"
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
end

OpensearchOperator.new.run if $PROGRAM_NAME == __FILE__
