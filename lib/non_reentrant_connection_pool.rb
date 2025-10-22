# frozen_string_literal: true

# Simple, unbounded, lazy, non-reentrant connection pool. Expects connection objects to
# respond to .close and .closed? (if .closed? is not defined, connections are assumed
# to always be healthy).
#
# API:
#   .new { ...build a connection... }
#   .with { |conn| ... }
#   .discard(connection)
#
# Thread-safety is provided by concurrent-ruby's Concurrent::Array and Concurrent::Set.

require "concurrent-ruby"

class NonReentrantConnectionPool
  def initialize(&connection_factory)
    raise ArgumentError, "SimpleConnectionPool requires a connection factory block" unless connection_factory

    @factory = connection_factory
    @available = Concurrent::Array.new # idle connections
    @discarded = Concurrent::Set.new # connections to drop on check-in
  end

  def with
    raise ArgumentError, "SimpleConnectionPool#with requires a block" unless block_given?

    conn = checkout
    begin
      yield conn
    ensure
      if @discarded.delete?(conn) || connection_broken?(conn)
        safely_close(conn)
      else
        @available.push(conn)
      end
    end
  end

  # Mark a specific connection object to be discarded (and closed) when its current .with block exits.
  def discard(connection)
    @discarded.add(connection)
  end

  private

  def checkout
    # pop is atomic on Concurrent::Array; if nil, lazily create a new connection.
    @available.pop || @factory.call
  end

  def connection_broken?(connection)
    connection.respond_to?(:closed?) && connection.closed?
  end

  def safely_close(connection)
    connection.close
  rescue StandardError
    # swallow close errors; we're discarding anyway
  end
end
