require "bcrypt"

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
      ensure_credentials_secret
      ensure_certificates_secret
      ensure_security_config
      ensure_service
      ensure_statefulset
      ensure_dashboards_deployment
      ensure_dashboards_service
    end

    def watch
      return @watcher if @watcher

      # CLUSTER_HOST_OVERRIDE=localhost can be used for testing with port-forwarded clusters
      host = ENV["CLUSTER_HOST_OVERRIDE"] || "opensearch-#{name}.#{namespace}.svc.cluster.local"
      cluster_url = "http://admin:#{admin_password}@#{host}:9200"
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

    def admin_password
      @admin_password ||= Base64.strict_decode64(secret.dig("data", "admin_password"))
    end

    def secret
      return @secret if @secret

      secret_name = "opensearch-#{name}-credentials"
      secret = Kubernetes.secrets.get(secret_name, namespace:)
      return if secret["code"] == 404

      @secret = secret
    end

    def ensure_credentials_secret
      return if secret

      admin_password = SecureRandom.hex
      anomalyadmin_password = SecureRandom.hex
      kibanaserver_password = SecureRandom.hex
      logstash_password = SecureRandom.hex
      readall_password = SecureRandom.hex
      snapshotrestore_password = SecureRandom.hex
      metrics_password = "metrics"

      secret = Template["credentials_secret"].render(
        name:,
        namespace:,
        owner_references:,
        admin_password:,
        anomalyadmin_password:,
        kibanaserver_password:,
        logstash_password:,
        readall_password:,
        snapshotrestore_password:,
        metrics_password:,
      )

      Kubernetes.secrets.apply(secret)
    end

    def ensure_certificates_secret
      return if Kubernetes.secrets.exists?("opensearch-#{name}-certificates", namespace:)

      certificates = CertificateGenerator.generate

      certificates_secret = Template["certificates_secret"].render(
        name:,
        namespace:,
        owner_references:,
        ca_crt: certificates.ca_crt.to_json,
        ca_key: certificates.ca_key.to_json,
        node_crt: certificates.node_crt.to_json,
        node_key: certificates.node_key.to_json,
        admin_crt: certificates.admin_crt.to_json,
        admin_key: certificates.admin_key.to_json,
      )

      Kubernetes.secrets.apply(certificates_secret)
    end

    def ensure_security_config
      admin_password = Base64.strict_decode64(secret.dig("data", "admin_password"))
      anomalyadmin_password = Base64.strict_decode64(secret.dig("data", "anomalyadmin_password"))
      kibanaserver_password = Base64.strict_decode64(secret.dig("data", "kibanaserver_password"))
      logstash_password = Base64.strict_decode64(secret.dig("data", "logstash_password"))
      readall_password = Base64.strict_decode64(secret.dig("data", "readall_password"))
      snapshotrestore_password = Base64.strict_decode64(secret.dig("data", "snapshotrestore_password"))
      metrics_password = Base64.strict_decode64(secret.dig("data", "metrics_password"))

      internal_users_yaml = Template["_internal_users"].render(
        admin_password_hash: BCrypt::Password.create(admin_password),
        anomalyadmin_password_hash: BCrypt::Password.create(anomalyadmin_password),
        kibanaserver_password_hash: BCrypt::Password.create(kibanaserver_password),
        logstash_password_hash: BCrypt::Password.create(logstash_password),
        readall_password_hash: BCrypt::Password.create(readall_password),
        snapshotrestore_password_hash: BCrypt::Password.create(snapshotrestore_password),
        metrics_password_hash: BCrypt::Password.create(metrics_password),
      ).to_json

      config_map = Template["security_configmap"].render(
        name:,
        namespace:,
        owner_references:,
        internal_users_yaml:,
      )

      Kubernetes.configmaps.apply(config_map)
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

      startup_script = Template["_startup_script"].render(
        name:,
        creation_timestamp_epoch:,
      ).to_json

      statefulset = Template["statefulset"].render(
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
        startup_script:,
      )

      Kubernetes.statefulsets.apply(statefulset)
    end

    def ensure_dashboards_deployment
      dashboards_image = "opensearchproject/opensearch-dashboards:#{version}"
      opensearch_hosts = "http://opensearch-#{name}.#{namespace}.svc.cluster.local:9200"

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
