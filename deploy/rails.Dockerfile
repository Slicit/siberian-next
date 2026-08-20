# One Dockerfile for every Rails service in core/. The service is a build arg
# rather than a copy of this file per app, because the four Rails services
# differ in their code, not in how they are built.
#
# Build context is the repository root so lib/ can be copied in. This is a
# consequence of "shared code goes in lib/, not extracted gems" (LOGBOOK.md).
#
#   docker build -f deploy/rails.Dockerfile --build-arg SERVICE=orchestrator .
ARG RUBY_VERSION=3.3
FROM ruby:${RUBY_VERSION}-slim

ARG SERVICE
ENV SERVICE=${SERVICE} \
    RAILS_ENV=development \
    BUNDLE_PATH=/usr/local/bundle \
    LANG=C.UTF-8

RUN apt-get update -qq && apt-get install --no-install-recommends -y \
      build-essential git libpq-dev libyaml-dev pkg-config curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Shared code first: it changes less often than the app, so the layer survives
# most rebuilds.
COPY lib/ /app/lib/

COPY core/${SERVICE}/Gemfile core/${SERVICE}/Gemfile.lock* /app/
RUN if [ -f Gemfile ]; then bundle install; fi

COPY core/${SERVICE}/ /app/

EXPOSE 3000

# The pid file is removed before the server starts.
#
# Rails writes tmp/pids/server.pid and refuses to boot if it already exists. A
# container that was killed rather than stopped leaves one behind, and in a new
# container the pid it names is 1, which always exists: the service then
# crash-loops with "A server is already running", which reads as two servers
# rather than as a file nobody deleted. It happened to two services when the
# host this box runs on went down.
CMD ["sh", "-c", "rm -f tmp/pids/server.pid && exec bin/rails server -b 0.0.0.0 -p 3000"]
