# Production image for decidim.vocdoni.dev: Decidim from vocdoni/decidim plus
# decidim-elections-vocdoni, both pinned by Gemfile.lock. The same image runs
# the `web` (Puma) and `worker` (Sidekiq) services; see railway*.toml.

ARG RUBY_VERSION=3.4.7
ARG NODE_VERSION=24.18.0

FROM ruby:${RUBY_VERSION}-slim AS base

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    RAILS_ENV=production \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_DEPLOYMENT=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git libpq5 postgresql-client libvips42 imagemagick \
      libyaml-0-2 libicu76 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --- build stage: gems, JS packages, compiled assets ------------------------
FROM base AS build

ARG NODE_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git libpq-dev libyaml-dev libicu-dev pkg-config xz-utils zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Shakapacker shells out to `node` from a plain `sh`, so Node has to be on the
# system PATH rather than behind a version manager.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) a=x64 ;; arm64) a=arm64 ;; *) exit 1 ;; esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${a}.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1 --exclude CHANGELOG.md --exclude LICENSE --exclude README.md; \
    node --version

COPY Gemfile Gemfile.lock .ruby-version ./
# The git checkouts keep their .git: the gemspecs list files with
# `git ls-files`, and Bundler evaluates them again at boot.
RUN bundle install --jobs 4 --retry 3 \
    && rm -rf "${BUNDLE_PATH}"/ruby/*/cache

# Rebuild the Vocdoni booth adapter (public/vocdoni/booth-adapter.js) from the
# pinned module source, so the served bundle always matches the Ruby side.
RUN set -eux; \
    gem_dir="$(bundle info --path decidim-elections-vocdoni)"; \
    cd "$gem_dir"; \
    npm ci --no-audit --no-fund; \
    node build/booth_adapter.mjs; \
    rm -rf node_modules

# Decidim is unreleased, so its npm packages are referenced as file:packages/*
# and must come from the exact Decidim checkout in Gemfile.lock.
COPY package.json package-lock.json ./
RUN cp -r "$(bundle info --path decidim)/packages" ./packages \
    && npm ci --no-audit --no-fund

COPY . .
RUN mkdir -p log tmp/pids storage \
    && SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile \
    && rm -rf node_modules packages tmp/cache

# --- runtime stage -----------------------------------------------------------
FROM base

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

RUN useradd --create-home --shell /bin/bash --uid 1000 rails \
    && chown -R rails:rails log tmp storage
USER rails

ENV RAILS_LOG_TO_STDOUT=1

EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
