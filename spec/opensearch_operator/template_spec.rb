# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe OpensearchOperator::Template do
  it "renders mustache template" do
    template = OpensearchOperator::Template.new("spec/fixtures/templates/test.sh.mustache")

    rendered = template.render(
      name: "my-opensearch-cluster",
      repositories: [
        { name: "repo1", access_key: "key1" },
        { name: "repo2", access_key: "key2" },
      ],
    )

    expect(rendered).to eq <<~SH
      echo "Testing my-opensearch-cluster script"
      echo "Repository repo1 with access key key1"
      echo "Repository repo2 with access key key2"
    SH
  end

  it "renders the statefulset.yaml.mustache template" do
    template = OpensearchOperator::Template.new("templates/statefulset.yaml.mustache")

    rendered = template.render(
      bootstrap_path: "/tmp/bootstrap",
      disk_size: "10Gi",
      has_repositories: true,
      heap_size: "5g",
      image: "opensearchproject/opensearch:3.3.0",
      name: "my-opensearch-cluster",
      namespace: "default",
      node_selector: { "node-role.kubernetes.io/database" => "" }.to_json,
      owner_references: [],
      replicas: 3,
      repositories: [
        {
          name: "repo1",
          access_key_secret: { name: "repo1-credentials", key: "access_key" },
          secret_key_secret: { name: "repo1-credentials", key: "secret_key" },
        },
      ],
      repository_secrets_path: "/tmp/repository_secrets",
      resources: {
        limits: { cpu: "1", memory: "4Gi" },
        requests: { cpu: "500m", memory: "4Gi" },
      }.to_json,
      startup_script: "#!/bin/bash\necho Starting OpenSearch...".to_json,
      tolerations: [
        { key: "role", value: "database", effect: "NoSchedule" },
      ].to_json,
      version: "3.3.0",
    )

    # NOTE: Most important part of this spec is that the YAML renders correctly. The verification
    # of volumes is here just because it's one of the more complex parts of the template.
    volumes = rendered.fetch("spec").fetch("template").fetch("spec").fetch("volumes")
    expect(volumes).to include(
      "name" => "repository-secrets",
      "projected" => {
        "sources" => [
          {
            "secret" => {
              "name" => "repo1-credentials",
              "items" => [{ "key" => "access_key", "path" => "repo1/access_key" }],
            },
          },
          {
            "secret" => {
              "name" => "repo1-credentials",
              "items" => [{ "key" => "secret_key", "path" => "repo1/secret_key" }],
            },
          },
        ],
      },
    )
  end

  describe "the startup script" do
    let(:bootstrap_path) { Dir.mktmpdir }

    after { FileUtils.remove_entry(bootstrap_path) }

    # Runs the part of the startup script which decides whether the node may bootstrap a new cluster, as bash -e like the
    # container does
    def initial_cluster_manager_nodes
      script = OpensearchOperator::Template["_startup_script"].render(
        bootstrap_path:, config_yaml_string: nil, has_repositories: false, name: "example", namespace: "default",
        prometheus_exporter_version: "3.5.0.0", repositories: [], uid: "123e4567-e89b-12d3-a456-426614174000"
      )
      bootstrap_part = script.split("\n# Seed hosts").first
      output, status = Open3.capture2e("bash", "-e", "-c", "#{bootstrap_part}\necho \"nodes=$INITIAL_CLUSTER_MANAGER_NODES\"")
      expect(status).to be_success, output
      output[/^nodes=(.*)$/, 1]
    end

    def record_bootstrap(resource_uid)
      File.write(File.join(bootstrap_path, "resource_uid"), resource_uid)
      File.write(File.join(bootstrap_path, "cluster_uuid"), "Q7rVjM5BSnefOwj1a8d2Tw")
    end

    it "lets pod 0 bootstrap a cluster which hasn't bootstrapped yet" do
      expect(initial_cluster_manager_nodes).to eq '"opensearch-example-0"'
    end

    it "keeps the nodes of a bootstrapped cluster from bootstrapping another one" do
      record_bootstrap("123e4567-e89b-12d3-a456-426614174000")

      expect(initial_cluster_manager_nodes).to eq ""
    end

    it "ignores the bootstrap of an earlier resource with the same name" do
      record_bootstrap("00000000-0000-0000-0000-000000000000")

      expect(initial_cluster_manager_nodes).to eq '"opensearch-example-0"'
    end
  end
end
