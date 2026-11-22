# Build from the repository root:  docker build -f server/Dockerfile -t hanashi-server .
#
# Other CPU types are cross-compiled on the build machine's own, so building
# for several needs no emulation:
#   docker buildx build --platform linux/amd64,linux/arm64 -f server/Dockerfile .
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /hanashi-server ./cmd/hanashi-server
# The data folder, made here: nothing runs in the stage below, which may be of
# another CPU type.
RUN mkdir -p /rootfs/data

FROM alpine:3.24
ARG VERSION=dev
LABEL org.opencontainers.image.title="Hanashi server" \
      org.opencontainers.image.description="Server of Hanashi, a self-hosted, end-to-end encrypted chat app" \
      org.opencontainers.image.source="https://github.com/N1kO23/Hanashi" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.version=$VERSION
COPY --from=build /hanashi-server /usr/local/bin/
COPY --from=build --chown=10001:10001 /rootfs/ /
# A user of its own (by number: the server looks up no names), owning /data.
USER 10001:10001
ENV HANASHI_DATA_DIR=/data HANASHI_PORT=8080
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["hanashi-server"]
