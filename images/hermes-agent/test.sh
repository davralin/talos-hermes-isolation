#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "$0")" && pwd)"
image="local/hermes-agent:test"

cd "$app_dir"

fail() {
  printf 'FAILED: %s\n' "$*" >&2
  exit 1
}

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  TAGS="$image" docker buildx bake image-local
fi

docker run --rm \
  --read-only \
  --tmpfs /opt/data:uid=10000,gid=10000,mode=0700 \
  --tmpfs /tmp:uid=10000,gid=10000,mode=1777 \
  "$image" --version

docker run --rm --entrypoint /bin/sh "$image" -c '
  set -eu

  fail() {
    printf "FAILED: %s\\n" "$*" >&2
    exit 1
  }

  test "$(id -u)" = 10000 || fail "container does not run as UID 10000"
  test "$(id -g)" = 10000 || fail "container does not run as GID 10000"
  test ! -e /init || fail "s6 init is present"
  test ! -e /etc/s6-overlay || fail "s6 overlay is present"
  for command in docker ffmpeg git node npm ssh; do
    ! command -v "$command" >/dev/null 2>&1 || fail "unexpected command in PATH: $command"
  done
  for path in \
    /opt/hermes/apps \
    /opt/hermes/plugins/platforms/photon \
    /opt/hermes/scripts/whatsapp-bridge \
    /opt/hermes/tools/computer_use \
    /opt/hermes/tools/computer_use_tool.py \
    /opt/hermes/ui-tui \
    /opt/hermes/pyproject.toml \
    /opt/hermes/setup.py \
    /usr/local/lib/python3.14/site-packages/pip \
    /opt/hermes/uv.lock; do
    test ! -e "$path" || fail "unexpected artifact remains: $path"
  done
  test ! -e /opt/hermes/plugins/computer_use || fail "computer-use plugin remains"
  test ! -e /opt/hermes/hermes_cli/subcommands/computer_use.py || fail "computer-use CLI command remains"
  test ! -e /opt/hermes/hermes_cli/subcommands/computer_use_screen.py || fail "computer-use screen CLI command remains"
  command -v rg >/dev/null || fail "ripgrep is unavailable"
  /opt/hermes/.venv/bin/python -c "import mcp, olm, openai, sqlite3; assert sqlite3.sqlite_version_info >= (3, 51, 3)" || fail "required Python dependencies or fixed SQLite are unavailable"
  /opt/hermes/.venv/bin/python -c "import importlib.metadata as metadata; assert metadata.version(\"hermes-agent\") == \"0.22.5\"" || fail "Hermes package metadata is not the release version"
  /opt/hermes/.venv/bin/python -c "import importlib.metadata as metadata; assert \"brotlicffi\" not in {distribution.metadata[\"Name\"].lower() for distribution in metadata.distributions()}" || fail "brotlicffi remains installed"
  test -f /opt/hermes/install-stamp.json || fail "Hermes install stamp is missing"
  /opt/hermes/.venv/bin/hermes gateway --help >/dev/null || fail "gateway CLI help failed"
'

docker run --rm \
  --read-only \
  --tmpfs /opt/data:uid=10000,gid=10000,mode=0700 \
  --tmpfs /tmp:uid=10000,gid=10000,mode=1777 \
  --entrypoint /opt/hermes/.venv/bin/python \
  "$image" -c '
import json
import os
import pathlib
import subprocess
from datetime import UTC, datetime, timedelta

root = pathlib.Path("/tmp/gateway-health")
root.mkdir()
state = root / "gateway_state.json"
env = os.environ | {"HERMES_HOME": str(root)}

def check(payload, expected):
    state.write_text(json.dumps(payload))
    kwargs = {"env": env}
    if expected:
        kwargs.update(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = subprocess.run(["/usr/local/bin/hermes-gateway-healthcheck"], **kwargs)
    if result.returncode != expected:
        raise SystemExit(f"health check returned {result.returncode}, expected {expected}")

check({"gateway_state": "running", "updated_at": datetime.now(UTC).isoformat()}, 0)
check({"gateway_state": "running", "updated_at": (datetime.now(UTC) - timedelta(seconds=121)).isoformat()}, 1)
check({"gateway_state": "degraded", "updated_at": datetime.now(UTC).isoformat()}, 1)
'

healthcheck="$(docker image inspect "$image" --format '{{json .Config.Healthcheck.Test}}')"
test "$healthcheck" = '["CMD","/usr/local/bin/hermes-gateway-healthcheck"]' || fail "unexpected health check metadata: $healthcheck"

docker run --rm \
  --read-only \
  --tmpfs /opt/data:uid=10000,gid=10000,mode=0700 \
  --tmpfs /tmp:uid=10000,gid=10000,mode=1777 \
  --entrypoint /bin/sh \
  "$image" -c '
    set -eu

    fail() {
      printf "FAILED: %s\\n" "$*" >&2
      exit 1
    }

    if touch /root-filesystem-write; then
      fail "root filesystem is writable"
    fi
    test -w /opt/data || fail "/opt/data is not writable"
    test -w /tmp || fail "/tmp is not writable"
  '

set +e
gateway_output="$(timeout 15s docker run --rm \
  --read-only \
  --tmpfs /opt/data:uid=10000,gid=10000,mode=0700 \
  --tmpfs /tmp:uid=10000,gid=10000,mode=1777 \
  "$image" gateway run 2>&1)"
gateway_status=$?
set -e

if [[ "$gateway_status" -ne 124 ]]; then
  printf 'FAILED: gateway exited with status %s instead of timing out\n%s\n' "$gateway_status" "$gateway_output" >&2
  exit 1
fi
if [[ "$gateway_output" != *"Hermes Gateway Starting"* ]]; then
  printf 'FAILED: gateway did not report startup\n%s\n' "$gateway_output" >&2
  exit 1
fi
if [[ "$gateway_output" == *"Traceback"* ]]; then
  printf 'FAILED: gateway emitted a traceback\n%s\n' "$gateway_output" >&2
  exit 1
fi

set +e
computer_use_output="$(docker run --rm \
  --read-only \
  --tmpfs /opt/data:uid=10000,gid=10000,mode=0700 \
  --tmpfs /tmp:uid=10000,gid=10000,mode=1777 \
  "$image" computer-use --help 2>&1)"
computer_use_status=$?
set -e

if [[ "$computer_use_status" -eq 0 ]]; then
  printf 'FAILED: computer-use command unexpectedly succeeded\n%s\n' "$computer_use_output" >&2
  exit 1
fi
if [[ "$computer_use_output" != *"not a \`hermes\` command"* ]]; then
  printf 'FAILED: computer-use command was not rejected as unavailable\n%s\n' "$computer_use_output" >&2
  exit 1
fi
if [[ "$computer_use_output" == *"Traceback"* ]]; then
  printf 'FAILED: computer-use rejection emitted a traceback\n%s\n' "$computer_use_output" >&2
  exit 1
fi
