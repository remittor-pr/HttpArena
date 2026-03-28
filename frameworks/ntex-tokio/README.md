# ntex (neon-uring)

[ntex](https://github.com/ntex-rs/ntex) is a framework for composable networking services in Rust, created by the same author as actix-web. This entry uses the **neon-uring** runtime, which leverages Linux's io_uring for async I/O.

## Runtime

- **Async runtime:** neon with io_uring backend
- **HTTP:** ntex built-in HTTP/1.1 server
- **Compression:** ntex Compress middleware (gzip)
- **Optimization:** `-O3`, thin LTO, `target-cpu=native`

## Build

```bash
docker build -t httparena-ntex .
docker run --network host -v /data:/data httparena-ntex
```
