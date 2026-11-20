# Talos Hermes Isolation PoC

A disposable, local proof of concept for running the Hermes Agent in an isolated
Kubernetes environment. The cluster is created with Talos in QEMU and managed
with Flux. Hermes communicates through a local Matrix homeserver, uses LiteLLM
for model access, and reads news through a read-only MCP service backed by
Miniflux.

This repository records the PoC as built. It is intended to be archived and
kept frozen when the experiment is complete, rather than maintained as a
long-lived deployment.

## What it contains

- **Talos and GitOps bootstrap** — scripts and configuration for creating the
  local cluster and installing Cilium and Flux.
- **Hermes Agent** — a custom, reduced container image and its Kubernetes
  configuration. Hermes connects to Matrix, LiteLLM, and the news MCP service.
- **Matrix** — Synapse and Element Web for local chat and the Hermes interface.
- **News service** — Miniflux, a feed importer, and a read-only MCP adapter.
- **Model gateway** — LiteLLM and its PostgreSQL database.
- **Isolation controls** — Kata Containers for the Hermes workload, restricted
  pod permissions, and network policies around the applications.

## Repository layout

```text
talos/                  Local cluster creation and rebuild runbook
gitops/base/            Cluster services and Flux configuration
apps/                   Application manifests
images/hermes-agent/    Custom Hermes image, build configuration, and tests
```

## Recreate the PoC

See [`talos/README.md`](talos/README.md) for cluster creation, Flux bootstrap,
runtime setup, and verification. It documents the manual setup needed for a
fresh cluster, including LiteLLM credentials, Miniflux credentials, and
Matrix-room creation.

Additional component details are in:

- [`apps/miniflux/README.md`](apps/miniflux/README.md) — feed import, news MCP,
  and its runtime credentials.
- [`images/hermes-agent/README.md`](images/hermes-agent/README.md) — custom
  image contents and runtime requirements.

The manifests and bootstrap steps are specific to this local test environment;
they are not a general-purpose or production deployment guide.
