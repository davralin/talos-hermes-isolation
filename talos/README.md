# Recreate the Hermes isolation cluster

This runbook covers rebuilding a working local cluster from this repository.
It distinguishes what Flux recreates from the runtime state that must be set up
again after a fresh database is created.

## Create the cluster and bootstrap Flux

From the repository root, create the local QEMU cluster:

```sh
./talos/create.sh
```

The script uses `talos/schematic.yaml` and `talos/config-patch.yaml` to create
`talos-hermes-isolation`: one control-plane node, 8 CPUs, 10 GiB RAM, and a
40 GiB disk.

Use the Kubernetes context generated for this test cluster explicitly. The
bootstrap script uses the current `kubectl` and `helm` context, so run it with a
dedicated test-cluster kubeconfig and confirm that its current context targets
`talos-hermes-isolation`. Never run it against HomeProd.

```sh
./talos/install-core.sh
```

This installs Cilium and Flux, then bootstraps the Flux source and `base`
Kustomization. The Git source is the public repository's `main` branch. Flux
reconciles `gitops/base` and, through it, the applications in `apps/`; no
per-application apply or wait steps are needed.

## Runtime setup

### LiteLLM and Hermes model access

The LiteLLM Secret is already declared in Git. The new database has no model or
virtual-key records, so configure these in LiteLLM after it is deployed:

1. Configure whichever LLM upstream is appropriate for this environment.
2. Register its model under the LiteLLM alias `chat`.
3. Create a virtual key named `chat`, restricted to the model alias `chat`.
4. Provide that key in the runtime Secret
   `hermes-agent/hermes-litellm-virtual-key`, key `api-key`.

Keep upstream credentials and virtual-key values out of this runbook.

### Miniflux and the news MCP

Miniflux's bootstrap and API Secrets are runtime-provisioned rather than
included in the Miniflux Kustomization. After Flux creates the `miniflux`
namespace, provision:

1. `miniflux/miniflux-bootstrap-admin` with keys `username` and `password`.
2. Once Miniflux is available, create the non-admin `news-reader` user and an
   API token for it.
3. `miniflux/miniflux-mcp-auth` with keys `miniflux-api-token` and
   `mcp-bearer-token`.
4. Update the declared Secret `hermes-agent/hermes-news-mcp-auth`, key
   `MCP_NEWS_API_KEY`, with only the MCP bearer token. Keep the Miniflux API
   token inside the MCP service; do not give it to Hermes.

Use a secret-safe method to provision or update Secret values. Flux deploys the
feed importer and imports the 50 public sources defined in
`apps/miniflux/feeds.opml`; do not add those feeds manually.

### Synapse and the Matrix room

Synapse Secrets and its bootstrap Jobs are declared in Git. Flux deploys the
jobs that create the operator and Hermes users and populate the declared
Hermes Matrix-token Secret.

A fresh Synapse database has no existing test room. Create a room, then use the
operator account to invite Hermes. Update the new room ID in both places:

- `apps/hermes-agent/configmap.yaml`: `group_allowed_chats`
- `apps/hermes-agent/helm-release.yaml`: `MATRIX_ALLOWED_ROOMS` and
  `MATRIX_HOME_ROOM`

Commit those changes and let Flux reconcile them. In this test setup, Hermes
rejected an invite sent by the Synapse admin account; the operator account
successfully invited it.

## Verify

Using the explicit test-cluster context, check that Flux has reconciled the
repository and that the application workloads are healthy. Then verify:

- LiteLLM exposes the `chat` alias and its virtual key is limited to `chat`.
- Miniflux contains the 50 feeds from `feeds.opml`.
- `hermes mcp test news` connects and lists the read-only news tools.
- Hermes is joined to the newly configured Matrix room and can reach the news
  MCP and LiteLLM model.

Do not include Secret values in command output or documentation.
