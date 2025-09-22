# OpenSearch Operator (Ruby)

A minimal Kubernetes operator written in Ruby that manages OpenSearch clusters via a CustomResourceDefinition (CRD). It reconciles `OpenSearch` resources into a `StatefulSet` and `Service` using server‑side apply.

## Project Structure

- `lib`: operator code (entrypoint in `main.rb`)
- `examples/`: sample cluster resources
- `deploy/`: Operator Deployment and RBAC
- `spec/`: RSpec tests
- `templates/`: YAML templates used by the operator

## Quick Start

Prerequisites: Ruby 3.4.5, Bundler, `kubectl` with cluster access.

- Install gems: `bundle install`
- Deploy the operator: `kubectl apply -k deploy/`
- Create sample: `kubectl apply -f examples/simple.yaml`
- Inspect: `kubectl get opensearch`

## Local Run

The operator tries in‑cluster config and falls back to local kubeconfig.

- Ensure `KUBECONFIG` is set (or default in `~/.kube/config`)
- Run: `ruby lib/main.rb`

## Development

- Test: `bundle exec rspec`
- Build image: `docker build -t opensearch-operator-rb .`
- Contributor guide: see `AGENTS.md` for structure, naming, testing, and PR guidelines.

## Container Image

Images are published to GHCR via CI.

- Base image: `ghcr.io/reclaim-the-stack/opensearch-operator`
- Tags: semver tags on releases (e.g., `v0.1.0` → `:0.1.0`, `:0.1`), SHA tags for all pushes, `latest` on `master` branch.

Examples

- Pull latest master: `docker pull ghcr.io/reclaim-the-stack/opensearch-operator:latest`
- Pull a release: `docker pull ghcr.io/reclaim-the-stack/opensearch-operator:0.1.0`
- Pull a specific commit: `docker pull ghcr.io/reclaim-the-stack/opensearch-operator:sha-5ffbd47e74dc7bce2a57787f766f2846d2abae4a`
