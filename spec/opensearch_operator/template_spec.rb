RSpec.describe OpensearchOperator::Template do
  it "renders mustache template" do
    template = OpensearchOperator::Template.new("spec/fixtures/templates/test.sh.mustache")

    rendered = template.render(
      name: "my-opensearch-cluster",
      repositories: [
        { name: "repo1", access_key_path: "/var/run/credentials/repo1/access_key" },
        { name: "repo2", access_key_path: "/var/run/credentials/repo2/access_key" },
      ],
    )

    expect(rendered).to eq <<~SH
      echo "Testing my-opensearch-cluster script"
      echo "Repository repo1 reading access key from /var/run/credentials/repo1/access_key"
      echo "Repository repo2 reading access key from /var/run/credentials/repo2/access_key"
    SH
  end
end
