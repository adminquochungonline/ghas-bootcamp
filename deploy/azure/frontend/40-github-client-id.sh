#!/bin/sh
# Chạy bởi /docker-entrypoint.sh của image nginx trước khi nginx start.
# Điền client_id GitHub OAuth App vào bundle JS đã build.
set -eu

PLACEHOLDER="__GITHUB_CLIENT_ID__"
HTML_DIR=/usr/share/nginx/html

if [ -z "${GITHUB_CLIENT_ID:-}" ]; then
  echo "$0: WARNING GITHUB_CLIENT_ID chưa được cấu hình, nút 'Login with GitHub' sẽ không hoạt động" >&2
  exit 0
fi

case "$GITHUB_CLIENT_ID" in
  *[!A-Za-z0-9._-]*)
    echo "$0: GITHUB_CLIENT_ID chứa ký tự không hợp lệ" >&2
    exit 1
    ;;
esac

files=$(grep -rlF "$PLACEHOLDER" "$HTML_DIR" || true)
for f in $files; do
  sed -i "s|$PLACEHOLDER|$GITHUB_CLIENT_ID|g" "$f"
  echo "$0: đã điền GITHUB_CLIENT_ID vào $f"
done
