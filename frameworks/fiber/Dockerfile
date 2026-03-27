FROM golang:1.24-alpine AS build
WORKDIR /app
COPY go.mod go.sum ./
COPY vendor ./vendor
COPY main.go ./
RUN CGO_ENABLED=0 go build -mod=vendor -o server main.go

FROM alpine:3.19
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
