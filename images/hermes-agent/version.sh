#!/usr/bin/env bash
set -euo pipefail

docker run --rm --entrypoint /opt/hermes/.venv/bin/hermes local/hermes-agent:test --version \
  | /bin/sed --quiet 's/^Hermes Agent v\([^ ]*\).*/v\1/p'
