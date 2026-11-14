# Isolation test-cluster notes

## Local hostname access

The isolated QEMU node is currently reachable at `10.5.0.2`. HAProxy ingress
uses host ports 80/443 on the node, so `/etc/hosts` maps both PoC hostnames to
that address:

```text
10.5.0.2 synapse.poc.test element.poc.test
```

Use `http://element.poc.test` for Element Web; its configured homeserver is
`http://synapse.poc.test`. If the cluster node address changes after rebuilding
the PoC, update the local `/etc/hosts` mapping as well.

## Matrix room behavior

The local Synapse database belongs to the test cluster. A room ID carried over
from an earlier cluster state may not exist after rebuilding Synapse. On the
2026-11-12 rebuild, the previous configured room ID
`!RmioTcubVcbthCAzoBhjeVnbzWnpUKsL6161HvrDM1A` returned 404 from Synapse, and
Hermes had no joined rooms. This is expected when the configured room has not
been created in the current Synapse instance; check that the room exists before
debugging Hermes connectivity.

For that test instance, a new room was created with ID
`!cl1iLtSaWE74utNrhBGNhzpEOI8ISp7_Yr61rRE9QSQ`. Hermes joined it after the room
was configured in `apps/hermes-agent/configmap.yaml` and
`apps/hermes-agent/helm-release.yaml`, and after `@operator:synapse.poc.test`
invited the bot. The current room ID is specific to that Synapse state; if a
future test-cluster rebuild creates a fresh homeserver database, verify or
create the room again and update all room references.

In this test, Hermes rejected an invite to the room from
`@admin:synapse.poc.test` as unauthorized, but joined after the operator
account joined and invited Hermes. Treat inviter authorization as separate
from room-ID existence. Do not broaden access or change authorization policy
just to work around this observed behavior.

Hermes managed settings live in the mutable `hermes-agent-policy` ConfigMap,
mounted read-only at `/managed`. Update that ConfigMap in place and keep its
name aligned with the mount in `apps/hermes-agent/helm-release.yaml`. Room
access is controlled by both the managed `group_allowed_chats` list and the
`MATRIX_ALLOWED_ROOMS`/`MATRIX_HOME_ROOM` environment variables.
