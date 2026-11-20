# Build from the repository root:  docker build -f server/Dockerfile -t hanashi-server .
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hanashi-server ./cmd/hanashi-server

FROM alpine:3.22
RUN adduser -D -H -u 10001 hanashi && mkdir /data && chown hanashi /data
COPY --from=build /hanashi-server /usr/local/bin/
USER hanashi
ENV HANASHI_DATA_DIR=/data HANASHI_PORT=8080
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["hanashi-server"]
