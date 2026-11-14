# Miniflux news source and MCP

This app installs Miniflux with a persistent CNPG database, subscribes the
non-admin `news-reader` user to the versioned feeds in `feeds.opml`, and serves
a read-only Streamable HTTP MCP endpoint at:

```text
http://news-mcp.miniflux.svc.cluster.local.:8081/mcp
```

The MCP exposes only category/source listing, article search by text/category/
time, and retrieval of a stored article. It accepts no feed URLs and has no
write tools. It authenticates with a bearer token. Miniflux’s API key and the
MCP bearer token are runtime-only Kubernetes Secret data, never Git data.
The trailing DNS dot keeps clients from issuing resolver search-suffix queries
outside the exact service-name DNS egress allowance.

## Runtime secret bootstrap

Before reconciling the Miniflux HelmRelease on a fresh cluster, provision
`miniflux/miniflux-bootstrap-admin` with `username` and a strong `password`.
Use a secret-safe local method; do not put credentials in this repository or
on a shell command line. Miniflux uses this identity only for initial admin
bootstrap.

After Miniflux is healthy:

1. Authenticate to its API as the bootstrap admin and create a non-admin user
   named `news-reader` with a generated password.
2. Authenticate as `news-reader` and create an API key.
3. Provision `miniflux/miniflux-mcp-auth` with keys `miniflux-api-token` and
   `mcp-bearer-token`. The feed-import Job and MCP Deployment use these keys.
4. Reconcile the feed-import Job and `news-mcp` HelmRelease. The importer skips
   existing category names and feed URLs, so retries are safe.

Each referenced runtime Secret must exist before its consuming pod or Job can
become Ready. If a cluster is recreated, bootstrap new credentials rather than
reusing old ones.

## Network boundaries

- Miniflux alone has external DNS and TCP 80/443 egress, plus TCP 5432 to its
  CNPG database. Private-network feed fetching remains disabled.
- The importer can reach only Miniflux API and DNS.
- The MCP can reach only Miniflux API and DNS; inbound requests are limited to
  Hermes-agent and node-local probes/port-forwarding.
