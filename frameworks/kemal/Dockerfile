# Build stage
FROM crystallang/crystal:1.14-alpine AS builder

WORKDIR /app

# Install SQLite dev headers
RUN apk add --no-cache sqlite-dev sqlite-static

# Copy dependency file first for caching
COPY shard.yml shard.lock ./
RUN shards install --production

# Copy source and build
COPY src/ src/
RUN crystal build src/server.cr -o server --release --no-debug --static

# Runtime stage
FROM alpine:3.20

RUN apk add --no-cache ca-certificates

WORKDIR /app
COPY --from=builder /app/server /app/server

EXPOSE 8080

CMD ["/app/server"]
