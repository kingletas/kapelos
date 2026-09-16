# syntax=docker/dockerfile:1

# drexbot, pinned to a commit on GitHub, on the Playwright image its browser version matches.
FROM mcr.microsoft.com/playwright:v1.62.1-noble

ARG DREXBOT_REF=40a9f05155731450ed5c84ce38ea0a3d2a466080

RUN set -eux; \
    git init --quiet /opt/drexbot; \
    git -C /opt/drexbot fetch --quiet --depth 1 https://github.com/kingletas/drexbot "${DREXBOT_REF}"; \
    git -C /opt/drexbot checkout --quiet FETCH_HEAD; \
    cd /opt/drexbot; \
    npm ci --no-audit --no-fund; \
    npm run build; \
    mv ledger /opt/drexbot-seed-ledger; \
    rm -rf baselines results; \
    mkdir -p /state; \
    ln -s /state/ledger ledger; \
    ln -s /state/baselines baselines; \
    ln -s /state/results results

COPY entrypoint.sh /usr/local/bin/drexbot-kapelos
ENV HOME=/tmp
WORKDIR /opt/drexbot
ENTRYPOINT ["drexbot-kapelos"]
