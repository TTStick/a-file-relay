# syntax=docker/dockerfile:1
# Multi-arch build: docker buildx build --platform linux/amd64,linux/arm64 -t fileswitch .
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS build
ARG TARGETOS TARGETARCH
ARG GOPROXY=https://proxy.golang.org,direct
WORKDIR /src
COPY go.mod go.sum ./
RUN GOPROXY=$GOPROXY go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/fileswitch ./cmd/fileswitch

FROM alpine:3.22
RUN apk add --no-cache ca-certificates tzdata \
 && addgroup -S -g 1000 fileswitch && adduser -S -D -H -u 1000 -G fileswitch fileswitch \
 && mkdir -p /data && chown fileswitch:fileswitch /data
COPY --from=build /out/fileswitch /usr/local/bin/fileswitch
USER fileswitch
ENV FS_DATA_DIR=/data FS_LISTEN=:8443 TZ=Asia/Shanghai
VOLUME /data
EXPOSE 8443
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD ["fileswitch", "healthcheck"]
ENTRYPOINT ["fileswitch"]
CMD ["serve"]
