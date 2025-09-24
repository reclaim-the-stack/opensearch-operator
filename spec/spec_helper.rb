# frozen_string_literal: true

require_relative "../lib/main"

require "webmock/rspec"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
