#!/bin/sh
# Biến môi trường:
#   CLIENT_ID, CLIENT_SECRET  - GitHub OAuth App (đọc bởi authn-service qua os.getenv)
#   OAUTH_REDIRECT_URI        - callback URL public của frontend, vd https://frontend.<domain>/login/callback
#   PORT                      - mặc định 5000
set -eu

# Source hardcode redirect_uri = http://localhost:8080/login/callback khi đổi code lấy token.
# GitHub từ chối nếu không khớp callback URL đã đăng ký, nên thay giá trị này trong bản copy
# bên trong container (file trong repo không bị đụng tới).
DEFAULT_REDIRECT="http://localhost:8080/login/callback"
if [ -n "${OAUTH_REDIRECT_URI:-}" ] && [ "$OAUTH_REDIRECT_URI" != "$DEFAULT_REDIRECT" ]; then
  if grep -q "$DEFAULT_REDIRECT" /app/app.py; then
    sed -i "s|$DEFAULT_REDIRECT|$OAUTH_REDIRECT_URI|" /app/app.py
    echo "authn-service: redirect_uri -> $OAUTH_REDIRECT_URI"
  elif ! grep -q "$OAUTH_REDIRECT_URI" /app/app.py; then
    echo "authn-service: WARNING không tìm thấy redirect_uri mặc định trong app.py" >&2
  fi
fi

if [ -z "${CLIENT_ID:-}" ] || [ -z "${CLIENT_SECRET:-}" ]; then
  echo "authn-service: WARNING CLIENT_ID/CLIENT_SECRET chưa được cấu hình" >&2
fi

exec gunicorn --bind "0.0.0.0:${PORT:-5000}" --workers 2 --access-logfile - app:app
