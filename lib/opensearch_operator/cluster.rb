# frozen_string_literal: true

require "bcrypt"

require "securerandom"
require "time"
require "yaml"

class OpensearchOperator
  class Cluster
    # Bump when operator-managed manifests change and existing clusters must be reconciled again.
    MANIFEST_VERSION = 3

    KEYS_AFFECTING_STATUS = %i[status number_of_nodes version].freeze

    # A failed generation is retried at most this often. Events which don't change the generation, like the status update
    # reporting the failure, would otherwise retry it right away.
    RECONCILE_RETRY_INTERVAL = 1.minute

    # Failed snapshot repository upserts are retried with a backoff rather than on every poll since their causes, eg. an
    # unreachable S3 endpoint or a bucket which doesn't exist, tend to last a while
    SNAPSHOT_REPOSITORIES_RETRY_INTERVAL = 5.minutes
    SNAPSHOT_REPOSITORIES_MAX_RETRY_INTERVAL = 1.hour

    def initialize(manifest)
      @manifest = manifest
      # The watch thread and the watcher thread both update the status, and each patch replaces all conditions
      @status_mutex = Mutex.new
    end

    def name = @manifest.fetch("metadata").fetch("name")
    def namespace = @manifest.fetch("metadata").fetch("namespace")
    def uid = @manifest.fetch("metadata").fetch("uid")
    def spec = @manifest.fetch("spec")
    def image = spec.fetch("image")
    def replicas = spec.fetch("replicas")
    def disk_size = spec.fetch("diskSize")

    def version = image.split(":").last
    def statefulset_name = "opensearch-#{name}"

    delegate :equal?, to: :@manifest
    delegate :dig, to: :@manifest

    def update(new_manifest)
      @manifest = new_manifest
      generation = @manifest.fetch("metadata").fetch("generation")

      # A generation whose reconciliation failed gets retried by the next event of the cluster, eg. a watch resync
      if generation == @reconciled_generation
        LOGGER.info "Generation #{generation} of #{namespace}/#{name} already reconciled, skipping"
      elsif @reconcile_failure&.fetch(:generation) == generation &&
            Time.now - @reconcile_failure.fetch(:failed_at) < RECONCILE_RETRY_INTERVAL
        LOGGER.info "Generation #{generation} of #{namespace}/#{name} failed to reconcile recently, retrying later"
      else
        LOGGER.info "Generation #{generation} of #{namespace}/#{name} not reconciled yet, reconsiling"
        reconsile
      end
    end

    def reconsile
      generation = @manifest.fetch("metadata").fetch("generation")
      observed_generation = @manifest.dig("status", "observedGeneration")
      observed_manifest_version = @manifest.dig("status", "operatorManifestVersion")

      if observed_generation && observed_generation >= generation && observed_manifest_version == MANIFEST_VERSION
        LOGGER.info "Generation #{generation} and manifest version #{MANIFEST_VERSION} already observed for #{namespace}/#{name}, skipping reconciliation steps"
        initialize_or_trigger_watcher
        @reconciled_generation = generation
        @reconcile_failure = nil
        patch_status
        return
      end

      ensure_credentials_secret
      ensure_certificates_secret
      ensure_security_config
      ensure_service
      ensure_client_service
      ensure_statefulset
      ensure_dashboards_deployment
      ensure_dashboards_service

      initialize_or_trigger_watcher
      @reconciled_generation = generation
      @reconcile_failure = nil
      patch_status(observedGeneration: generation, operatorManifestVersion: MANIFEST_VERSION)
    rescue StandardError => e
      message = "#{e.class}: #{e.message}".truncate(1000)
      # Retries of the generation fail the same way, one event per distinct failure keeps them from flooding the events.
      # Compared to the published condition, which also holds across operator restarts.
      published = published_conditions.find { |condition| condition["type"] == "Reconciled" }
      unless published&.values_at("status", "observedGeneration", "message") == ["False", generation, message]
        emit_event("ReconcileFailed", "Failed to reconcile generation #{generation}: #{message}", type: "Warning")
      end
      @reconcile_failure = { generation:, message:, failed_at: Time.now }
      patch_status
      raise
    end

    def initialize_or_trigger_watcher
      # Snapshot repositories can only be registered once all pods run the latest StatefulSet revision (the S3
      # client credentials live in the keystore of each node), hence we wait for a settled cluster before upserting.
      # Holds the time from which to upsert them, nil once they're in place.
      @snapshot_repositories_upsert_due_at = Time.now

      return if @watcher

      # CLUSTER_HOST_OVERRIDE=localhost or localhost:9201 can be used for testing with port-forwarded clusters
      host = ENV["CLUSTER_HOST_OVERRIDE"] || "opensearch-#{name}-client.#{namespace}.svc.cluster.local"
      host += ":9200" unless host.include?(":")
      cluster_url = "http://admin:#{admin_password}@#{host}"
      @watcher = OpensearchWatcher.new(cluster_url)
      rolling_restart = RollingRestart.new(self, @watcher.client)
      # Consecutive failed snapshot repository upserts, a spec change retries right away but keeps counting
      snapshot_repositories_failures = 0
      @watcher.on_poll do |health, nodes|
        settled = rolling_restart.tick(health, nodes)

        if settled && @snapshot_repositories_upsert_due_at&.past?
          # Cleared up front so that a spec change arriving in the meantime triggers another upsert
          @snapshot_repositories_upsert_due_at = nil
          failed_repository_names = upsert_snapshot_repositories

          if failed_repository_names.empty?
            if snapshot_repositories_failures.positive?
              emit_event(
                "SnapshotRepositoriesRecovered",
                "Upserted all snapshot repositories and policies after #{snapshot_repositories_failures} failed " \
                "#{'attempt'.pluralize(snapshot_repositories_failures)}",
              )
            end
            snapshot_repositories_failures = 0
          else
            snapshot_repositories_failures += 1
            retry_interval = [
              SNAPSHOT_REPOSITORIES_RETRY_INTERVAL * (2**(snapshot_repositories_failures - 1)),
              SNAPSHOT_REPOSITORIES_MAX_RETRY_INTERVAL,
            ].min
            # Keeps the immediate upsert of a spec change which arrived in the meantime
            @snapshot_repositories_upsert_due_at ||= retry_interval.from_now
            # Emitted on every failure since Events expire after an hour by default, the backoff is capped at an hour
            # so a Warning remains visible for as long as the failures last
            emit_event(
              "SnapshotRepositoriesFailed",
              "Failed to upsert snapshot repositories #{failed_repository_names.join(', ')} (see the operator logs), " \
              "retrying at #{@snapshot_repositories_upsert_due_at.utc.iso8601}",
              type: "Warning",
            )
          end
        end
      end
      @watcher.run do |new_state, changed_keys|
        update_status(new_state, changed_keys)
      end
    end

    def finalize
      @watcher&.stop
    end

    # Configures snapshot repositories and reconciles associated lifecycle policies in OpenSearch. Returns the names of
    # the repositories which failed, a failing repository doesn't hold up the others.
    def upsert_snapshot_repositories
      spec.fetch("snapshotRepositories").filter_map do |repository|
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

        @watcher.client.snapshot.create_repository(params)
        LOGGER.info "Ensured snapshot repository #{repository_name} in cluster #{namespace}/#{name}"

        # The listing only returns 20 policies unless asked for more, the missing ones would be created again and conflict
        existing_policies = @watcher.client.http.get("/_plugins/_sm/policies", params: { size: 1000 }).fetch("policies")
        reconcile_snapshot_policies(repository_name, repository.fetch("policies"), existing_policies)
        nil
      rescue StandardError => e
        Sentry.capture_exception(e)
        LOGGER.error "Failed to upsert snapshot repository #{repository_name} or its policies in cluster #{namespace}/#{name}: #{e.class}: #{e.message}"
        repository_name
      end
    end

    # TODO: Maybe we should label which pod is master / manager?
    def update_status(new_state, changed_keys)
      return unless changed_keys.intersect?(KEYS_AFFECTING_STATUS)

      patch_status(health: new_state[:status]&.capitalize, nodes: new_state[:number_of_nodes], version: new_state[:version])
    end

    # Set by each tick of the rolling restart to the StatefulSet generation it works with. Ready waits for it to reach the
    # generation the latest reconciliation applied (see #conditions).
    def evaluated_statefulset_generation=(generation)
      # The phase of an earlier generation doesn't tell whether the new one needs a rolling restart or scaling
      @phase = nil if generation != @evaluated_statefulset_generation
      @evaluated_statefulset_generation = generation
    end

    # Sets status.phase (visible in `kubectl get opensearch`), skipping the API call when unchanged
    def update_phase(phase)
      return if @phase == phase

      @phase = phase if patch_status(phase:)
    end

    # Emits a Kubernetes Event attached to the OpenSearch resource (visible in `kubectl describe opensearch`)
    def emit_event(reason, message, type: "Normal")
      LOGGER.info "event=#{reason} type=#{type} cluster=#{namespace}/#{name} message=#{message}"

      timestamp = Time.now.utc.iso8601
      Kubernetes.events.create(
        "metadata" => { "generateName" => "#{name}.", "namespace" => namespace },
        "involvedObject" => {
          "apiVersion" => @manifest.fetch("apiVersion"),
          "kind" => @manifest.fetch("kind"),
          "name" => name,
          "namespace" => namespace,
          "uid" => uid,
        },
        "reason" => reason,
        "message" => message,
        "type" => type,
        "source" => { "component" => "opensearch-operator" },
        "reportingComponent" => "opensearch-operator",
        "firstTimestamp" => timestamp,
        "lastTimestamp" => timestamp,
        "count" => 1,
      )
    rescue StandardError => e
      Sentry.capture_exception(e)
      LOGGER.error "Failed to emit event #{reason} for #{namespace}/#{name}: #{e.class}: #{e.message}"
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

    def ensure_client_service
      client_service = Template["client_service"].render(
        name:,
        namespace:,
        owner_references:,
      )

      Kubernetes.services.apply(client_service)
    end

    def ensure_statefulset
      creation_timestamp_epoch = Time.parse(@manifest.dig("metadata", "creationTimestamp")).to_i
      node_selector = spec["nodeSelector"].to_json
      resources = spec["resources"].to_json
      tolerations = spec["tolerations"].to_json

      # Prometheus exporter plugin version must be synced with OpenSearch version:
      # https://github.com/opensearch-project/opensearch-prometheus-exporter/blob/main/COMPATIBILITY.md
      prometheus_exporter_version = "#{version}.0"

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
        namespace:,
        prometheus_exporter_version:,
        repositories:,
      ).to_json

      # Heap size is set to 50% of the memory limit, up to a maximum of 31Gi to avoid compressed oops being disabled
      # NOTE: Our CRD makes resources.limits.memory mandatory and requires a minumum of 4Gi
      memory = spec.fetch("resources").fetch("limits").fetch("memory")
      memory_in_bytes = Kubernetes.parse_memory(memory)
      heap_in_bytes = [memory_in_bytes / 2, 31.gigabytes].min
      heap_size = "#{heap_in_bytes / (1024 * 1024)}m"

      # StatefulSets created before the switch to the OnDelete update strategy carry an API server defaulted
      # spec.updateStrategy.rollingUpdate.partition field which no field manager owns. Server side apply can't
      # remove it and the API server rejects OnDelete combined with rollingUpdate, so we merge patch it away first.
      existing_statefulset = Kubernetes.statefulsets.get(statefulset_name, namespace:)
      if existing_statefulset.dig("spec", "updateStrategy", "type") == "RollingUpdate"
        LOGGER.info "Migrating StatefulSet #{namespace}/#{statefulset_name} to the OnDelete update strategy"
        Kubernetes.statefulsets.patch(
          statefulset_name,
          namespace:,
          params: { spec: { updateStrategy: { type: "OnDelete", rollingUpdate: nil } } },
        )
      end

      # RollingRestart owns the replicas of an existing StatefulSet since removing nodes requires draining them first.
      # NOTE: The spec replicas only apply on a 404, Resource#get raises on any other API error.
      statefulset_replicas = existing_statefulset.dig("spec", "replicas") || replicas
      # Volume claim templates are immutable, so an existing StatefulSet keeps its disk size. The CRD rejects diskSize
      # changes, but a CR changed before that rule existed would otherwise fail every reconciliation.
      statefulset_disk_size =
        existing_statefulset.dig("spec", "volumeClaimTemplates", 0, "spec", "resources", "requests", "storage") || disk_size

      statefulset = Template["statefulset"].render(
        disk_size: statefulset_disk_size,
        has_repositories: repositories.any?,
        heap_size:,
        image:,
        name:,
        namespace:,
        node_selector:,
        owner_references:,
        replicas: statefulset_replicas,
        repositories:,
        repository_secrets_path: "/tmp/repository_secrets",
        resources:,
        startup_script:,
        tolerations:,
        version:,
      )

      @applied_statefulset_generation = Kubernetes.statefulsets.apply(statefulset).dig("metadata", "generation")
    end

    def ensure_dashboards_deployment
      dashboards_image = "opensearchproject/opensearch-dashboards:#{version}"
      opensearch_hosts = "http://opensearch-#{name}-client.#{namespace}.svc.cluster.local:9200"

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

    # Patches the given status fields along with the conditions if they changed, which a merge patch replaces as a whole.
    # Returns whether the patch succeeded.
    def patch_status(fields = {})
      @status_mutex.synchronize do
        new_conditions = conditions(phase: fields.fetch(:phase, @phase))
        conditions_changed = new_conditions != published_conditions
        return true if fields.empty? && !conditions_changed

        status = conditions_changed ? fields.merge(conditions: new_conditions) : fields
        CLUSTERS_RESOURCE.patch(name, namespace:, subresource: "status", params: { status: })
        @published_conditions = new_conditions
        true
      end
    rescue StandardError => e
      Sentry.capture_exception(e)
      LOGGER.error "Failed to update the status of #{namespace}/#{name}: #{e.class}: #{e.message}"
      false
    end

    # The Reconciled and Ready conditions (standard metav1.Condition fields) for `kubectl wait --for=condition=Ready` and
    # GitOps health checks. Until the watcher reported the health and the rolling restart the phase, eg. after an operator
    # restart, the published Ready condition is kept.
    def conditions(phase:)
      generation = @reconcile_failure ? @reconcile_failure.fetch(:generation) : @reconciled_generation
      failure_message = @reconcile_failure&.fetch(:message)
      health = @watcher&.state&.dig(:status)

      reconciled =
        if failure_message
          ["False", "ReconcileFailed", failure_message]
        else
          ["True", "Reconciled", "Generation #{generation} is applied"]
        end
      ready =
        if phase == "Deleting"
          ["False", "Deleting", "The cluster is being deleted"]
        elsif failure_message
          ["False", "ReconcileFailed", failure_message]
        elsif health.nil? || phase.nil?
          nil
        elsif health == "unreachable"
          ["False", "Unreachable", "The OpenSearch REST API isn't reachable"]
        elsif health == "red"
          ["False", "HealthRed", "Cluster health is red"]
        elsif @evaluated_statefulset_generation.to_i < @applied_statefulset_generation.to_i
          # A Running phase can predate the applied StatefulSet, eg. from a tick which read it before the apply
          ["False", "Progressing", "Applying generation #{generation}"]
        elsif phase != "Running"
          ["False", "Progressing", phase]
        else
          ["True", "Running", "Cluster health is #{health}"]
        end

      { "Reconciled" => reconciled, "Ready" => ready }.filter_map do |type, (status, reason, message)|
        published = published_conditions.find { |condition| condition["type"] == type }
        next published unless status

        transitioned = published&.dig("status") != status
        {
          "type" => type,
          "status" => status,
          "observedGeneration" => generation,
          "lastTransitionTime" => transitioned ? Time.now.utc.iso8601 : published.fetch("lastTransitionTime"),
          "reason" => reason,
          "message" => message,
        }
      end
    end

    def published_conditions
      @published_conditions ||= @manifest.dig("status", "conditions").to_a
    end
  end
end
