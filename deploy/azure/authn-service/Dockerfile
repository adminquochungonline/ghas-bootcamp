# Build context: thư mục gốc repo
#   docker build -f deploy/azure/authn-service/Dockerfile -t authn-service .
FROM python:3.10-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=5000

RUN useradd --create-home --uid 10001 app
WORKDIR /app

COPY deploy/azure/authn-service/requirements.runtime.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Source được copy nguyên vẹn (đổi tên file để gunicorn import được: "app:app")
COPY authn-service/authn-service.py /app/app.py
COPY deploy/azure/authn-service/entrypoint.sh /usr/local/bin/entrypoint.sh
# entrypoint cần ghi vào /app (sed -i) để chỉnh redirect_uri lúc khởi động
RUN chmod 0755 /usr/local/bin/entrypoint.sh && chown -R app:app /app

USER app
EXPOSE 5000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
