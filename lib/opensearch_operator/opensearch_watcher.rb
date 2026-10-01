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
#   # - :status (String, "green", "yellow", "red" or "unreachable")
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

    # Called on every poll with the raw cluster health and _cat/nodes responses, regardless of state changes
    def on_poll(&block)
      @on_poll_callback = block
    end

    def stop
      @thread&.kill
      @thread = nil
    end

    private

    def watch_loop
      loop do
        # While the cluster is yellow or red the health request waits for it to turn green rather than the loop sleeping,
        # so rolling restarts and node drains (see Cluster#update_pod_disruption_budget) proceed as soon as it does
        waited_for_green = false
        if %w[yellow red].include?(@state[:status])
          # Answered with a 408 when the cluster didn't turn green within the timeout
          health = client.cluster.health(wait_for_status: "green", timeout: "#{CHECK_INTERVAL}s", ignore: 408)
          waited_for_green = true
        else
          health = client.cluster.health
        end
        status = health["status"]

        nodes = client.cat.nodes(h: "name,cluster_manager,master,version", format: "json")
        number_of_nodes = nodes.length
        master = nodes.find { |n| n["master"] == "*" }&.fetch("name")
        cluster_manager = nodes.find { |n| n["cluster_manager"] == "*" }&.fetch("name")
        version = (nodes.find { |n| n["master"] == "*" } || nodes.first)&.fetch("version")

        new_state = { number_of_nodes:, master:, cluster_manager:, status:, version: }

        changed_keys = new_state.keys.reject { |key| @state[key] == new_state[key] }

        # LOGGER.debug "class=OpensearchWatcher action=refresh-state url=#{@url} changed_keys=#{changed_keys.join(",")}"

        if changed_keys.any?
          @state = new_state

          changes = changed_keys.map { |key| "#{key}=#{new_state[key]}" }.join(",")
          LOGGER.info "class=OpensearchWatcher action=state-changed url=#{@url_without_basicauth} changes=#{changes}"

          yield(new_state, changed_keys)
        end

        if @on_poll_callback
          begin
            @on_poll_callback.call(health, nodes)
          rescue StandardError => e
            Sentry.capture_exception(e)
            LOGGER.error "class=OpensearchWatcher action=on-poll-failed url=#{@url_without_basicauth} error=#{e.class} message=#{e.message}"
          end
        end
      rescue OpenSearch::Transport::Transport::Error, Faraday::Error => e
        # An unreachable cluster is expected at times (bootstrapping, full outage) so we report it as a warning
        # rather than an error to stay out of alerting, and surface it via the status instead.
        LOGGER.warn "class=OpensearchWatcher error=#{e.class} url=#{@url_without_basicauth} message=#{e.message}"
        Sentry.capture_exception(e, level: :warning, fingerprint: ["opensearch-unreachable", @url_without_basicauth])

        unless @state[:status] == "unreachable"
          @state = @state.merge(status: "unreachable")
          yield(@state, [:status])
        end
      rescue StandardError => e
        # Anything else is a bug, but must not kill the watcher thread
        Sentry.capture_exception(e)
        LOGGER.error "class=OpensearchWatcher action=poll-failed url=#{@url_without_basicauth} error=#{e.class} message=#{e.message}"
      ensure
        sleep CHECK_INTERVAL unless waited_for_green
      end
    end
  end
end
