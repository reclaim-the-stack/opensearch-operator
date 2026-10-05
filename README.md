# OpenSearch Operator

A tightly scoped OpenSearch operator written in Ruby.

## Why a new operator?

Many issues with the [official operator](https://github.com/opensearch-project/opensearch-k8s-operator) triggered us to roll our own:

- Can't deploy opensearch versions beyond 2.12.0, released in February 2024: https://github.com/opensearch-project/opensearch-k8s-operator/issues/759
- Certificate generation doesn't work, and even if it did work would only create a certificate with a 1 year TTL with no support for rotation
- No support for randomized automatic password generation (two pull requests exist but nothing's moving forward: [816](https://github.com/opensearch-project/opensearch-k8s-operator/pull/816), [986](https://github.com/opensearch-project/opensearch-k8s-operator/pull/986))
- Has a [huge number of bugs](https://github.com/opensearch-project/opensearch-k8s-operator/issues?q=is%3Aissue%20state%3Aopen%20label%3Abug) and doesn't seem to have any momentum in fixing them
- Questionable security choices like making admin credentials readily available on disk on the opensearch pods
- Missing or outdated documentation
- Attempting to run the REST API without TLS doesn't work
- Doesn't follow best practices like capping JVM heap size to 31GB

We were also interested in writing a Kubernetes operator from scratch in Ruby and see how that would compare with orthodox Go operators as Ruby is the prefered language for the [Reclaim the Stack](https://reclaim-the-stack.com) platform. At the time of writing this operator comes in at ~1.5k lines of Ruby vs ~20k lines of Go (excluding tests) in the official operator.

## Features and limitations

Trying to become "feature complete" as a general purpose opensearch operator is outside the scope of this project. Having a limited and focused scope is necessary for us to ensure stability and maintainability over the long term. The main purpose of this operator is to suit deployments within the [Reclaim the Stack](https://reclaim-the-stack.com) platform.

That said, we ocassionaly go above and beyond the official OpenSearch operator (and even the official ElasticSearch operator) such as with our implementation of declarative snapshot management.

Notable features:
- Can deploy the latest versions of OpenSearch 🥳
- Random passwords generated for all default users (`admin`, `kibanaserver`, `readall` etc)
- Ready to integrate with prometheus operator via a single `ServiceMonitor` and Grafana with a dashboard JSON template
- Fully declarative snapshot management
- Intelligent JVM heap management (50% of available RAM up to a cap of 31GB to avoid compressed oops)
- Health gated rolling restarts: pods are restarted one at a time, waiting for green cluster health in between (see below)
- Safe scale downs: shards and cluster manager votes are migrated off leaving nodes before their pods are removed (see below)
- Health aware PodDisruptionBudget: node drains evict one pod at a time, waiting for green cluster health in between (see below)

Notable limitations:
- No functionality to create custom users and roles
- Not tested with old versions of OpenSearch prior to 3.x
- No support for "node pools" for advanced node role topologies (all replicas per cluster are expected to be homogenous master eligble data nodes)
- No support for single or two node clusters (same as the official operator)
- REST API runs without TLS (we assume clusters are either fully private or that SSL can be terminated at edge)
- TLS certificates for the transport layer are generated with a 100 year TTL, without strict host verification or rotation support

Feel free to open a pull request if you are missing anything 🙏

## Get started

The operator targets Kubernetes 1.36 or later.

- Deploy the operator: `kubectl apply -k deploy/`
- Create sample cluster: `kubectl apply -f examples/simple.yaml`
- Inspect: `kubectl get opensearch` (the `Health` column shows `Unreachable` when the operator can't reach the cluster, and `Unauthorized` when OpenSearch rejects its admin credentials)

Look at the example files to understand the CRD structure.

TODO: add comprehensive documentation.

## Images

`spec.image` can be any OpenSearch image. With the official images (`opensearchproject/opensearch`) the startup script installs the Prometheus exporter on every start, and the `repository-s3` plugin when snapshot repositories are configured. A pod then can't start while GitHub or OpenSearch's artifact server is unreachable. The exporter is also released for each OpenSearch version separately, often days or weeks after it, so upgrading to a version without one leaves the first restarted pod crashing.

`ghcr.io/reclaim-the-stack/opensearch:<version>` comes with those plugins installed, so its pods start without downloading anything. `ghcr.io/reclaim-the-stack/opensearch:3.8.0` is the default: a cluster without `spec.image` gets the default of the installed CRD, so upgrading the operator can upgrade OpenSearch too. Set `spec.image` to decide when to upgrade instead. CI builds it for the versions listed in `.github/workflows/opensearch-images.yml`, currently 3.8.0, and a version can only be built once its exporter is released. Upgrade the operator to 0.15.0 or later before switching to it, earlier versions fail to install the plugins a second time.

## Bootstrapping

A new cluster bootstraps, ie. elects its first cluster manager, on its first start, however long its pods take to start (eg. while nodes are added or images pulled). Once it has formed, the operator records its UUID in the ConfigMap `opensearch-<name>-bootstrap`, and nodes started from then on don't bootstrap any more. A node without data which started while no cluster manager was reachable would otherwise form a second, empty cluster.

So pods of a cluster which lost the data of all its nodes wait for the cluster that's gone rather than forming a new, empty one. To start over with an empty cluster, delete the ConfigMap and then the pods. The operator records the new cluster once it has formed.

## Rolling restarts

The StatefulSet uses the `OnDelete` update strategy, so Kubernetes never restarts pods on its own when the pod template changes (version upgrade, resource changes, new snapshot repositories etc). Instead the operator restarts pods one at a time following the [OpenSearch rolling upgrade procedure](https://docs.opensearch.org/latest/migrate-or-upgrade/rolling-upgrade/):

1. Wait for all pods to be ready and all nodes to have joined the cluster
2. Wait for green cluster health
3. Disable replica shard allocation, flush, delete the next pod (highest ordinal first, cluster manager last)
4. Once the pod has rejoined, re-enable replica shard allocation and repeat

A yellow cluster with no shard recovery in progress (no initializing, relocating or delayed shards) is tolerated for 5 minutes, after which the rollout proceeds anyway with a warning event. This avoids rollouts getting stuck forever on shards that can't be assigned regardless of node restarts. A red cluster always blocks the rollout.

Follow along with `kubectl get opensearch` (the `Phase` column) and `kubectl describe opensearch <name>` (events).

## Scaling down

Lowering `spec.replicas` removes the pods with the highest ordinals, but only once that's safe. Removing them straight away would delete their volumes along with any shard that only had copies on them, and removing half or more of the (all cluster manager eligible) nodes at once would cost the cluster its quorum. Instead the operator:

1. Waits for the remaining pods to be ready and their nodes to have joined the cluster. The leaving pods don't have to be available, eg. pods of a scale up which never got scheduled, or a pod stuck on a Kubernetes node which is gone for good.
2. Excludes the leaving nodes from shard allocation (`cluster.routing.allocation.exclude._name`) and waits for OpenSearch to migrate their shards to the remaining nodes
3. Once the cluster state shows no shards on the leaving nodes and no unassigned primary shards (recovering those might need data which only remains on a leaving node), excludes the leaving nodes from the cluster manager voting configuration and lowers the StatefulSet replicas. At most 10 nodes are removed per step since that's the default limit of voting configuration exclusions.
4. Once the removed nodes have left the cluster, clears the allocation and voting configuration exclusions

Rolling restarts wait for an ongoing scale down to finish. Raising the replicas again while shards are being migrated (step 2) cancels the scale down.

The remaining nodes need room for all shards. The scale down waits for as long as shards can't be moved, eg. when an index has more replicas than the remaining nodes can hold or disk watermarks are exceeded (`GET _cluster/allocation/explain` tells why).

The operator manages `cluster.routing.allocation.exclude._name` and the voting configuration exclusions, so don't use them to drain nodes by hand (`cluster.routing.allocation.exclude._ip` works).

## Node drains

Each cluster has a PodDisruptionBudget, `opensearch-<name>`, which the operator keeps up to date. Node drains, eg. during Kubernetes or OS upgrades, may evict one OpenSearch pod while the cluster is green and no rolling restart or scaling is in progress, and none otherwise. Evicting a pod while the cluster is yellow could take the only copy of a shard offline.

So a drain of the next node waits until the cluster has recovered from the previous one, ie. until the evicted node's shards are assigned again. While the cluster isn't green the operator waits for it to turn green rather than polling, so the next eviction is allowed within about a second.

A cluster which stays yellow, eg. because an index has more replicas than the nodes can hold, blocks drains until it's fixed. Drains retry blocked evictions until their own timeout (eg. `kubectl drain --timeout`). To wait for a cluster before draining the next node: `kubectl wait --for=jsonpath='{.status.disruptionsAllowed}'=1 pdb/opensearch-<name> --timeout=30m`.

## Status

`kubectl get opensearch` shows the version, health and number of nodes of each cluster, whether it's ready, and its phase, eg. the progress of a rolling restart. `kubectl describe opensearch <name>` also shows two conditions with their messages:

- `Reconciled` tells whether the latest generation of the spec was applied, with the error if it wasn't. Failed reconciliations are retried on the next change of the spec and every 10 minutes.
- `Ready` is `True` once the latest generation was applied, the cluster is reachable, its health isn't red and no rolling restart or scaling is in progress. Otherwise its reason is `ReconcileFailed`, `Unreachable`, `Unauthorized`, `HealthRed`, `Progressing` or `Deleting`.

`kubectl wait --for=condition=Ready opensearch/<name> --timeout=15m` waits for a cluster to be ready, eg. after creating it.

For Argo CD to show the health of OpenSearch resources, add a custom health check to `argocd-cm`:

```yaml
resource.customizations.health.opensearch.reclaim-the-stack.com_OpenSearch: |
  hs = { status = "Progressing", message = "Waiting for the operator" }
  if obj.status ~= nil and obj.status.conditions ~= nil then
    for _, condition in ipairs(obj.status.conditions) do
      if condition.type == "Ready" and condition.observedGeneration == obj.metadata.generation then
        hs.message = condition.message
        if condition.status == "True" then
          hs.status = "Healthy"
        elseif condition.reason ~= "Progressing" then
          hs.status = "Degraded"
        end
      end
    end
  end
  return hs
```

## Integrate with prometheus operator for metrics

Note: This assumes you're running Reclaim the Stack with `kube-prometheus-stack` running in the `monitoring` namespace and is using Sealed Secrets for secrets management. Adjust as needed.

Run from your gitops repository:

```bash
echo 'apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: reclaim-the-stack-opensearch
  namespace: monitoring
spec:
  namespaceSelector:
    any: true
  selector:
    matchLabels:
      app.kubernetes.io/managed-by: opensearch-operator
      app.kubernetes.io/name: opensearch
  endpoints:
    - port: http
      scheme: http
      path: /_prometheus/metrics
      interval: 30s
      scrapeTimeout: 10s
      basicAuth:
        username:
          name: opensearch-servicemonitor-basic-auth
          key: username
        password:
          name: opensearch-servicemonitor-basic-auth
          key: password
' > platform/kube-prometheus-stack/opensearch-servicemonitor.yaml

metrics_password=`kubectl get secret opensearch-metrics-basic-auth -n opensearch-operator -o yaml | yq .data.password | base64 -d`
kubectl create secret generic opensearch-servicemonitor-basic-auth -n monitoring --dry-run=client --from-literal=username=metrics --from-literal password=$metrics_password -o yaml | kubeseal -o yaml >> platform/kube-prometheus-stack/opensearch-servicemonitor.yaml
```

Now add the new manifest file to the resources list in `platform/kube-prometheus-stack/kustomization.yaml` and push the files.

You should now get metrics from your OpenSearch clusters into Prometheus. Add the `examples/opensearch-grafana-dashboard.json` dashboard into Grafana to view the metrics.

The selector only matches the headless service of each cluster, which includes pods that aren't ready, so every pod is scraped once. The client service deliberately lacks the `app.kubernetes.io/name` label: a selector which also matches it, eg. `opensearch.reclaim-the-stack.com/cluster` alone, would scrape every pod twice.

## Development

Prerequisites: Ruby 3.4.5

Install dependencies: `bundle install`
Run tests: `bundle exec rspec` (after changing a template, regenerate the rendered manifests in `spec/fixtures/manifests/` with `UPDATE_MANIFEST_SNAPSHOTS=1 bundle exec rspec`)
Build image: `docker build -t opensearch-operator-rb .`

### Local Run

For a faster feedback loop when testing changes to the operator you can run it from your local machine.

- Ensure `KUBECONFIG` is set (or default in `~/.kube/config`) and that the current context is the one you want to run the operator against.
- Run the operator with: `ruby lib/main.rb`

### Project Structure

- `lib`: operator code (entrypoint in `main.rb`)
- `examples/`: sample cluster resources
- `deploy/`: Operator Deployment and RBAC
- `spec/`: RSpec tests
- `templates/`: Templates used by the operator to create Kubernetes resources

## Container Image

Images are published to GHCR via CI.

- Base image: `ghcr.io/reclaim-the-stack/opensearch-operator`
- Tags: semver tags on releases (e.g., `v0.1.0` → `:0.1.0`, `:0.1`), SHA tags for all pushes, `latest` on `master` branch.

Examples

- Pull latest master: `docker pull ghcr.io/reclaim-the-stack/opensearch-operator:latest`
- Pull a release: `docker pull ghcr.io/reclaim-the-stack/opensearch-operator:0.1.0`
- Pull a specific commit: `docker pull ghcr.io/reclaim-the-stack/opensearch-operator:sha-5ffbd47e74dc7bce2a57787f766f2846d2abae4a`
