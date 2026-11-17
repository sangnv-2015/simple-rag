FROM ruby:3.4-slim-trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
    poppler-utils libreoffice-writer-nogui fonts-noto-core fonts-liberation2 libpq5 \
    build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile Gemfile.lock* ./
RUN bundle install
# Run as a normal user: the repo is mounted read-only, so a converter exploit cannot rewrite code or .git.
# /cache is created here so a fresh named volume mounted on it inherits this owner.
RUN useradd --create-home --uid 1000 app && mkdir /cache && chown app /cache
USER app
