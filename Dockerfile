# syntax=docker/dockerfile:1
# © 2026 aiaiaiai · aiaiaiai.org

# Gems, including prism-bot pinned by commit from GitHub.
FROM ruby:4.0.6-slim AS gems
RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3 \
    && rm -rf /usr/local/bundle/ruby/*/cache

FROM ruby:4.0.6-slim
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 1927 hubot \
    && install -d -o hubot -g hubot /data
WORKDIR /app
# Configuration is the environment; secrets arrive only from infra's sealed envelope. TLS ends at
# the edge, so the process speaks plain HTTP inside the network.
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    PORT=1927 \
    PRISM_HUBOT_INTERACTION_STATE_DIR=/data/interaction-state \
    PRISM_HUBOT_DELIVERY_IDEMPOTENCY_DIR=/data/delivery-idempotency
COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY . .
USER hubot
EXPOSE 1927
CMD ["bin/prism-hubot-container"]
