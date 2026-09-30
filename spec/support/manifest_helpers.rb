# frozen_string_literal: true

module ManifestHelpers
  # The OpenSearch resource of spec/fixtures/example-cluster-manifest.yaml with the given generation, status and spec keys
  def cluster_manifest(generation: 1, uid: nil, status: nil, **spec)
    manifest = YAML.load_file(File.join(__dir__, "..", "fixtures", "example-cluster-manifest.yaml"))
    manifest["metadata"]["generation"] = generation
    manifest["metadata"]["uid"] = uid if uid
    manifest["spec"]["snapshotRepositories"] = []
    manifest["spec"].merge!(spec.transform_keys(&:to_s))
    manifest["status"] = status if status
    manifest
  end
end

RSpec.configure { |config| config.include ManifestHelpers }
