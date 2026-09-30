# frozen_string_literal: true

RSpec.describe Kubernetes do
  describe ".parse_memory" do
    it "converts whole numbers of Mi and Gi into bytes" do
      expect(Kubernetes.parse_memory("4Gi")).to eq 4 * (1024**3)
      expect(Kubernetes.parse_memory("4608Mi")).to eq 4608 * (1024**2)
    end

    it "parses leading zeros as base 10 rather than octal" do
      expect(Kubernetes.parse_memory("08Gi")).to eq 8 * (1024**3)
      expect(Kubernetes.parse_memory("010Gi")).to eq 10 * (1024**3)
    end

    it "accepts exactly the values the CRD admits" do
      crd = YAML.load_file("deploy/opensearchcluster.crd.yaml")
      spec_schema = crd.dig("spec", "versions", 0, "schema", "openAPIV3Schema", "properties", "spec", "properties")
      resources = spec_schema.dig("resources", "properties")
      patterns = %w[limits requests].map { |kind| resources.dig(kind, "properties", "memory", "pattern") }
      expect(patterns.uniq.size).to eq 1
      # The API server matches patterns with Go regular expressions, whose ^ and $ anchor the whole value
      pattern = Regexp.new(patterns.first.sub(/\A\^/, "\\A").sub(/\$\z/, "\\z"))

      ["4Gi", "4608Mi", "08Gi", "4.5Gi", "8G", "8e9", "1Ti", "8589934592", "4gi", "4 Gi", ""].each do |memory|
        parsed = begin
          Kubernetes.parse_memory(memory)
        rescue Kubernetes::Error
          nil
        end
        admitted = memory.match?(pattern)
        expect(parsed.nil?).to eq(!admitted), "#{memory.inspect} admitted by the CRD: #{admitted}, parsed: #{parsed.inspect}"
      end
    end
  end

  describe "TRANSIENT_NET_ERRORS" do
    def transient?(error)
      raise error
    rescue *Kubernetes::TRANSIENT_NET_ERRORS
      true
    rescue StandardError
      false
    end

    it "treats connection errors as transient" do
      [EOFError, IOError, Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout].each do |error_class|
        expect(transient?(error_class.new)).to be(true), error_class.name
      end
    end

    it "treats a TLS connection closed mid stream without a close_notify as transient" do
      expect(transient?(OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof while reading"))).to be true
    end

    it "doesn't retry handshake or certificate failures, which a proxy rejecting every connection also causes" do
      [
        "SSL_connect returned=1 errno=0 peeraddr=10.96.0.1:443 state=error: unexpected eof while reading",
        "SSL_connect SYSCALL returned=5 errno=0 peeraddr=10.96.0.1:443 state=SSLv3/TLS write client hello",
        "SSL_connect returned=1 errno=0 peeraddr=10.96.0.1:443 state=error: certificate verify failed " \
        "(unable to get local issuer certificate)",
      ].each do |message|
        expect(transient?(OpenSSL::SSL::SSLError.new(message))).to be(false), message
      end
    end
  end
end
