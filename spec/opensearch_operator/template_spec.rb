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
end
