#!/usr/local/bin/python3
"""Check that the Hermes gateway is running and updating its heartbeat."""

import json
import os
import sys
from datetime import UTC, datetime
from pathlib import Path


MAX_AGE_SECONDS = 120


def fail(message: str) -> None:
    print(f"gateway health check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    home = Path(os.environ.get("HERMES_HOME", "/opt/data"))
    if not home.is_absolute():
        fail("HERMES_HOME must be absolute")

    home = home.resolve(strict=False)
    state_path = (home / "gateway_state.json").resolve(strict=False)
    try:
        state_path.relative_to(home)
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail("gateway state is missing")
    except (OSError, json.JSONDecodeError):
        fail("gateway state is unreadable")

    if not isinstance(state, dict):
        fail("gateway state is invalid")
    if state.get("gateway_state") != "running":
        fail("gateway is not running")

    updated_at = state.get("updated_at")
    if not isinstance(updated_at, str):
        fail("gateway heartbeat is missing")

    try:
        heartbeat = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
    except ValueError:
        fail("gateway heartbeat is invalid")
    if heartbeat.tzinfo is None:
        fail("gateway heartbeat has no timezone")

    age = (datetime.now(UTC) - heartbeat.astimezone(UTC)).total_seconds()
    if age < 0 or age > MAX_AGE_SECONDS:
        fail("gateway heartbeat is stale")


if __name__ == "__main__":
    main()
