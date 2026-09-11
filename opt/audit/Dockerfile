# syntax=docker/dockerfile:1

# dep-intel and credential-guard, each pinned to a commit on GitHub, for kapelos site audit.
FROM python:3.12-slim

ARG DEP_INTEL_REF=3b1edfce78b686565ebc38dd7e048e7f81bb9a9d
ARG CREDENTIAL_GUARD_REF=915b3c8179983a3db405ee4ce0ab66fa5fbaef14

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends git ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    for tool in dep-intel:${DEP_INTEL_REF} credential-guard:${CREDENTIAL_GUARD_REF}; do \
        name="${tool%%:*}"; ref="${tool#*:}"; \
        git init --quiet "/opt/$name"; \
        git -C "/opt/$name" fetch --quiet --depth 1 "https://github.com/kingletas/$name" "$ref"; \
        git -C "/opt/$name" checkout --quiet FETCH_HEAD; \
    done

# git reads the store as whoever runs this, and HOME has to be somewhere that user can write.
ENV PATH=/opt/dep-intel/bin:/opt/credential-guard/bin:$PATH \
    DEP_INTEL_DB=/intel/dep-intel.db \
    HOME=/tmp

WORKDIR /site
