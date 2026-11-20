# Recreate the Hermes isolation cluster

This runbook rebuilds the disposable Talos/QEMU cluster and verifies a complete
Matrix-to-Hermes interaction. A fresh cluster has fresh databases: LiteLLM's
model/key records, Miniflux users/API keys, and the Synapse room must be set up
again. Flux reads the public repository's `main` branch, so Git-managed changes
must be pushed there before Flux can apply them.

## Prerequisites and isolated cluster context

Install `talosctl`, `kubectl`, `helm`, `flux`, `qemu`, `curl`, and `jq`. Cluster
creation requires root privileges. Use a short, dedicated `HOME` path: QEMU's
monitor socket has a path-length limit. Never use the workstation's default
kubeconfig, which may target another cluster.

From the repository root, create an isolated config directory and create the
cluster with that home and kubeconfig:

```sh
export TEST_HOME=/tmp/talos-hermes
install -d -m 700 "$TEST_HOME/.kube"
sudo env HOME="$TEST_HOME" KUBECONFIG="$TEST_HOME/.kube/config" \
  ./talos/create.sh
sudo chown "$(id -u):$(id -g)" "$TEST_HOME/.kube/config"
chmod 600 "$TEST_HOME/.kube/config"
export HOME="$TEST_HOME"
export KUBECONFIG="$TEST_HOME/.kube/config"
kubectl config current-context
```

Confirm the context is `admin@talos-hermes-isolation` before continuing. The
exported `HOME` and `KUBECONFIG` must also be set in every new terminal used for
this cluster. The
cluster has one control-plane node, 8 CPUs, 10 GiB RAM, and a 40 GiB disk. The
create script may leave generated `controlplane.yaml` and `worker.yaml` files in
the repository root; keep these local and remove them after provisioning if they
are not needed.

Miniflux needs its admin Secret at first startup. Create its namespace and
Secret before Flux is bootstrapped (choose a local test password):

```sh
MINIFLUX_ADMIN_PASSWORD="$(openssl rand -hex 32)"
kubectl create namespace miniflux --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic miniflux-bootstrap-admin -n miniflux \
  --from-literal=username=miniflux-admin \
  --from-literal=password="$MINIFLUX_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Then install Cilium and Flux:

```sh
./talos/install-core.sh
```

This script uses the active `kubectl` and `helm` context. Flux installs the
`base` and `apps` Kustomizations automatically; application releases begin
reconciling as soon as their manifests arrive. The `apps` Kustomization may
initially wait while CloudNative-PG installs its CRD; allow Flux to retry, then
check with `flux get kustomizations -A` or reconcile it explicitly:

```sh
flux reconcile kustomization apps -n flux-system --timeout=10m
```

## Runtime setup

### LiteLLM and Hermes model access

The LiteLLM database starts without a model or virtual key. For the tested
provider, configure the upstream model and credentials manually through the
LiteLLM admin API. The LiteLLM policy permits unrestricted DNS queries through
the cluster resolver and HTTPS egress to any destination, so provider hostnames
do not need to be declared in Git.

After LiteLLM is Ready, start a port-forward in one terminal:

```sh
kubectl -n litellm port-forward svc/litellm 14000:4000
```

In another terminal, use the master key from the `litellm/litellm` Secret to
call the LiteLLM admin API:

```sh
export HOME=/tmp/talos-hermes
export KUBECONFIG="$HOME/.kube/config"
LITELLM_URL=http://127.0.0.1:14000
LITELLM_MASTER_KEY="$(kubectl -n litellm get secret litellm \
  -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 --decode)"
read -rp 'Upstream model identifier: ' UPSTREAM_MODEL
read -rp 'Upstream API base URL: ' UPSTREAM_API_BASE
read -rsp 'Upstream API key: ' UPSTREAM_API_KEY
printf '\n'
```

Register the model alias and generate its scoped virtual key:

```sh
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg model "$UPSTREAM_MODEL" \
    --arg base "$UPSTREAM_API_BASE" --arg key "$UPSTREAM_API_KEY" \
    '{model_name:"chat",litellm_params:{model:$model,api_base:$base,api_key:$key},model_info:{id:"poc-chat"}}')" \
  "$LITELLM_URL/model/new"
