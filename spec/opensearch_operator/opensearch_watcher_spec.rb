# frozen_string_literal: true

RSpec.describe OpensearchOperator::OpensearchWatcher do
  subject(:watcher) { described_class.new("http://admin:secret@opensearch-example-client.default.svc.cluster.local:9200") }

  let(:health_requests) { [] }
  let(:sleeps) { [] }
  let(:reported_statuses) { [] }
  let(:wait_for_green) { { wait_for_status: "green", timeout: "10s", ignore: 408 } }

  # Runs one poll per health response, an exception class fails the health request. The nodes request fails in the
  # polls numbered in failing_nodes_polls.
  def poll(*health_responses, failing_nodes_polls: [])
    health_requests = self.health_requests
    polls = health_responses.size
    cluster = Object.new
    cluster.define_singleton_method(:health) do |**params|
      health_requests << params
      response = health_responses.shift
      response.is_a?(Class) ? raise(response, "scripted") : response
    end
    cat = Object.new
    cat.define_singleton_method(:nodes) do |**|
      raise "scripted" if failing_nodes_polls.include?(health_requests.size)

      [{ "name" => "opensearch-example-0", "cluster_manager" => "*", "master" => "*", "version" => "3.5.0" }]
    end
    allow(watcher).to receive_messages(client: Struct.new(:cluster, :cat).new(cluster, cat))
    allow(watcher).to receive(:loop) { |&iteration| polls.times(&iteration) }
    allow(watcher).to receive(:sleep) { |seconds| sleeps << seconds }

    watcher.send(:watch_loop) { |state, changed_keys| reported_statuses << state[:status] if changed_keys.include?(:status) }
  end

  it "polls the health every CHECK_INTERVAL while the cluster is green" do
    poll({ "status" => "green" }, { "status" => "green" })

    expect(health_requests).to eq [{}, {}]
    expect(sleeps).to eq [10, 10]
  end

  it "waits for a yellow or red cluster to turn green rather than sleeping, so the change shows right away" do
    poll({ "status" => "yellow" }, { "status" => "red", "timed_out" => true }, { "status" => "green" })

    expect(health_requests).to eq [{}, wait_for_green, wait_for_green]
    expect(sleeps).to eq [10]
    expect(reported_statuses).to eq %w[yellow red green]
  end

  it "sleeps after a poll which failed past the health request, so it can't spin" do
    poll({ "status" => "yellow" }, { "status" => "green" }, { "status" => "green" }, failing_nodes_polls: [2])

    expect(health_requests).to eq [{}, wait_for_green, wait_for_green]
    expect(sleeps).to eq [10, 10]
    expect(reported_statuses).to eq %w[yellow green]
  end

  it "sleeps between the polls of an unreachable cluster" do
    poll({ "status" => "yellow" }, Faraday::ConnectionFailed, { "status" => "yellow" })

    expect(health_requests).to eq [{}, wait_for_green, {}]
    expect(sleeps).to eq [10, 10, 10]
    expect(reported_statuses).to eq %w[yellow unreachable yellow]
  end

  it "logs an unreachable cluster as a warning rather than reporting it to Sentry, it's expected eg. while it bootstraps" do
    allow(Sentry).to receive(:capture_exception)

    poll(Faraday::ConnectionFailed, OpenSearch::Transport::Transport::Errors::ServiceUnavailable)

    expect(Sentry).not_to have_received(:capture_exception)
    expect(log_output.scan(/WARN -- : class=OpensearchWatcher error=(\S+)/).flatten)
      .to eq %w[Faraday::ConnectionFailed OpenSearch::Transport::Transport::Errors::ServiceUnavailable]
    expect(reported_statuses).to eq ["unreachable"]
  end
end
