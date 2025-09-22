FROM ruby:3.4.5-slim

RUN apt-get update && apt-get install -y build-essential

WORKDIR /app

COPY Gemfile Gemfile.lock* /app/
RUN bundle install --without development test

COPY lib /app/lib
COPY templates /app/templates
COPY bin /app/bin

RUN groupadd -g 10001 app && useradd -r -u 10001 -g app app
RUN chown -R app:app /app /usr/local/bundle
USER app

CMD ["ruby", "/app/lib/main.rb"]
