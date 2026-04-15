---
weight: 3
title: H/2 Gateway
---

The H/2 Gateway test benchmarks a two-service production stack: a reverse proxy terminating TLS and serving static files, plus an application server handling dynamic endpoints. The load generator sends TLS-encrypted HTTP/2 requests to port 8443, which must be handled by the proxy.

Each entry defines the stack via **Docker Compose** with exactly two services — `proxy` and `server` — and is free to split the 64-CPU budget between them however it wants. This mirrors how real applications deploy behind Nginx, Caddy, Envoy, or HAProxy and measures the end-to-end throughput of the pair as a unit.

{{< cards >}}
  {{< card link="gateway-64" title="Gateway-64" subtitle="Proxy + server combination with 64 CPUs split freely — mixed workload of static files (served by proxy) and dynamic endpoints (served by server) over HTTP/2 with TLS." icon="server" >}}
{{< /cards >}}
