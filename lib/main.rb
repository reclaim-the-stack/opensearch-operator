# frozen_string_literal: true

require "bundler/setup"

begin
  require "debug"
  require "dotenv/load"
rescue LoadError
  # only available in development / test environments
end

require "json"
require "logger"

require "active_support/all"
require "concurrent"
require "securerandom"

require_relative "kubernetes"
require_relative "sentry"

require_relative "opensearch_operator/certificate_generator"
require_relative "opensearch_operator/cluster"
require_relative "opensearch_operator/template"
require_relative "opensearch_operator/opensearch_watcher"
require_relative "opensearch_operator/rolling_restart"

Kubernetes.field_manager = "opensearch-operator"

$stdout.sync = true
LOGGER = Logger.new $stdout, level: Logger.const_get((ENV["LOG_LEVEL"] || "DEBUG").upcase)

class OpensearchOperator
  CLUSTERS_RESOURCE = Kubernetes::Resource.new(
    "opensearches",
    group: "opensearch.reclaim-the-stack.com",
    version: "v1alpha1",
  )
  DEFAULT_OPERATOR_NAMESPACE = "opensearch-operator"
  HEALTH_POLL_INTERVAL = 15

  # Lazily create or fetch the singleton metrics user password. The password is unique per
  # installation of the operator, but shared across all OpenSearch clusters managed by it.
  def self.metrics_password
    return @metrics_password if @metrics_password

    secret_name = "opensearch-metrics-basic-auth"
    internal_namespace_file = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"
    namespace = File.exist?(internal_namespace_file) ? File.read(internal_namespace_file) : DEFAULT_OPERATOR_NAMESPACE
    secret = Kubernetes.secrets.get(secret_name, namespace:)

    @metrics_password =
      if secret["code"] == 404
        password = SecureRandom.hex
        Kubernetes.secrets.create(
          "metadata" => {
            "name" => secret_name,
            "namespace" => namespace,
          },
          "type" => "kubernetes.io/basic-auth",
          "stringData" => {
            "username" => "metrics",
            "password" => password,
          },
        )
        LOGGER.info "Created metrics basic auth secret #{namespace}/#{secret_name}"
        password
      else
        Base64.strict_decode64(secret.fetch("data").fetch("password"))
      end
  end

  def initialize
    @clusters = Concurrent::Hash.new # uid => cluster
    @stopping = false
    @monitor_thread = nil
  end

  def run
    setup_signal_traps
    LOGGER.info "class=OpensearchOperator action=watching"

    # The existing clusters arrive as ADDED events before any changes
    CLUSTERS_RESOURCE.watch do |event|
      break if @stopping

      type = event.fetch("type")
      cluster_manifest = event.fetch("object")
      namespace = cluster_manifest.dig("metadata", "namespace")
      name = cluster_manifest.dig("metadata", "name")
      resource_version = cluster_manifest.dig("metadata", "resourceVersion")

      LOGGER.info "event=#{type} name=#{name} resource_version=#{resource_version}"

      case type
      when "ADDED", "MODIFIED"
        # A resource with finalizers, eg. the foregroundDeletion one of Argo CD's cascading deletes, only gets a
        # deletionTimestamp (and a new generation) until its owned resources are gone. Reconciling it would recreate them.
        if cluster_manifest.dig("metadata", "deletionTimestamp")
          finalize(cluster_manifest)
        else
          reconcile(cluster_manifest)
        end
      when "DELETED"
        finalize(cluster_manifest)
      end
    rescue StandardError => e
      # One failing cluster must neither take down the operator nor stall the events of the other clusters. Its events
      # are handled again on the next change or watch resync (see Kubernetes::WATCH_RESYNC_INTERVAL).
      Sentry.capture_exception(e)
      LOGGER.error "Failed to handle #{type} event for #{namespace}/#{name}: #{e.class}: #{e.message}"
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
    # Not tracked when handling its events failed so far, or once finalized when its deletion started
    cluster = @clusters.delete(uid)
    return unless cluster

    cluster.finalize
    LOGGER.info "Finalized #{cluster_manifest.dig('metadata', 'namespace')}/#{cluster_manifest.dig('metadata', 'name')}"
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

if $PROGRAM_NAME == __FILE__
  begin
    OpensearchOperator.new.run
  rescue StandardError => e
    # Report crashes before the process exits, Sentry has no hook for unhandled exceptions on its own
    Sentry.capture_exception(e)
    raise
  end
end
