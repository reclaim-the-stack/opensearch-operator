# frozen_string_literal: true

# lib/main.rb loads .env, which may configure a real Sentry DSN. An empty value takes precedence over it.
ENV["SENTRY_DSN"] = ""

require_relative "../lib/main"

require "active_support/testing/time_helpers"
require "webmock/rspec"

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |file| require file }

# Password hashing dominates reconciliation time otherwise
BCrypt::Engine.cost = BCrypt::Engine::MIN_COST

module LogOutputHelpers
  def log_output = @log_output.string
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Stubs of methods which don't exist, or calls with arguments the real methods don't take, fail
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.include ActiveSupport::Testing::TimeHelpers
  config.after { travel_back }

  # Keeps the operator's logging out of the test output, specs can inspect it through log_output
  config.include LogOutputHelpers
  config.before do
    @log_output = StringIO.new
    LOGGER.reopen(@log_output)
    LOGGER.level = Logger::DEBUG
  end

  # Specs against real local servers need the unpatched Net::HTTP: WebMock makes real requests without their block, so
  # it reads streamed responses to the end before handing them over
  config.around(:each, :real_network) do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end
end
