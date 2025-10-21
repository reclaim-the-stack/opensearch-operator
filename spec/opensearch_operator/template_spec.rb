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
end
