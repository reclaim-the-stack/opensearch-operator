# frozen_string_literal: true

source "https://rubygems.org"

gem "activesupport"
gem "bcrypt"
gem "concurrent-ruby-ext"
gem "mustache"
gem "opensearch-ruby"
gem "openssl", "~> 3.3" # locked due to: https://github.com/ruby/openssl/issues/949
gem "sentry-ruby"

group :development, :test do
  gem "debug"
  gem "dotenv"
  gem "rspec"
  gem "rubocop-mynewsdesk", git: "https://github.com/mynewsdesk/mnd-rubocop"
end

group :test do
  gem "webmock"
end
