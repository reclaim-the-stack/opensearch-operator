# frozen_string_literal: true

RSpec.describe Kubernetes::Connection do
  describe "#headers" do
    it "reads the token file for every request since the kubelet rotates projected service account tokens" do
      Dir.mktmpdir do |directory|
        token_path = File.join(directory, "token")
        File.write(token_path, "first-token\n")
        connection = Kubernetes::Connection.new(http: nil, token_path:)
        expect(connection.headers["Authorization"]).to eq "Bearer first-token"

        File.write(token_path, "rotated-token\n")
        expect(connection.headers["Authorization"]).to eq "Bearer rotated-token"
      end
    end

    it "uses a static token, or none" do
      expect(Kubernetes::Connection.new(http: nil, token: "static").headers["Authorization"]).to eq "Bearer static"
      expect(Kubernetes::Connection.new(http: nil).headers).not_to have_key("Authorization")
    end
  end
end
