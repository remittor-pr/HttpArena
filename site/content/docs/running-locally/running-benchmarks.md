---
title: Running Benchmarks
weight: 3
---

How to use the benchmark script and what it does under the hood.

## Usage

By default, running the benchmark script does **not** modify any result files — this prevents local runs from polluting PRs with unintended data changes.

Run all frameworks (dry-run, results displayed but not saved):

```bash
./scripts/benchmark.sh
```

Run a single framework:

```bash
./scripts/benchmark.sh aspnet-minimal
```

Run a single framework with a specific profile:

```bash
./scripts/benchmark.sh aspnet-minimal baseline
```

To persist results to `results/` and rebuild `site/data/`, add the `--save` flag:

```bash
./scripts/benchmark.sh --save
./scripts/benchmark.sh --save aspnet-minimal
./scripts/benchmark.sh --save aspnet-minimal baseline
```

Available profiles: `baseline`, `pipelined`, `limited-conn`, `json`, `upload`, `compression`, `noisy`, `baseline-h2`, `static-h2`, `baseline-h3`, `static-h3`.

## What happens

For each framework and profile combination, the script:

1. Builds the Docker image from `frameworks/<name>/Dockerfile`
2. Starts the container with `--network host`
3. Waits for the server to respond
4. Runs the load generator 3 times and keeps the best result
5. Displays the results

With `--save`, it additionally:

6. Saves results to `results/<profile>/<connections>/<framework>.json`
7. Saves Docker logs to `site/static/logs/<profile>/<connections>/<framework>.log`
8. Rebuilds site data files in `site/data/`

For HTTP/1.1 profiles (`baseline`, `pipelined`, `limited-conn`, `json`, `upload`, `compression`, `noisy`), the load generator is **gcannon**. For HTTP/2 profiles (`baseline-h2`, `static-h2`), the load generator is **h2load**. For HTTP/3 profiles (`baseline-h3`, `static-h3`), the load generator is **oha**.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `THREADS` | `64` | Number of threads for **gcannon** (HTTP/1.1 load generator) |
| `H2THREADS` | `128` | Number of threads for **h2load** (HTTP/2 load generator) |

Example — run with custom thread counts:

```bash
THREADS=8 H2THREADS=128 ./scripts/benchmark.sh aspnet-minimal
```
