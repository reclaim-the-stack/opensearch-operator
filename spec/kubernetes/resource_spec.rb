# frozen_string_literal: true

require "socket"

RSpec.describe Kubernetes::Resource do
  describe "#get" do
    subject(:statefulsets) { Kubernetes::Resource.new("statefulsets", group: "apps") }

    def respond(code, body) = allow(Kubernetes).to receive(:get).and_return(Struct.new(:code, :body).new(code, body.to_json))

    it "returns the object" do
      respond("200", { "kind" => "StatefulSet", "spec" => { "replicas" => 5 } })
      expect(statefulsets.get("demo", namespace: "default").dig("spec", "replicas")).to eq 5
    end

    it "returns the Status of a 404, which callers treat as a missing object" do
      respond("404", { "kind" => "Status", "code" => 404 })
      expect(statefulsets.get("demo", namespace: "default")).to include("code" => 404)
      expect(statefulsets.exists?("demo", namespace: "default")).to be false
    end

    it "raises on other errors rather than returning them in place of the object" do
      %w[403 429 503].each do |code|
        respond(code, { "kind" => "Status", "code" => code.to_i, "message" => "status #{code}" })
        expect { statefulsets.get("demo", namespace: "default") }.to raise_error(Kubernetes::Error, /failed: #{code}/)
      end
    end
  end

  describe "#watch" do
    subject(:resource) do
      Kubernetes::Resource.new("opensearches", group: "opensearch.reclaim-the-stack.com", version: "v1alpha1")
    end

    # Raised by the scripted API server once its script ran out, which ends the watch
    let(:script_end) { Class.new(StandardError) }
    let(:requests) { [] }
    let(:delays) { [] }
    let(:received) { [] }

    def object(name, resource_version)
      metadata = { "name" => name, "namespace" => "default", "uid" => "uid-#{name}", "resourceVersion" => resource_version }
      { "kind" => "OpenSearch", "metadata" => metadata }
    end

    def added(name, resource_version) = { "type" => "ADDED", "object" => object(name, resource_version) }
    def modified(name, resource_version) = { "type" => "MODIFIED", "object" => object(name, resource_version) }
    def deleted(name, resource_version) = { "type" => "DELETED", "object" => object(name, resource_version) }

    def bookmark(resource_version, annotations: nil)
      metadata = { "resourceVersion" => resource_version, "annotations" => annotations }.compact
      { "type" => "BOOKMARK", "object" => { "metadata" => metadata } }
    end

    def initial_events_end(resource_version)
      bookmark(resource_version, annotations: { "k8s.io/initial-events-end" => "true" })
    end

    def error_event(code)
      { "type" => "ERROR", "object" => { "kind" => "Status", "code" => code, "message" => "status #{code}" } }
    end

    def initial_request?(params)
      params.values_at(:sendInitialEvents, :resourceVersionMatch, :resourceVersion) == [true, "NotOlderThan", ""]
    end

    # Each step of the script answers one watch request: its events streamed in awkward chunks, an HTTP status or a
    # connection error, optionally followed by a connection error once the events are delivered
    def watch(*script, &handler)
      allow(Kubernetes).to receive(:get) do |_path, params, &block|
        step = script[requests.size]
        requests << params
        raise script_end if step.nil?
        raise step[:raise], "scripted" if step[:raise]

        status = step.fetch(:status, "200")
        response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status).new("1.1", status, "scripted")
        lines = step.fetch(:events, []).map { |event| "#{event.to_json}\n" }.join
        allow(response).to receive(:read_body) do |&chunk_block|
          lines.scan(/.{1,37}/m).each { |chunk| chunk_block.call(+chunk) }
        end
        status_object = { "kind" => "Status", "code" => status.to_i, "message" => step.fetch(:message, "status #{status}") }
        allow(response).to receive(:body).and_return(status_object.to_json)
        block.call(response)
        raise step[:raise_after], "scripted" if step[:raise_after]

        response
      end
      allow(resource).to receive(:sleep) { |seconds| delays << seconds }

      resource.watch do |event|
        metadata = event.dig("object", "metadata")
        received << [event.fetch("type"), metadata.fetch("name"), metadata["resourceVersion"]].compact.join(" ")
        handler&.call(event)
      end
    rescue script_end
      nil
    end

    it "streams the initial state, then resumes from the bookmark which ended it and later resource versions" do
      watch(
        { events: [added("a", "50"), added("b", "40"), initial_events_end("100"), modified("a", "110"), bookmark("120")] },
        { events: [modified("b", "130")] },
      )

      expect(received).to eq ["ADDED a 50", "ADDED b 40", "MODIFIED a 110", "MODIFIED b 130"]
      expect(initial_request?(requests[0])).to be true
      expect(requests[0][:timeoutSeconds]).to eq Kubernetes::WATCH_TIMEOUT.to_i
      expect(requests[1..].map { |params| params[:resourceVersion] }).to eq %w[120 130]
      expect(requests[1..].map { |params| params.key?(:sendInitialEvents) }).to all(be false)
    end

    it "streams the state afresh after a 410 Gone ERROR event, with DELETED events for objects which vanished meanwhile" do
      watch(
        { events: [added("a", "50"), added("b", "40"), initial_events_end("100")] },
        { events: [error_event(410)] },
        { events: [added("a", "150"), initial_events_end("200"), modified("a", "210")] },
      )

      expect(received).to eq ["ADDED a 50", "ADDED b 40", "ADDED a 150", "DELETED b", "MODIFIED a 210"]
      expect(requests.first(3).map { |params| initial_request?(params) }).to eq [true, false, true]
    end

    it "handles an HTTP 410 on resume the same way" do
      watch(
        { events: [added("a", "50"), added("b", "40"), initial_events_end("100")] },
        { status: "410" },
        { events: [added("b", "160"), initial_events_end("200")] },
      )

      expect(received).to eq ["ADDED a 50", "ADDED b 40", "ADDED b 160", "DELETED a"]
    end

    it "starts over when the initial state is interrupted, since its events aren't ordered by resource version" do
      watch(
        { events: [added("a", "50")] },
        { raise: EOFError },
        { events: [added("a", "50"), added("b", "40"), initial_events_end("100")] },
      )

      expect(received).to eq ["ADDED a 50", "ADDED b 40"]
      expect(requests.first(3).map { |params| initial_request?(params) }).to eq [true, true, true]
      expect(requests[3][:resourceVersion]).to eq "100"
    end

    it "resumes from the initial state's bookmark when the connection drops right after it" do
      watch(
        { events: [added("a", "50"), added("b", "40"), initial_events_end("100")], raise_after: EOFError },
      )

      expect(received).to eq ["ADDED a 50", "ADDED b 40"]
      expect(requests[1][:resourceVersion]).to eq "100"
    end

    it "backs off exponentially from 429s, 5xx and connection errors, resetting once a stream delivers events" do
      watch(
        { events: [added("a", "50"), initial_events_end("100")] },
        { status: "429" },
        { status: "503" },
        { raise: Errno::ECONNREFUSED },
        { events: [modified("a", "110")] },
        { raise: Net::ReadTimeout },
        { events: [] },
      )

      expect(received).to eq ["ADDED a 50", "MODIFIED a 110"]
      expect(delays).to eq [1, 2, 4, 1, 2]
    end

    it "keeps backing off from streams which fail or end right away, even with a 200" do
      watch(
        { events: [added("a", "50"), initial_events_end("100")] },
        { events: [error_event(500)] },
        { events: [error_event(500)] },
        { events: [] },
        { events: [bookmark("120")] },
      )

      expect(delays).to eq [1, 2, 4]
      expect(requests[5][:resourceVersion]).to eq "120"
    end

    it "resumes from the last resource version after a transient ERROR event" do
      watch(
        { events: [added("a", "50"), initial_events_end("100"), modified("a", "110"), error_event(500)] },
        { events: [deleted("a", "120")] },
      )

      expect(received).to eq ["ADDED a 50", "MODIFIED a 110", "DELETED a 120"]
      expect(requests[1][:resourceVersion]).to eq "110"
    end

    it "raises on permanent errors instead of retrying forever" do
      expect { watch({ events: [added("a", "50"), initial_events_end("100")] }, { status: "403" }) }
        .to raise_error(Kubernetes::Error, /failed with status 403/)
    end

    it "raises permanent errors with the server's message" do
      message = "sendInitialEvents is forbidden for watch unless the WatchList feature gate is enabled"
      expect { watch({ status: "400", message: }) }.to raise_error(Kubernetes::Error, /sendInitialEvents is forbidden/)
    end

    it "raises on an ERROR event with a permanent code" do
      expect { watch({ events: [added("a", "50"), initial_events_end("100"), error_event(400)] }) }
        .to raise_error(Kubernetes::Error, /status 400/)
    end

    it "doesn't retry SSL errors other than a stream cut without a TLS close_notify" do
      expect { watch({ events: [added("a", "50"), initial_events_end("100")] }, { raise: OpenSSL::SSL::SSLError }) }
        .to raise_error(OpenSSL::SSL::SSLError)
    end

    it "propagates exceptions of the block instead of replaying the event, even network error classes" do
      script = [
        { events: [added("a", "50"), initial_events_end("100"), modified("a", "110")] },
        { events: [modified("a", "110")] },
      ]

      expect { watch(*script) { |event| raise IOError, "handler failure" if event["type"] == "MODIFIED" } }
        .to raise_error(IOError, "handler failure")
      expect(requests.size).to eq 1
    end

    it "streams the current state again every WATCH_RESYNC_INTERVAL, repeating ADDED events and deleting vanished objects" do
      stub_const("Kubernetes::WATCH_RESYNC_INTERVAL", -1)

      watch(
        { events: [added("a", "50"), added("b", "60"), initial_events_end("100")] },
        { events: [added("a", "50"), initial_events_end("200")] },
      )

      expect(received).to eq ["ADDED a 50", "ADDED b 60", "ADDED a 50", "DELETED b"]
      expect(requests.first(2).map { |params| initial_request?(params) }).to eq [true, true]
    end

    context "with a TLS server which drops connections without a close_notify, like a stopping API server", :real_network do
      let(:tls_server) do
        key = OpenSSL::PKey::RSA.new(2048)
        certificate = OpenSSL::X509::Certificate.new
        certificate.version = 2
        certificate.serial = 1
        certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
        certificate.public_key = key.public_key
        certificate.not_before = Time.now - 60
        certificate.not_after = Time.now + 3600
        certificate.sign(key, OpenSSL::Digest.new("SHA256"))
        context = OpenSSL::SSL::SSLContext.new
        context.cert = certificate
        context.key = key
        OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", 0), context)
      end
      let(:paths) { [] }
      let(:sentry_levels) { [] }

      before do
        server = tls_server
        paths = self.paths
        event_line = ->(event) { "#{event.to_json}\n" }
        events = [added("a", "1"), initial_events_end("1"), modified("a", "2")]
        @server_thread = Thread.new do
          loop do
            Thread.new(server.accept) do |socket|
              paths << socket.gets.split[1]
              nil while (line = socket.gets) && line != "\r\n"
              socket.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
              chunks = paths.size == 1 ? events : [modified("a", "3")]
              chunks.map(&event_line).each { |data| socket.write "#{data.bytesize.to_s(16)}\r\n#{data}\r\n" }
              socket.flush
              if paths.size == 1
                sleep 0.2
                socket.io.close # without the TLS close_notify
              else
                sleep 5
              end
            rescue StandardError
              nil
            end
          end
        end
        port = server.to_io.addr[1]
        pool = NonReentrantConnectionPool.new do
          http = Net::HTTP.new("127.0.0.1", port)
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          http.start
          Kubernetes::Connection.new(http:)
        end
        allow(Kubernetes).to receive(:connection_pool).and_return(pool)
        allow(Sentry).to receive(:capture_exception) { |_error, **options| sentry_levels << options[:level] }
      end

      after do
        @server_thread.kill
        tls_server.close
      end

      it "resumes from the last resource version and reports the interruption as a warning" do
        Timeout.timeout(15) do
          resource.watch do |event|
            received << "#{event.fetch('type')} #{event.dig('object', 'metadata', 'resourceVersion')}"
            break if received.size == 3
          end
        end

        expect(received).to eq ["ADDED 1", "MODIFIED 2", "MODIFIED 3"]
        expect(paths.last).to include("resourceVersion=2")
        expect(paths.last).not_to include("sendInitialEvents")
        expect(sentry_levels).to eq [:warning]
        expect(log_output).to match(/watch-interrupted .*SSL_read: unexpected eof while reading/)
      end
    end
  end
end
