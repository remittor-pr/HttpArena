FROM rust:1.88 AS build
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src/ target/release/httparena-ntex-tokio* target/release/deps/httparena_ntex_tokio*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-ntex-tokio /server
EXPOSE 8080
CMD ["/server"]
