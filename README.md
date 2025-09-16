# OpenSearch Operator (Ruby)

A minimal Kubernetes operator written in Ruby that manages OpenSearch clusters via a CustomResourceDefinition (CRD). It reconciles `OpenSearchCluster` resources into a `StatefulSet` and `Service` using server‑side apply.

## Project Structure

- `lib/main.rb`: operator entrypoint (watches CRs and reconciles resources)
- `manifests/`: CRD and sample `OpenSearchCluster`
- `deploy/`: Operator Deployment and RBAC
- `spec/`: RSpec tests

## Quick Start

Prerequisites: Ruby 3.4.5, Bundler, `kubectl` with cluster access.

- Install gems: `bundle install`
- Apply CRD: `kubectl apply -f manifests/opensearchcluster.crd.yaml`
- Deploy operator: `kubectl apply -f deploy/`
- Create sample: `kubectl apply -f manifests/opensearchcluster.sample.yaml`
- Inspect: `kubectl get opensearchclusters` and `kubectl logs -f deploy/opensearch-operator -n <ns>`

## Local Run

The operator tries in‑cluster config and falls back to local kubeconfig.

- Ensure `KUBECONFIG` is set (or default in `~/.kube/config`)
- Run: `ruby lib/main.rb` (optional: `LOG_LEVEL=debug`)

## Development

- Test: `bundle exec rspec`
- Build image: `docker build -t opensearch-operator-rb .`
- Contributor guide: see `AGENTS.md` for structure, naming, testing, and PR guidelines.
