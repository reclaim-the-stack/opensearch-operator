- Support major version upgrades

The StatefulSet already uses updateStrategy: OnDelete with the operator restarting pods one by one (see RollingRestart), non-manager pods first:
https://docs.opensearch.org/latest/migrate-or-upgrade/rolling-upgrade/

Still missing: block downgrades (eg. a CEL transition rule on the image tag), and only upgrade Dashboards once the OpenSearch rollout is done since Dashboards refuses OpenSearch nodes on an older minor version.

- Online disk expansion: the CRD rejects diskSize changes since volumeClaimTemplates are immutable, and existing StatefulSets keep their size. On storage classes which support expansion, relax the CRD rule to only reject shrinking (quantity(self).compareTo(quantity(oldSelf)) >= 0), patch the PVCs, then orphan delete and re-apply the StatefulSet (the ECK approach), and support storageClassName. Hostpath volumes can't be expanded, moving such clusters to bigger disks needs replacing nodes one at a time: drain the node's shards like a scale down does, then recreate its pod and PVC.

- A SnapshotsHealthy condition with the last successful snapshot per policy, so failing snapshots show up in kubectl and GitOps health checks like reconcile failures do.

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

- No drift repair: reconciliation is skipped once status.observedGeneration matches and owned resources aren't watched, so a deleted Service, ConfigMap, Secret or StatefulSet is never recreated.
- Replica shard allocation stays disabled ("primaries") if a pod deleted by a rolling restart never comes back.
- internal_users.yml and roles.yml only seed the security index on first boot, changes to them never reach existing clusters.
- Snapshot management: removing a repository leaves its policies behind, and changed S3 credentials in the referenced Secrets only reach the keystore once the pods restart, which nothing triggers.
- Dashboards is upgraded right away while OpenSearch restarts one pod at a time, so it's unavailable during minor version upgrades.
- No leader election: the Recreate strategy doesn't prevent two operator instances when a node's kubelet hangs.
- spec.config keys which the operator sets itself (network.host, cluster.name, plugins.security.* etc) produce duplicate keys which stop OpenSearch from starting.
- No pod securityContext.fsGroup, fine with hostpath volumes but likely to fail with block storage CSI drivers.
- Authentication failures are reported as Unreachable health.
- The operator Deployment has no probes.
- `kubectl delete -k deploy/` also deletes the CRD, and with it every cluster and its data.

# Maybe?

- Build ghcr.io/reclaim-the-stack/opensearch images for new OpenSearch versions automatically, eg. a scheduled workflow which adds a version once its Prometheus exporter is released.
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
