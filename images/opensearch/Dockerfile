# OpenSearch with the plugins the operator uses pre-installed, so pods don't download them on every start (see
# templates/_startup_script.sh.mustache). Built and published as ghcr.io/reclaim-the-stack/opensearch:<version> by
# .github/workflows/opensearch-images.yml.
ARG OPENSEARCH_VERSION
FROM opensearchproject/opensearch:${OPENSEARCH_VERSION}

LABEL org.opencontainers.image.source="https://github.com/reclaim-the-stack/opensearch-operator"

ARG OPENSEARCH_VERSION
# The Prometheus exporter has to match the OpenSearch version exactly, a version without an exporter release fails here
RUN opensearch-plugin install --batch \
      "https://github.com/opensearch-project/opensearch-prometheus-exporter/releases/download/${OPENSEARCH_VERSION}.0/prometheus-exporter-${OPENSEARCH_VERSION}.0.zip" \
  && opensearch-plugin install --batch repository-s3 \
  && opensearch-plugin remove opensearch-performance-analyzer
