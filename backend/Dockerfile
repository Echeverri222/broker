# syntax=docker/dockerfile:1
# OPS-01 / OPS-03: one production image, three roles chosen by the command:
#   web      bin/rails server         (Puma)
#   worker   bin/jobs                 (Solid Queue, the JOB-01 queues)
#   release  bin/release              (migrations + idempotent seeds, once per deploy)
ARG RUBY_VERSION=3.4
FROM ruby:${RUBY_VERSION}-slim AS build
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT="development:test" BUNDLE_PATH=/usr/local/bundle
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential libpq-dev git libyaml-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /rails
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache
COPY . .

FROM ruby:${RUBY_VERSION}-slim
ENV RAILS_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT="development:test" BUNDLE_PATH=/usr/local/bundle RAILS_LOG_TO_STDOUT=1
RUN apt-get update -qq && apt-get install -y --no-install-recommends libpq5 curl && rm -rf /var/lib/apt/lists/*
WORKDIR /rails
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails
# Non-root. SEC-08: config/master.key is never copied (see .dockerignore); secrets arrive as environment variables.
RUN useradd --create-home --uid 1000 rails && mkdir -p log tmp && chown -R rails:rails log tmp
USER 1000:1000
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=3s --retries=5 CMD curl -fs http://localhost:3000/up || exit 1
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
