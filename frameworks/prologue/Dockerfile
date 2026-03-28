FROM nimlang/nim:2.0.14-alpine AS build
RUN apk add --no-cache sqlite-dev postgresql-dev
WORKDIR /app
COPY src/ ./
RUN nimble install -y prologue zippy db_connector
RUN nim c -d:release -d:danger -d:usestd --opt:speed --threads:on --passL:"-lsqlite3 -lpq" -o:server server.nim

FROM alpine:3.19
RUN apk add --no-cache libgcc sqlite-libs libpq
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
