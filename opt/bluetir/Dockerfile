# syntax=docker/dockerfile:1

# Bluetir, pinned to a commit on GitHub, with Chromium for it to drive.
FROM ruby:3.3-slim-bookworm

ARG BLUETIR_REF=cf2e69d16d0fe16519a57dc722ca7fd25764e245

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends git ca-certificates build-essential chromium chromium-driver; \
    rm -rf /var/lib/apt/lists/*; \
    git init --quiet /opt/bluetir; \
    git -C /opt/bluetir fetch --quiet --depth 1 https://github.com/kingletas/bluetir "${BLUETIR_REF}"; \
    git -C /opt/bluetir checkout --quiet FETCH_HEAD; \
    cd /opt/bluetir; \
    bundle config set --local without 'development test'; \
    bundle install --quiet

# Chrome's sandbox needs privileges a container doesn't have, and a local store's certificate is local.
# This browser only ever opens the store Kapelos runs.
RUN printf '#!/bin/sh\nexec /usr/bin/chromium --no-sandbox --ignore-certificate-errors "$@"\n' > /usr/local/bin/chromium-kapelos; \
    chmod +x /usr/local/bin/chromium-kapelos

# Selenium uses the browser and driver installed here, and never downloads its own.
ENV PATH=/opt/bluetir/bin:$PATH \
    SE_BROWSER_PATH=/usr/local/bin/chromium-kapelos \
    SE_DRIVER_PATH=/usr/bin/chromedriver \
    SE_OFFLINE=true \
    HOME=/tmp

WORKDIR /opt/bluetir
ENTRYPOINT ["bluetir"]
