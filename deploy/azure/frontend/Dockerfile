# Build context: thư mục gốc repo
#   docker build -f deploy/azure/frontend/Dockerfile -t frontend .
#
# Source frontend hardcode http://localhost:5000 (authn), http://localhost:8081 (gallery) và
# client_id của GitHub OAuth App. Thay vì sửa source, bản copy trong stage build được thay:
#   http://localhost:5000      -> /api/authn    (nginx reverse proxy tới authn-service)
#   http://localhost:8081      -> /api/gallery  (nginx reverse proxy tới gallery-service)
#   client_id=aad2f5434c1efdb25ce6 -> placeholder, điền từ $GITHUB_CLIENT_ID lúc container khởi động
# Build sẽ fail nếu không tìm thấy chuỗi cần thay (để phát hiện khi source thay đổi).
# Build qua deploy/azure/frontend/build.js (bỏ eslint + thoát tường minh), xem chú thích trong file.

FROM node:26-bullseye-slim AS build
WORKDIR /src
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
COPY deploy/azure/frontend/build.js /src/.aca-build.js
RUN set -eu; \
    patch() { file="$1"; from="$2"; to="$3"; \
      grep -qF "$from" "$file" || { echo "Không tìm thấy '$from' trong $file" >&2; exit 1; }; \
      sed -i "s|$from|$to|g" "$file"; }; \
    patch src/main.js 'http://localhost:5000' '/api/authn'; \
    patch src/main.js 'http://localhost:8081' '/api/gallery'; \
    patch src/components/Login.vue 'client_id=aad2f5434c1efdb25ce6' 'client_id=__GITHUB_CLIENT_ID__'; \
    node .aca-build.js

FROM nginxinc/nginx-unprivileged:1.27-alpine
ENV AUTHN_UPSTREAM=http://authn-service \
    GALLERY_UPSTREAM=http://gallery-service \
    NGINX_ENVSUBST_FILTER=UPSTREAM
USER root
RUN rm -f /etc/nginx/conf.d/default.conf
COPY deploy/azure/frontend/default.conf.template /etc/nginx/templates/default.conf.template
COPY deploy/azure/frontend/40-github-client-id.sh /docker-entrypoint.d/40-github-client-id.sh
COPY --from=build /src/dist /usr/share/nginx/html
RUN chmod 0755 /docker-entrypoint.d/40-github-client-id.sh \
 && chown -R nginx:nginx /usr/share/nginx/html /etc/nginx/conf.d
USER nginx
EXPOSE 8080
