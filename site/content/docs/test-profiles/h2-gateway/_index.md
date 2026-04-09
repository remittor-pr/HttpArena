---
weight: 3
title: H/2 Gateway
---

H/2 Gateway test profiles benchmark complete application stacks — not just a single server, but a full deployment with a reverse proxy, application server, and potentially additional services like caches or connection poolers. The load generator sends TLS-encrypted HTTP/2 requests to the entry point (typically a reverse proxy), which handles TLS termination and forwards requests to backend services.

Each entry defines its entire stack via **Docker Compose**, giving full control over architecture, service count, internal protocols, and CPU allocation. This mirrors how production applications are actually deployed — behind Nginx, Caddy, Envoy, or similar reverse proxies — and measures the end-to-end throughput of the whole system.

Entries without a proxy are also welcome: a single server handling TLS directly competes on the same 64-CPU budget.

{{< cards >}}
  {{< card link="gateway-64" title="Gateway-64" subtitle="Docker Compose-orchestrated stack with 64 CPUs — mixed workload of static files, JSON, async database, and baseline over HTTP/2 with TLS." icon="server" >}}
{{< /cards >}}
