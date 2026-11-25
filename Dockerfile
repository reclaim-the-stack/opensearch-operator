FROM ruby:4.0.10-slim

# build-essential for the native extensions of bcrypt and concurrent-ruby-ext
RUN apt-get update && apt-get install -y build-essential

WORKDIR /app

COPY Gemfile Gemfile.lock* /app/
ENV BUNDLE_WITHOUT=development:test
RUN bundle install

COPY lib /app/lib
COPY templates /app/templates
COPY bin /app/bin

RUN groupadd -g 10001 app && useradd -r -u 10001 -g app app
RUN chown -R app:app /app /usr/local/bundle
USER app

CMD ["ruby", "/app/lib/main.rb"]
