require "opensearch-ruby"

# Monitors the state of a single OpenSearch cluster via a URL (the OpenSearch REST API endpoint).
#
# Example usage:
# watcher = OpensearchWatcher.new("http://opensearch-my-cluster.default.svc.cluster.local:9200")
# watcher.run do |new_state, changed_keys|
#   # The block passed to `run` will be called whenever the state changes.
#   # The `new_state` hash contains the following keys:
#   # - :number_of_nodes (Integer)
#   # - :master (String, node name)
#   # - :cluster_manager (String, node name)
#   # - :status (String, "Green", "Yellow", "Red")
#   # - :version (String, OpenSearch version)
#   puts "State changed: #{changed_keys.join(", ")}"
#   puts new_state.inspect
# end
# ...
# watcher.stop # stops the watcher thread

class OpensearchOperator
  class OpensearchWatcher
    CHECK_INTERVAL = 10

    attr_reader :client, :state

    def initialize(url)
      @url = url
      @url_without_basicauth = url.sub(%r{^(https?://)([^/@]+@)?}, '\1')
      @client = OpenSearch::Client.new(url:, transport_options: { ssl: { verify: false } })
      @state = {
        number_of_nodes: nil,
        master: nil,
        cluster_manager: nil,
        status: nil,
        version: nil,
      }
      @thread = nil
    end

    def run(&)
      raise ArgumentError, "Block is required" unless block_given?

      @thread = Thread.new { watch_loop(&) }

      self
    end

    def on_green(&block)
      if @state[:status] == "green"
        block.call
      else
        @on_green_callback = block
      end
    end

    def stop
      @thread&.kill
      @thread = nil
    end

    private

    def watch_loop
      loop do
        nodes = client.cat.nodes(h: "name,cluster_manager,master,version", format: "json")
        number_of_nodes = nodes.length
        master = nodes.find { |n| n["master"] == "*" }&.fetch("name")
        cluster_manager = nodes.find { |n| n["cluster_manager"] == "*" }&.fetch("name")
        version = (nodes.find { |n| n["master"] == "*" } || nodes.first)&.fetch("version")

        health = client.cluster.health
        status = health["status"]

        new_state = { number_of_nodes:, master:, cluster_manager:, status:, version: }

        changed_keys = new_state.keys.reject { |key| @state[key] == new_state[key] }

        # LOGGER.debug "class=OpensearchWatcher action=refresh-state url=#{@url} changed_keys=#{changed_keys.join(",")}"

        if @on_green_callback && status == "green"
          begin
            @on_green_callback.call
            @on_green_callback = nil
          rescue StandardError => e
            LOGGER.error "class=OpensearchWatcher action=on-green-callback-error url=#{@url_without_basicauth} error=#{e.class} message=#{e.message}"
          end
        end

        if changed_keys.any?
          @state = new_state

          changes = changed_keys.map { |key| "#{key}=#{new_state[key]}" }.join(",")
          LOGGER.info "class=OpensearchWatcher action=state-changed url=#{@url_without_basicauth} changes=#{changes}"

          yield(new_state, changed_keys)
        end
      rescue OpenSearch::Transport::Transport::Error, Faraday::Error => e
        LOGGER.warn "class=OpensearchWatcher error=#{e.class} url=#{@url_without_basicauth} message=#{e.message}"
      ensure
        sleep CHECK_INTERVAL
      end
    end
  end
end
