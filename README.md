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

Notable limitations:
- No functionality to create custom users and roles
- Not tested with old versions of OpenSearch prior to 3.x
- No support for "node pools" for advanced node role topologies (all replicas per cluster are expected to be homogenous master eligble data nodes)
- No support for single or two node clusters (same as the official operator)
- REST API runs without TLS (we assume clusters are either fully private or that SSL can be terminated at edge)
- TLS certificates for the transport layer are generated with a 100 year TTL, without strict host verification or rotation support

Feel free to open a pull request if you are missing anything 🙏

## Get started

- Deploy the operator: `kubectl apply -k deploy/`
- Create sample cluster: `kubectl apply -f examples/simple.yaml`
- Inspect: `kubectl get opensearch` (the `Health` column shows `Unreachable` when the operator can't reach the cluster)

Look at the example files to understand the CRD structure.

TODO: add comprehensive documentation.

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

## Development

Prerequisites: Ruby 3.4.5

Install dependencies: `bundle install`
Run tests: `bundle exec rspec`
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
