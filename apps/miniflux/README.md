# Miniflux news source and MCP

This app installs Miniflux with a persistent CNPG database, subscribes the
non-admin `news-reader` user to the versioned feeds in `feeds.opml`, and serves
a read-only Streamable HTTP MCP endpoint at:

```text
http://news-mcp.miniflux.svc.cluster.local.:8081/mcp
```

The MCP exposes only category/source listing, article search by text/category/
time, and retrieval of a stored article. It accepts no feed URLs and has no
write tools. It authenticates with a bearer token. The Miniflux API key and MCP
bearer token are runtime-only Kubernetes Secret data, never Git data. Hermes
must use exactly the same bearer token as the MCP server.
The trailing DNS dot keeps clients from issuing resolver search-suffix queries
outside the exact service-name DNS egress allowance.

## Runtime secret bootstrap

Flux starts reconciling application releases automatically after
`talos/install-core.sh`. Create `miniflux/miniflux-bootstrap-admin` as described
in the Talos runbook before Flux is installed, or immediately after the
`miniflux` namespace appears. It must contain keys `username` and `password`;
Miniflux uses this identity only for initial admin bootstrap.

After Miniflux is healthy, open a port-forward in one terminal:

```sh
export HOME=/tmp/talos-hermes
export KUBECONFIG="$HOME/.kube/config"
kubectl -n miniflux port-forward svc/miniflux 18080:8080
```

In another terminal, set `MINIFLUX_URL=http://127.0.0.1:18080` and use the
bootstrap admin credentials from the Secret. Miniflux's API uses HTTP Basic
authentication for these requests. The commands below read the bootstrap
credentials into shell variables without printing them, then create the reader
user with a generated password:

```sh
export HOME=/tmp/talos-hermes
export KUBECONFIG="$HOME/.kube/config"
export MINIFLUX_URL=http://127.0.0.1:18080
MINIFLUX_ADMIN_USERNAME="$(kubectl -n miniflux get secret miniflux-bootstrap-admin \
  -o jsonpath='{.data.username}' | base64 --decode)"
MINIFLUX_ADMIN_PASSWORD="$(kubectl -n miniflux get secret miniflux-bootstrap-admin \
  -o jsonpath='{.data.password}' | base64 --decode)"
NEWS_READER_PASSWORD="$(openssl rand -hex 32)"
curl --fail-with-body --silent --show-error \
  --user "$MINIFLUX_ADMIN_USERNAME:$MINIFLUX_ADMIN_PASSWORD" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg password "$NEWS_READER_PASSWORD" \
    '{username:"news-reader",password:$password,is_admin:false}')" \
  "$MINIFLUX_URL/v1/users"
```

If `news-reader` already exists, reset it instead of trying to create a
duplicate:

```sh
NEWS_READER_ID="$(curl --fail-with-body --silent --show-error \
  --user "$MINIFLUX_ADMIN_USERNAME:$MINIFLUX_ADMIN_PASSWORD" \
  "$MINIFLUX_URL/v1/users/news-reader" | jq -r .id)"
curl --fail-with-body --silent --show-error -X PUT \
  --user "$MINIFLUX_ADMIN_USERNAME:$MINIFLUX_ADMIN_PASSWORD" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg password "$NEWS_READER_PASSWORD" \
    '{username:"news-reader",password:$password,is_admin:false}')" \
  "$MINIFLUX_URL/v1/users/$NEWS_READER_ID"
```

As `news-reader`, create an API key:

```sh
MINIFLUX_API_TOKEN="$(curl --fail-with-body --silent --show-error \
  --user "news-reader:$NEWS_READER_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"description":"Hermes news MCP"}' \
  "$MINIFLUX_URL/v1/api-keys" | jq -r .token)"
NEWS_MCP_BEARER_TOKEN="$(openssl rand -hex 32)"
```

The API key is returned once in the response field `token`. Save it as the
Miniflux API token. Requests using that token authenticate with the `X-Auth-Token`
header.

Provision these runtime Secrets:

1. `miniflux/miniflux-mcp-auth` with keys `miniflux-api-token` (the Miniflux
   API token) and `mcp-bearer-token` (the generated MCP bearer).
2. `hermes-agent/hermes-news-mcp-auth-runtime` with key `MCP_NEWS_API_KEY` set
   to the exact same value as `mcp-bearer-token`.

For example, with the token values held in local shell variables:

```sh
kubectl create namespace hermes-agent --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic miniflux-mcp-auth -n miniflux \
  --from-literal=miniflux-api-token="$MINIFLUX_API_TOKEN" \
  --from-literal=mcp-bearer-token="$NEWS_MCP_BEARER_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic hermes-news-mcp-auth-runtime -n hermes-agent \
  --from-literal=MCP_NEWS_API_KEY="$NEWS_MCP_BEARER_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Keep these runtime values out of Git. The MCP uses the Miniflux API token to
call Miniflux; Hermes receives only the independent MCP bearer token. Changing
a Secret does not update environment variables in existing pods, so restart
`news-mcp` and `hermes-agent` after rotating either token:

```sh
kubectl -n miniflux rollout restart deployment/news-mcp
kubectl -n hermes-agent rollout restart deployment/hermes-agent
```

Then reconcile Flux with `flux reconcile kustomization apps -n flux-system`.
The importer skips existing category names and feed URLs, so retries are safe.
If a cluster is recreated, generate fresh credentials and repeat this setup.

## Network boundaries

- Miniflux alone has external DNS and TCP 80/443 egress, plus TCP 5432 to its
  CNPG database. Private-network feed fetching remains disabled.
- The importer can reach only Miniflux API and DNS.
- The MCP can reach only Miniflux API and DNS; inbound requests are limited to
  Hermes-agent and node-local probes/port-forwarding.
- Hermes-agent can reach only the MCP service on TCP 8081, with DNS restricted
  to that service name. The managed Hermes config registers this server for
  Matrix only and allowlists its four read-only tools; it does not change the
  prompt or SOUL text.
