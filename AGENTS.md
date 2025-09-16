# Repository Guidelines

## Project Structure & Module Organization
- Source: Ruby code in `lib/` (entrypoint: `lib/main.rb`).
- Namespace: version constant in `lib/opensearch_operator/version.rb`.
- Tests: RSpec specs in `spec/**/*_spec.rb` mirroring `lib/` paths.
- Config: `.ruby-version`, `.rspec`, `Gemfile`, `Gemfile.lock`.
- Kubernetes: CRD and samples in `manifests/`; deployment/RBAC in `deploy/`.

## Build, Test, and Development Commands
- Install deps: `bundle install` — install gems from `Gemfile`.
- Run tests: `bundle exec rspec` — executes the spec suite.
- Console: `bundle exec irb -I lib -r opensearch_operator` — load library for quick checks.
- Docker build: `docker build -t opensearch-operator-rb .` — builds image (Ruby 3.4.5).
- Kubernetes apply: `kubectl apply -f manifests/` and `kubectl apply -f deploy/` — install CRD and operator.

Examples
- Run a single spec: `bundle exec rspec spec/opensearch_operator/version_spec.rb`.
- Tail logs when running in cluster: `kubectl logs -f deploy/opensearch-operator -n <ns>`.

## Coding Style & Naming Conventions
- Indentation: 2 spaces; no tabs.
- Files: `snake_case.rb`; Classes/Modules: `CamelCase` under the `OpenSearchOperator` namespace.
- Add `# frozen_string_literal: true` to Ruby files.

## Testing Guidelines
- Framework: RSpec with `expect` syntax.
- Location: `spec/` mirroring `lib/` (e.g., `lib/foo/bar.rb` → `spec/foo/bar_spec.rb`).
- Scope: cover reconciliation logic with unit-level seams; mock I/O to Kubernetes.
- Run locally: `bundle exec rspec` before opening a PR.

## Commit & Pull Request Guidelines
- Commits: imperative, concise (e.g., "Add StatefulSet reconcile path"); conventional commits welcomed.
- PRs: include purpose, scope, testing notes, and linked issues; screenshots/log excerpts for behavior changes.
- Requirements: all tests pass; keep PRs small and focused; update docs/manifests when interfaces change.
