# OpenSearch Operator (Ruby)

A minimal Kubernetes operator written in Ruby that manages OpenSearch clusters via a CustomResourceDefinition (CRD). It reconciles `OpenSearch` resources into a `StatefulSet` and `Service` using server‑side apply.

## Get started

- Deploy the operator: `kubectl apply -k deploy/`
- Create sample cluster: `kubectl apply -f examples/simple.yaml`
- Inspect: `kubectl get opensearch`

Look at the example files to understand the CRD structure.

TODO: add comprehensive documentation.

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