LITELLM_VIRTUAL_KEY="$(curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  --data '{"models":["chat"]}' \
  "$LITELLM_URL/key/generate" | jq -r .key)"
kubectl create namespace hermes-agent --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic hermes-litellm-virtual-key -n hermes-agent \
  --from-literal=api-key="$LITELLM_VIRTUAL_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $LITELLM_VIRTUAL_KEY" \
  -H 'Content-Type: application/json' \
  --data '{"model":"chat","messages":[{"role":"user","content":"Reply with exactly READY."}],"max_tokens":64}' \
  "$LITELLM_URL/chat/completions" | jq -r '.choices[0].message.content'
```

Provider keys and virtual keys are runtime values; do not put them in this
runbook. Verify `POST /chat/completions` with model `chat` and the virtual key
before proceeding.

### Miniflux and the news MCP

Follow [`apps/miniflux/README.md`](../apps/miniflux/README.md) for the exact API
steps. In summary, create a `news-reader` user and Miniflux API key, then create
`miniflux/miniflux-mcp-auth` and
`hermes-agent/hermes-news-mcp-auth-runtime`. The `mcp-bearer-token` and
`MCP_NEWS_API_KEY` values must be identical. The API token belongs only in the
Miniflux/MCP Secret, never in Hermes. Restart `news-mcp` and `hermes-agent` after
changing their Secret-backed environment variables.

Flux runs the feed importer automatically; it loads the 50 sources in
`apps/miniflux/feeds.opml`. Do not add those feeds manually.

### Synapse and Matrix access

Synapse bootstrap Jobs create the `@operator:synapse.poc.test` and
`@hermes:synapse.poc.test` accounts and provide their credentials in
`synapse/synapse-user-credentials`. After a fresh Synapse database is ready:

1. Sign in as the operator and create a room.
2. Configure Hermes to allow that room in all three locations:
   `group_allowed_chats` in `apps/hermes-agent/configmap.yaml`, and
   `MATRIX_ALLOWED_ROOMS` plus `MATRIX_HOME_ROOM` in
   `apps/hermes-agent/helm-release.yaml`.
3. Keep `MATRIX_ALLOWED_USERS` restricted to the intended Matrix sender. The
   tested value is `@operator:synapse.poc.test`; Hermes ignores senders not on
   this allowlist.
4. Commit and push the room/user changes to `main`, wait for Flux to apply them,
   then have the operator join the room and invite Hermes. The Synapse admin
   account was not an authorized inviter in this test.

Room IDs belong to the current Synapse database and must be recreated after a
fresh database. Inviter authorization, allowed sender IDs, and room access are
separate controls.

## Local browser access and verification

Map the ingress hostnames to the current QEMU node address (currently
`10.5.0.2`) in `/etc/hosts` while testing Element:

```text
10.5.0.2 synapse.poc.test element.poc.test
```

Add this line and remove it after testing if it is no longer needed:

```sh
printf '%s\n' '10.5.0.2 synapse.poc.test element.poc.test' | sudo tee -a /etc/hosts
```

Open `http://element.poc.test`; its configured homeserver is
`http://synapse.poc.test`. Remove the temporary host mapping after browser
verification if it is no longer needed.

With the explicit test kubeconfig, verify Flux and workloads, then send a
mentioned message from the allowlisted operator in the configured room asking
Hermes to list news sources. Success means Hermes replies with the source list,
demonstrating Matrix authorization, the news MCP bearer token, and LiteLLM model
access together.

```sh
flux get kustomizations -A
kubectl get deployments -A
kubectl -n miniflux get jobs
```
