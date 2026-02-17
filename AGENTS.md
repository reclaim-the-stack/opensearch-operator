# Repository Guidelines

## Project Structure & Module Organization

- Source: Ruby code in `lib/` (entrypoint: `lib/main.rb`).
- Namespace: version constant in `lib/opensearch_operator/version.rb`.
- Tests: RSpec specs in `spec/**/*_spec.rb` mirroring `lib/` paths.
- Config: `.ruby-version`, `.rspec`, `Gemfile`, `Gemfile.lock`.
- Kubernetes: CRD samples in `examples/`; CRD, RBAC and operator deployment in `deploy/`.

## Build, Test, and Development Commands

- Install deps: `bundle install` — install gems from `Gemfile`.
- Run tests: `bundle exec rspec` — executes the spec suite.
- Console: `bundle exec irb -I lib -r opensearch_operator` — load library for quick checks.
- Docker build: `docker build -t opensearch-operator-rb .` — builds image.

## Coding Style & Naming Conventions

- Don't abbreviate names of methods / variables
- Avoid small methods, prefer inlining code unless there is clear re-use
- Avoid defensive code unless there is a clear reason to expect invalid input
- Indentation: 2 spaces; no tabs.
- Add `# frozen_string_literal: true` to Ruby files.

## Testing Guidelines

- Avoid implementing or running specs

## Commit & Pull Request Guidelines

- Commits: imperative, concise (e.g., "Add StatefulSet reconcile path"); conventional commits welcomed.
- PRs: include purpose, scope, testing notes, and linked issues; screenshots/log excerpts for behavior changes.
- Requirements: all tests pass; keep PRs small and focused; update docs/manifests when interfaces change.
