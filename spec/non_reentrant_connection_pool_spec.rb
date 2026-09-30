# frozen_string_literal: true

require "socket"

RSpec.describe NonReentrantConnectionPool do
  let(:connection_class) do
    Class.new do
      def closed? = @closed == true
      def close = @closed = true
    end
  end
  let(:created) { [] }
  let(:pool) { NonReentrantConnectionPool.new { connection_class.new.tap { |connection| created << connection } } }

  it "reuses connections whose block completed" do
    first = pool.with { |connection| connection }
    second = pool.with { |connection| connection }

    expect(second).to be first
    expect(created.size).to eq 1
  end

  it "closes connections which were discarded or closed by their block" do
    discarded = pool.with { |connection| pool.discard(connection) && connection }
    closed = pool.with(&:close)

    next_connection = pool.with { |connection| connection }
    expect(discarded).to be_closed
    expect(next_connection).not_to be discarded
    expect(next_connection).not_to be closed
    expect(created.size).to eq 3
  end

  it "closes the connection of a block which raised" do
    expect { pool.with { |_connection| raise IOError } }.to raise_error(IOError)

    expect(created.last).to be_closed
  end

  # The requests which a killed thread, or a break out of a streamed response, leave unread on a connection would be read
  # by the next request on it
  context "with real connections to a keep-alive HTTP server", :real_network do
    let(:server) { TCPServer.new("127.0.0.1", 0) }
    let(:pool) do
      port = server.addr[1]
      NonReentrantConnectionPool.new do
        http = Net::HTTP.new("127.0.0.1", port)
        http.start
        Kubernetes::Connection.new(http:).tap { |connection| created << connection }
      end
    end

    let(:slow_requests_received) { Queue.new }

    before do
      server = self.server
      slow_requests_received = self.slow_requests_received
      @server_thread = Thread.new do
        loop do
          Thread.new(server.accept) do |socket|
            while (request_line = socket.gets)
              path = request_line.split[1]
              nil while (line = socket.gets) && line != "\r\n"
              if path == "/slow"
                slow_requests_received << path
                sleep 1
              end
              body = { path: }.to_json
              response_head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n"
              socket.write response_head + body
            end
          rescue IOError, SystemCallError
            nil
          ensure
            socket.close
          end
        end
      end
    end

    after do
      @server_thread.kill
      server.close
    end

    def fast_request = JSON.parse(pool.with { |connection| connection.get("/fast") }.body).fetch("path")

    # Like CLUSTERS_RESOURCE.watch, where main.rb breaks out of the handler
    def stream(path, &) = pool.with { |connection| connection.get(path, &) }

    it "reuses the connection of completed requests" do
      expect([fast_request, fast_request]).to eq %w[/fast /fast]
      expect(created.size).to eq 1
    end

    it "closes the connection of a thread killed in the middle of a request" do
      thread = Thread.new { pool.with { |connection| connection.get("/slow") } }
      slow_requests_received.pop
      thread.kill
      thread.join

      expect(fast_request).to eq "/fast"
      expect(created.size).to eq 2
    end

    it "closes the connection of a streamed response which the caller broke out of" do
      stream("/slow") { |_response| break }

      expect(fast_request).to eq "/fast"
      expect(created.size).to eq 2
    end
  end
end
