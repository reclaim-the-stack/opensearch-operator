# frozen_string_literal: true

# Stands in for the OpensearchWatcher of a Cluster, see FakeWatcherHelpers#fake_watcher
class FakeWatcher
  attr_reader :state, :client

  def initialize(client = nil)
    @client = client
    @state = { status: nil }
  end

  def on_poll(&block) = @on_poll = block
  def run(&block) = @on_change = block

  # What the watcher does when the cluster's health changes
  def report(status)
    @state = @state.merge(status:)
    @on_change.call(@state, [:status])
  end

  # What the watcher does after every successful poll
  def poll = @on_poll.call({}, [])
end

module FakeWatcherHelpers
  # Every Cluster gets the same fake watcher. The default client only answers GET / of a formed cluster.
  def fake_watcher(client: Struct.new(:info).new({ "cluster_uuid" => "Q7rVjM5BSnefOwj1a8d2Tw" }))
    @fake_watcher ||= FakeWatcher.new(client).tap do |watcher|
      allow(OpensearchOperator::OpensearchWatcher).to receive(:new).and_return(watcher)
    end
  end
end

RSpec.configure { |config| config.include FakeWatcherHelpers }
