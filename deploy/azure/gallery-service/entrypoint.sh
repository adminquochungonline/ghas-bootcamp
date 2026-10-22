#!/bin/sh
# gallery-service đọc cấu hình từ file JSON truyền qua argv. File gallery-service/config.json
# trong repo bind "localhost" nên không nhận traffic trong container; entrypoint này sinh
# config riêng từ biến môi trường.
#
# Biến môi trường:
#   JWT_SECRET        - (bắt buộc) phải trùng secret authn-service dùng để ký JWT
#   PORT              - mặc định 8081
#   DATABASE_PATH     - mặc định /data/galleries.db
#   ALLOWED_ORIGINS   - danh sách origin, phân cách bằng dấu phẩy (tuỳ chọn)
set -eu

if [ -z "${JWT_SECRET:-}" ]; then
  echo "gallery-service: JWT_SECRET chưa được cấu hình" >&2
  exit 1
fi

CONFIG_FILE=/app/config.json
jq -n \
  --arg host "0.0.0.0" \
  --argjson port "${PORT:-8081}" \
  --arg database "${DATABASE_PATH:-/data/galleries.db}" \
  --arg secret "$JWT_SECRET" \
  --arg origins "${ALLOWED_ORIGINS:-}" \
  '{host: $host, port: $port, database: $database, secret: $secret,
    "allowed-origins": ($origins | split(",") | map(select(length > 0)))}' \
  > "$CONFIG_FILE"

exec /app/gallery-service "$CONFIG_FILE"
