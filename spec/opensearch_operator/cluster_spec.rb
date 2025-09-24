RSpec.describe OpensearchOperator::Cluster do
  subject(:cluster) { OpensearchOperator::Cluster.new(manifest) }

  let(:manifest) { YAML.load_file("spec/fixtures/example-cluster-manifest.yaml") }

  describe "#name" do
    it "returns the name from metadata" do
      expect(cluster.name).to eq "example"
    end
  end

  describe "#namespace" do
    it "returns the namespace from metadata" do
      expect(cluster.namespace).to eq "default"
    end
  end

  describe "#uid" do
    it "returns the uid from metadata" do
      expect(cluster.uid).to eq "123e4567-e89b-12d3-a456-426614174000"
    end
  end

  describe "#spec" do
    it "returns the spec hash" do
      expect(cluster.spec).to be_a Hash
      expect(cluster.spec["image"]).to eq "opensearchproject/opensearch:3.1.0"
    end
  end

  describe "#image" do
    it "returns the image from spec" do
      expect(cluster.image).to eq "opensearchproject/opensearch:3.1.0"
    end
  end

  describe "#replicas" do
    it "returns the replicas from spec" do
      expect(cluster.replicas).to eq 3
    end
  end

  describe "#disk_size" do
    it "returns the diskSize from spec" do
      expect(cluster.disk_size).to eq "5Gi"
    end
  end

  describe "#version" do
    it "returns the version extracted from image" do
      expect(cluster.version).to eq "3.1.0"
    end
  end
end
