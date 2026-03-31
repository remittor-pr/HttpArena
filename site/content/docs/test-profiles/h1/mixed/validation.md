---
title: Validation
---

The mixed workload profile does not have its own dedicated validation checks. Instead, each endpoint used in the mixed test is validated through its respective test profile:

- `/baseline11` — validated by the [Baseline](../../baseline/validation) checks
- `/json` — validated by the [JSON Processing](../../json-processing/validation) checks
- `/db` — validated by the [Database Query](../../database/validation) checks
- `/upload` — validated by the [Upload](../../upload/validation) checks
- `/compression` — validated by the [Compression](../../compression/validation) checks

A framework subscribed to the `mixed` test must also implement all five endpoints. The database endpoint (`/db`) validation is triggered specifically when the `mixed` test is in the framework's test list.
