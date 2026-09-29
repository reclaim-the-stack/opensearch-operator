- Adding new repositories + policies to existing clusters: verify that the health gated rolling restart now restarts all pods and that the snapshot policy gets created once the cluster is green again.

- Support major version upgrades

The StatefulSet already uses updateStrategy: OnDelete with the operator restarting pods one by one (see RollingRestart), non-manager pods first:
https://docs.opensearch.org/latest/migrate-or-upgrade/rolling-upgrade/

Still missing: block downgrades (eg. a CEL transition rule on the image tag), and only upgrade Dashboards once the OpenSearch rollout is done since Dashboards refuses OpenSearch nodes on an older minor version.

- Health aware PodDisruptionBudget to protect against node drains evicting several pods in a row: maxUnavailable 1 while the cluster is green and 0 otherwise (the ECK approach). A static PDB only looks at pod readiness so it wouldn't prevent red blips during drains.

- Online disk expansion: changing diskSize is rejected since volumeClaimTemplates are immutable. Patch the PVCs, then orphan delete and re-apply the StatefulSet (the ECK approach). Also support storageClassName.

- Status conditions (Ready, Reconciled with the error, Progressing, SnapshotsHealthy with the last successful snapshot per policy) and Warning events on reconcile failures, so failures show up in kubectl and GitOps health checks.

- Declarative users and roles (spec.users / spec.roles) applied through the security REST API with the admin certificate, so applications get least privilege credentials instead of admin_uri. The same mechanism would let security config changes reach existing clusters.

- Include and document how to use alertmanager rules etc
- Add documentation for CRD etc

- Should we enable more Dashboard features?
# Set the value to true to enable multiple data source feature
data_source.enabled: true

# Set the value to true to enable workspace feature
workspace.enabled: true

# Set the value to true to enable explore feature
explore.enabled: true

# Known issues

- New clusters never bootstrap if their pods start more than 5 minutes after the OpenSearch resource was created (the cluster.initial_cluster_manager_nodes heuristic in the startup script). Better: record bootstrap completion, eg. in a mounted ConfigMap, and only set it until then.
- Every pod start downloads the prometheus exporter (from GitHub) and repository-s3 plugins, and exporter releases lag OpenSearch releases by days to months. Build an image with the plugins pre-installed instead.
- No drift repair: reconciliation is skipped once status.observedGeneration matches and owned resources aren't watched, so a deleted Service, ConfigMap, Secret or StatefulSet is never recreated.
- Replica shard allocation stays disabled ("primaries") if a pod deleted by a rolling restart never comes back.
- internal_users.yml and roles.yml only seed the security index on first boot, changes to them never reach existing clusters.
- Snapshot management: failed repository registrations and policy updates aren't retried until the next spec change, removing a repository leaves its policies behind, and the policies listing isn't paginated (20 results).
- The ServiceMonitor scrapes every pod twice since the headless and client services share their labels.
- Dashboards is upgraded right away while OpenSearch restarts one pod at a time, so it's unavailable during minor version upgrades.
- No leader election: the Recreate strategy doesn't prevent two operator instances when a node's kubelet hangs.
- spec.config keys which the operator sets itself (network.host, cluster.name, plugins.security.* etc) produce duplicate keys which stop OpenSearch from starting.
- Kubernetes.parse_memory rejects decimal quantities like 4.5Gi which the CRD accepts.
- No pod securityContext.fsGroup, fine with hostpath volumes but likely to fail with block storage CSI drivers.
- Authentication failures are reported as Unreachable health.
- The operator Deployment has no resource requests or probes and logs at debug level.
- `kubectl delete -k deploy/` also deletes the CRD, and with it every cluster and its data.

# Maybe?

- Watch owned resources (StatefulSets, pods, services, secrets) with informer style caches, replacing RollingRestart's polling of the Kubernetes API, triggering ticks on pod changes and repairing drift. The OpenSearch resource watch already streams its initial state and handles resumes, 410s and missed deletions.
- Should default 40MB max_snapshot_bytes_per_sec / max_restore_bytes_per_sec be configurable to tune per node snapshot speeds?
- Restore / bootstrap a cluster from a snapshot
- Pod template overrides: labels and annotations, priorityClassName, topology spread constraints, image pull secrets, Dashboards resources or opting out of Dashboards
- Deletion protection, eg. a ValidatingAdmissionPolicy requiring an annotation to delete an OpenSearch resource
- Graduate the CRD from v1alpha1

# YAGNI

- Single / two node clusters
- SSL certificate host verification
- Short lived SSL certificates and rotation
- Should dashboards have the security section enabled? (https://forum.opensearch.org/t/opensearch-dashboards-missing-security-options/7601/2) - probably not since the operator should manage users
- Is AWS_EC2_METADATA_DISABLED=true important? - probably not: https://chatgpt.com/c/68ff8ffe-59a4-8329-8688-8937204284be

# Esoteric features

- Suspend: be able to keep the ES pod running but have elasticsearch itself not running, eg. to run diagnostic / data tools on the raw ES data without process interference. Handled in the ESC operator by adding a suspend annotation to a pod
