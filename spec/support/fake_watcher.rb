# frozen_string_literal: true

# Stands in for the OpensearchWatcher of a Cluster, see FakeWatcherHelpers#fake_watcher
class FakeWatcher
  attr_reader :state, :client

  def initialize(client = nil)
    @client = client
    @state = { status: nil }
  end

  def on_poll(&block) = @on_poll = block
  def run(&block) = (@on_change = block) && self
  def stop = nil

  # What the watcher does when the cluster's health changes
  def report(status)
    @state = @state.merge(status:)
    @on_change.call(@state, [:status])
  end

  # What the watcher does after every successful poll
  def poll(health = {}, nodes = []) = @on_poll.call(health, nodes)
end

module FakeWatcherHelpers
  # Every Cluster gets the same fake watcher, and a rolling restart whose tick returns rolling_restart_settled
  def fake_watcher(client: nil)
    @fake_watcher ||= FakeWatcher.new(client).tap do |watcher|
      allow(OpensearchOperator::OpensearchWatcher).to receive(:new).and_return(watcher)
      rolling_restart = instance_double(OpensearchOperator::RollingRestart)
      allow(rolling_restart).to receive(:tick) { @rolling_restart_settled }
      allow(OpensearchOperator::RollingRestart).to receive(:new).and_return(rolling_restart)
    end
  end
end

RSpec.configure { |config| config.include FakeWatcherHelpers }
