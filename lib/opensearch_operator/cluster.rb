# frozen_string_literal: true

require "bcrypt"

require "securerandom"
require "time"
require "yaml"

class OpensearchOperator
  class Cluster
    KEYS_AFFECTING_STATUS = %i[status number_of_nodes version].freeze

    def initialize(manifest)
      @manifest = manifest
    end

    def name = @manifest.fetch("metadata").fetch("name")
    def namespace = @manifest.fetch("metadata").fetch("namespace")
    def uid = @manifest.fetch("metadata").fetch("uid")
    def spec = @manifest.fetch("spec")
    def image = spec.fetch("image")
    def replicas = spec.fetch("replicas")
    def disk_size = spec.fetch("diskSize")

    def version = image.split(":").last

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

      initialize_or_trigger_watcher
    end

    def initialize_or_trigger_watcher
      if @watcher
        @watcher.on_green { upsert_snapshot_repositories }
      else
        # CLUSTER_HOST_OVERRIDE=localhost can be used for testing with port-forwarded clusters
        host = ENV["CLUSTER_HOST_OVERRIDE"] || "opensearch-#{name}.#{namespace}.svc.cluster.local"
        cluster_url = "http://admin:#{admin_password}@#{host}:9200"
        @watcher = OpensearchWatcher.new(cluster_url)
        @watcher.on_green { upsert_snapshot_repositories }
        @watcher.run do |new_state, changed_keys|
          update_status(new_state, changed_keys)
        end
      end
    end

    def finalize
      @watcher&.stop
    end

    # Configures snapshot repositories and reconciles associated lifecycle policies in OpenSearch.
    def upsert_snapshot_repositories
      existing_policies = @watcher.client.http.get("/_plugins/_sm/policies").fetch("policies")

      spec.fetch("snapshotRepositories").each do |repository|
        repository_name = repository.fetch("name")

        params = {
          repository: repository_name,
          body: {
            type: "s3",
            settings: {
              base_path: repository["base_path"].presence,
              bucket: repository.fetch("bucket"),
              client: repository_name,
              # NOTE: hashed_prefix is default but this creates hashed prefixes at the root of the bucket
              # which makes it unsuitable when sharing a snapshot bucket with other clusters.
              shard_path_type: "hashed_infix",
            },
          },
        }

        begin
          @watcher.client.snapshot.create_repository(params)
        rescue StandardError => e
          Sentry.capture_exception(e)
          LOGGER.error "Failed to upsert snapshot repository for cluster #{namespace}/#{name}: #{e.class}: #{e.message}"
          next
        end

        LOGGER.info "Ensured snapshot repository #{repository_name} in cluster #{namespace}/#{name}"


        reconcile_snapshot_policies(repository_name, repository.fetch("policies"), existing_policies)
      end
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
      Sentry.capture_exception(e)
      LOGGER.error "Failed to update status for #{namespace}/#{name}: #{e.class}: #{e.message}"
    end

    private

    def admin_password
      @admin_password ||= Base64.strict_decode64(secret.dig("data", "admin_password"))
    end

    def reconcile_snapshot_policies(repository_name, policies, existing_policies)
      policies.each do |policy|
        LOGGER.debug "Reconciling snapshot policy #{policy.fetch('name')} for repository #{repository_name} in cluster #{namespace}/#{name}"
        LOGGER.debug "Policy details: #{policy}"
        policy_name = "#{repository_name}-#{policy.fetch('name')}"
        payload = {
          creation: {
            schedule: {
              cron: {
                expression: policy.fetch("schedule"),
                timezone: "UTC",
              },
            },
          },
          deletion: {
            condition: {
              max_age: policy.fetch("max_age"),
            },
          },
          snapshot_config: {
            repository: repository_name,
            include_global_state: false,
            indices: "*,-.opendistro_security",
          },
        }

        existing_policy_document = existing_policies.find do |policy_document|
          policy = policy_document.fetch("sm_policy")
          policy.fetch("snapshot_config").fetch("repository") == repository_name && policy.fetch("name") == policy_name
        end

        if existing_policy_document
          # NOTE: This approach to detecting changes was too naive as OpenSearch adds and changes fields. eg.
          # if the user pushes max_age: 24h it gets returned as max_age: 1d. Hence we've resorted to always
          # updating the policies for now even if they haven't actually changed.
          # next if existing_policy_document.fetch("sm_policy").slice(*payload.keys) == payload

          @watcher.client.http.put(
            "/_plugins/_sm/policies/#{policy_name}",
            params: {
              if_seq_no: existing_policy_document.fetch("_seq_no"),
              if_primary_term: existing_policy_document.fetch("_primary_term"),
            },
            body: payload,
          )
          LOGGER.info "Updated snapshot lifecycle policy #{policy_name} in cluster #{namespace}/#{name}"
        else
          @watcher.client.http.post("/_plugins/_sm/policies/#{policy_name}", body: payload)
          LOGGER.info "Created snapshot lifecycle policy #{policy_name} in cluster #{namespace}/#{name}"
        end
      end

      # Delete policies that are not in the spec anymore
      expired_policies = existing_policies.select do |existing_policy_document|
        existing_policy = existing_policy_document.fetch("sm_policy")
        existing_policy.fetch("snapshot_config").fetch("repository") == repository_name &&
          policies.none? { |p| "#{repository_name}-#{p.fetch('name')}" == existing_policy.fetch("name") }
      end
      expired_policies.each do |expired_policy_document|
        policy_name = expired_policy_document.fetch("sm_policy").fetch("name")

        @watcher.client.http.delete("/_plugins/_sm/policies/#{policy_name}")
        LOGGER.info "Deleted snapshot lifecycle policy #{policy_name} in cluster #{namespace}/#{name}"
      end
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
      metrics_password = OpensearchOperator.metrics_password

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

      roles_yaml = Template["_roles"].render.to_json

      config_map = Template["security_configmap"].render(
        name:,
        namespace:,
        owner_references:,
        internal_users_yaml:,
        roles_yaml:,
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

      # Prometheus exporter plugin version must be synced with OpenSearch version:
      # https://github.com/opensearch-project/opensearch-prometheus-exporter/blob/main/COMPATIBILITY.md
      prometheus_exporter_version = "#{version}.0"

      # local cache for repository secrets in the shape { name => secret }
      repository_secrets = {}

      repositories = spec["snapshotRepositories"] || []
      repositories.each do |repository|
        repository["region"] ||= "us-east-1"
        repository["endpoint"] ||= "s3.#{repository['region']}.amazonaws.com"
        repository["protocol"] ||= "https"

        repository["access_key_secret"] = repository.fetch("accessKeyId")
        repository["secret_key_secret"] = repository.fetch("secretAccessKey")
      end

      config_yaml_string = spec["config"].present? ? YAML.dump(spec["config"]).delete_prefix("---\n") : nil

      startup_script = Template["_startup_script"].render(
        creation_timestamp_epoch:,
        config_yaml_string:,
        has_repositories: repositories.any?,
        name:,
        prometheus_exporter_version:,
        repositories:,
      ).to_json

      # Heap size is set to 50% of the memory limit, up to a maximum of 31Gi to avoid compressed oops being disabled
      # NOTE: Our CRD makes resources.limits.memory mandatory and requires a minumum of 4Gi
      memory = spec.fetch("resources").fetch("limits").fetch("memory")
      memory_in_bytes = Kubernetes.parse_memory(memory)
      heap_in_bytes = [memory_in_bytes / 2, 31.gigabytes].min
      heap_size = "#{heap_in_bytes / (1024 * 1024)}m"

      statefulset = Template["statefulset"].render(
        disk_size:,
        has_repositories: repositories.any?,
        heap_size:,
        image:,
        name:,
        namespace:,
        node_selector:,
        owner_references:,
        replicas:,
        repositories:,
        repository_secrets_path: "/tmp/repository_secrets",
        resources:,
        startup_script:,
        tolerations:,
        version:,
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
