FROM ruby:3.4-slim-trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
    poppler-utils libreoffice-writer-nogui fonts-noto-core fonts-liberation2 libpq5 \
    build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock* ./
RUN bundle install
