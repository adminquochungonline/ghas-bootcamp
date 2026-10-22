# (Tuỳ chọn) storage-service - frontend hiện không gọi service này. Cần AWS S3 thật để hoạt động.
# Build context: thư mục gốc repo
#   docker build -f deploy/azure/storage-service/Dockerfile -t storage-service .
FROM maven:3.8.1-openjdk-15 AS build
WORKDIR /src
COPY storage-service/pom.xml ./
RUN mvn -B -q dependency:go-offline
COPY storage-service/src ./src
RUN mvn -B -q -DskipTests package \
 && cp target/storage-service-*.jar /app.jar

FROM eclipse-temurin:17-jre
RUN useradd --create-home --uid 10001 app
COPY --from=build /app.jar /app/app.jar
USER app
EXPOSE 8082
# Cấu hình qua biến môi trường (Spring relaxed binding), ví dụ:
#   CLOUD_AWS_S3_BUCKET, CLOUD_AWS_REGION_STATIC, CLOUD_AWS_STACK_AUTO=false,
#   CLOUD_AWS_CREDENTIALS_ACCESSKEY, CLOUD_AWS_CREDENTIALS_SECRETKEY, JWT_SECRET
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
