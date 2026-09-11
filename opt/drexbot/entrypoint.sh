#!/bin/sh
# Gives each site its own ledger, baselines and results, starting from the ledger drexbot ships.
set -eu
mkdir -p /state/ledger /state/baselines /state/results
[ -n "$(ls -A /state/ledger)" ] || cp -R /opt/drexbot-seed-ledger/. /state/ledger/
exec /opt/drexbot/bin/drexbot "$@"
