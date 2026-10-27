# Build context: thư mục gốc repo
#   docker build -f deploy/azure/gallery-service/Dockerfile -t gallery-service .
FROM golang:1.27-bookworm AS build
WORKDIR /src
COPY gallery-service/go.mod gallery-service/go.sum ./
RUN go mod download
COPY gallery-service/ ./
# go-sqlite3 cần CGO
RUN CGO_ENABLED=1 go build -o /out/gallery-service .

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 app \
 && mkdir -p /data /app \
 && chown app:app /data /app

COPY --from=build /out/gallery-service /app/gallery-service
COPY deploy/azure/gallery-service/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER app
WORKDIR /app
EXPOSE 8081
VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
