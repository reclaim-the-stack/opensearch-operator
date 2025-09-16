FROM ruby:3.4.5-slim

RUN apt-get update && apt-get install -y build-essential
WORKDIR /app
COPY Gemfile Gemfile.lock* /app/
RUN bundle install --without development test
COPY lib /app/lib

CMD ["ruby", "/app/lib/main.rb"]
