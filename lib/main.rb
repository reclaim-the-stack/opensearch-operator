# frozen_string_literal: true

require "bundler/setup"

require "json"
require "logger"
require "k8s-ruby"

require_relative "opensearch_operator/version"

$stdout.sync = true
LOGGER = Logger.new $stdout, level: Logger.const_get((ENV["LOG_LEVEL"] || "INFO").upcase)

class OpensearchOperator
  FIELD_MANAGER = "opensearch-operator"
  GROUP = "opensearch.reclaim-the-stack.com"
  VERSION = "v1alpha1"
  PLURAL = "opensearchclusters"

  def initialize
    @client = begin
      K8s::Client.in_cluster_config
    rescue K8s::Error::Configuration
      LOGGER.warn "Falling back to local kubeconfig"
      K8s::Client.config(K8s::Config.load_file(ENV["KUBECONFIG"] || File.join(Dir.home, ".kube", "config")))
    end
    @clusters = @client.api("#{GROUP}/#{VERSION}").resource(PLURAL)
    @core = @client.api("v1")
    @apps = @client.api("apps/v1")
  end

  def run
    setup_signal_traps
    LOGGER.info "Starting watch on #{PLURAL}.#{GROUP}/#{VERSION}"

    @clusters.watch do |event|
      resource = event.resource
      next if resource.nil?

      LOGGER.info "#{event.type} #{resource.metadata.namespace}/#{resource.metadata.name}"

      case event.type # "ADDED", "MODIFIED", "DELETED", "BOOKMARK", "ERROR"
      when "ADDED", "MODIFIED"
        reconcile(resource)
      when "DELETED"
        finalize(resource)
      end
    end
  rescue StandardError => e
    if e.is_a?(OpenSSL::SSL::SSLErrorWaitReadable) && @stopping
      # Ignore SSL errors during shutdown
    else
      LOGGER.error("Watch cluster crashed: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
      sleep 2
      retry
    end
  end

  def setup_signal_traps
    @stopping = false
    %w[INT TERM].each do |sig|
      Signal.trap(sig) do
        unless @stopping
          puts "Received #{sig}, shutting down..."
          @stopping = true
          exit
        end
      end
    end
  end

  private

  def reconcile(cluster)
    namespace = cluster.metadata.namespace || "default"
    name = cluster.metadata.name
    spec = cluster.spec

    image = spec.image
    replicas = spec.replicas
    disk_size = spec.diskSize

    ensure_statefulset(namespace, name, image, replicas, disk_size)
    ensure_service(namespace, name)

    # (Optional) update status
    begin
      st = @apps.resource("statefulsets", namespace:).get(name)
      ready = st.status&.readyReplicas.to_i
      patch = { status: { phase: ready >= replicas ? "Ready" : "Reconciling", readyReplicas: ready } }
      @clusters.merge_patch(name, patch, namespace:)
    rescue StandardError => e
      LOGGER.warn "Status update failed: #{e.message}"
    end
  end

  def finalize(cluster)
    # For now: do nothing (let GC handle child resources or add OwnerReferences).
    # Optional: implement PVC cleanup behind a finalizer.
    LOGGER.info "Finalized #{cluster.metadata.namespace}/#{cluster.metadata.name}"
  end

  def ensure_service(namespace, name)
    body = {
      apiVersion: "v1", kind: "Service",
      metadata: { name:, labels: { "app.kubernetes.io/name" => name } },
      spec: {
        type: "ClusterIP",
        ports: [{ name: "http", port: 9200, targetPort: 9200 }],
        selector: { "app.kubernetes.io/name" => name },
      }
    }
    services = @core.resource("services", namespace:)

    apply(services, body)
  end

  def ensure_statefulset(namespace, name, image, replicas, disk_size)
    body = {
      apiVersion: "apps/v1", kind: "StatefulSet",
      metadata: { name:, namespace:, labels: { "app.kubernetes.io/name" => name } },
      spec: {
        serviceName: name,
        replicas: replicas,
        selector: { matchLabels: { "app.kubernetes.io/name" => name } },
        template: {
          metadata: { labels: { "app.kubernetes.io/name" => name } },
          spec: {
            containers: [
              {
                name: "opensearch",
                image: image,
                ports: [
                  { name: "http", containerPort: 9200 },
                  { name: "metrics", containerPort: 9600 },
                ],
                env: [
                  # MVP runs single-node; remove this once you add real clustering logic
                  { name: "discovery.type", value: "single-node" },
                  { name: "OPENSEARCH_JAVA_OPTS", value: "-Xms512m -Xmx512m" },
                ],
                volumeMounts: [{ name: "data", mountPath: "/usr/share/opensearch/data" }],
                readinessProbe: {
                  httpGet: { path: "/_cluster/health", port: 9200 },
                  initialDelaySeconds: 20, periodSeconds: 10, failureThreshold: 6
                },
                resources: {}, # fill from spec["resources"] if provided
              },
            ],
          },
        },
        volumeClaimTemplates: [
          {
            metadata: { name: "data" },
            spec: {
              accessModes: ["ReadWriteOnce"],
              resources: { requests: { storage: disk_size } },
            },
          },
        ],
      }
    }
    statefulsets = @apps.resource("statefulsets", namespace:)

    apply(statefulsets, body)
  end

  def apply(client, hash)
    resource = K8s::Resource.new(hash)
    client.create_resource(resource)
  end
end

OpensearchOperator.new.run if $PROGRAM_NAME == __FILE__
