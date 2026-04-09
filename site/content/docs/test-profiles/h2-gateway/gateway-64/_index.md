---
title: Gateway-64
---

Benchmarks an HTTP/2 application stack behind a reverse proxy — mirroring how production applications are typically deployed. The load generator sends TLS-encrypted HTTP/2 requests to the proxy, which forwards them to the application server. The test measures the combined throughput of the entire stack working together.

Unlike other HttpArena tests that benchmark a single container, the Gateway test uses **Docker Compose** to orchestrate multi-container deployments. Each entry provides a `compose.gateway.yml` that defines the full stack — proxy, application server, and any additional services (caches, sidecars, etc.). This means entries have full control over their architecture: they choose the proxy software, the internal protocol between services, and how to split the 64 available CPUs.

Entries may also skip the proxy entirely and let the application server handle TLS termination directly, competing on equal footing with the same total CPU budget.

The workload mixes four endpoint types — static files, JSON processing, async database queries, and baseline request handling — representing a realistic application that serves both static assets and dynamic API responses.

{{< cards >}}
  {{< card link="implementation" title="Implementation Guidelines" subtitle="Docker Compose setup, CPU allocation rules, proxy configuration, and type-specific rules." icon="code" >}}
  {{< card link="validation" title="Validation" subtitle="All checks executed by the validation script for this test profile." icon="check-circle" >}}
{{< /cards >}}
