require "sentry-ruby"

return unless ENV["SENTRY_DSN"].present?

Sentry.init do |config|
  config.dsn = ENV.fetch("SENTRY_DSN")
end
