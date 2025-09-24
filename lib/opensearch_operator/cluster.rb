require "securerandom"
require "time"

class OpensearchOperator
  class Cluster
    KEYS_AFFECTING_STATUS = %i[status number_of_nodes version].freeze

    def initialize(manifest)
      @manifest = manifest
    end

    def name = @name ||= @manifest.fetch("metadata").fetch("name")
    def namespace = @namespace ||= @manifest.fetch("metadata").fetch("namespace")
    def uid = @uid ||= @manifest.fetch("metadata").fetch("uid")
    def spec = @spec ||= @manifest.fetch("spec")
    def image = @image ||= spec.fetch("image")
    def replicas = @replicas ||= spec.fetch("replicas")
    def disk_size = @storage_size ||= spec.fetch("diskSize")

    def version = @version ||= image.split(":").last

    delegate :equal?, to: :@manifest
    delegate :dig, to: :@manifest

    def update(new_manifest)
      spec_changed = spec != new_manifest.fetch("spec")

      @manifest = new_manifest

      if spec_changed
        LOGGER.info "Spec changed for #{namespace}/#{name}, reconsiling"
        reconsile
      else
        LOGGER.info "No changes in spec for #{namespace}/#{name}, skipping"
      end
    end

    def reconsile
      ensure_secret
      ensure_service
      ensure_statefulset
      ensure_dashboards_deployment
      ensure_dashboards_service
    end

    def watch
      return @watcher if @watcher

      # CLUSTER_HOST_OVERRIDE=localhost can be used for testing with port-forwarded clusters
      host = ENV["CLUSTER_HOST_OVERRIDE"] || "opensearch-#{name}.#{namespace}.svc.cluster.local"
      cluster_url = "https://admin:#{password}@#{host}:9200"
      @watcher = OpensearchWatcher.new(cluster_url).run do |new_state, changed_keys|
        update_status(new_state, changed_keys)
      end
    end

    def finalize
      @watcher&.stop
    end

    # TODO: Maybe we should label which pod is master / manager?
    def update_status(new_state, changed_keys)
      return unless changed_keys.intersect?(KEYS_AFFECTING_STATUS)

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

    private

    def password
      return @password if @password

      secret_name = "opensearch-#{name}-admin"
      secret = Kubernetes.secrets.get(secret_name, namespace:)
      return if secret["code"] == 404

      @password = Base64.strict_decode64(secret.dig("data", "password"))
    end

    # Password must be minimum 8 characters long and must contain at least one uppercase
    # letter, one lowercase letter, one digit, and one non letter/digit character.
    REQUIRED_PASSWORD_CHARACTERS = "Ul1_"

    def ensure_secret
      return if password

      @password = "#{REQUIRED_PASSWORD_CHARACTERS}#{SecureRandom.hex}"

      secret = Template["secret"].render(
        name:,
        namespace:,
        owner_references:,
        password:,
      )

      Kubernetes.secrets.apply(secret)
    end

    def ensure_service
      service = Template["service"].render(
        name:,
        namespace:,
        owner_references:,
      )

      Kubernetes.services.apply(service)
    end

    def ensure_statefulset
      creation_timestamp_epoch = Time.parse(@manifest.dig("metadata", "creationTimestamp")).to_i
      node_selector = spec["nodeSelector"].to_json
      resources = spec["resources"].to_json
      tolerations = spec["tolerations"].to_json

      statefulset = Template["statefulset"].render(
        creation_timestamp_epoch:,
        disk_size:,
        image:,
        name:,
        namespace:,
        node_selector:,
        owner_references:,
        replicas:,
        resources:,
        tolerations:,
        version:,
      )

      Kubernetes.statefulsets.apply(statefulset)
    end

    def ensure_dashboards_deployment
      dashboards_image = "opensearchproject/opensearch-dashboards:#{version}"
      opensearch_hosts = "https://#{name}-service.#{namespace}.svc.cluster.local:9200"

      dashboards_deployment = Template["dashboards_deployment"].render(
        dashboards_image:,
        name:,
        namespace:,
        opensearch_hosts:,
        owner_references:,
      )

      Kubernetes.deployments.apply(dashboards_deployment)
    end

    def ensure_dashboards_service
      dashboards_service = Template["dashboards_service"].render(
        name:,
        namespace:,
        owner_references:,
      )
      Kubernetes.services.apply(dashboards_service)
    end

    def owner_references
      @owner_references ||= [
        {
          "apiVersion" => @manifest.fetch("apiVersion"),
          "kind" => @manifest.fetch("kind"),
          "name" => name,
          "uid" => uid,
          "controller" => true,
          "blockOwnerDeletion" => true,
        },
      ].to_json
    end
  end
end
