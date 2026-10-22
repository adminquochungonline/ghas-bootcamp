#!/usr/bin/env bash
# Triển khai OctoGallery (ghas-bootcamp) lên Azure Container Apps.
#
#   cp deploy/azure/deploy.env.example deploy/azure/deploy.env   # điền giá trị
#   ./deploy/azure/deploy.sh            # hạ tầng + build image (ACR Tasks) + container apps
#   ./deploy/azure/deploy.sh infra      # chỉ tạo hạ tầng, in ra callback URL cho GitHub OAuth App
#   ./deploy/azure/deploy.sh destroy    # xoá resource group
#
# Yêu cầu: Azure CLI (đã az login), quyền Owner/User Access Administrator trên resource group
# (để gán role AcrPull). Không cần Docker local: image được build trên ACR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACTION="${1:-all}"

if [[ -f "$SCRIPT_DIR/deploy.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/deploy.env"
fi

: "${AZ_RESOURCE_GROUP:=rg-ghas-bootcamp}"
: "${AZ_LOCATION:=southeastasia}"
: "${PREFIX:=ghas}"
: "${ALWAYS_ON:=false}"
: "${DEPLOY_STORAGE_SERVICE:=false}"
: "${IMAGE_TAG:=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo manual)-$(date +%Y%m%d%H%M%S)}"
: "${SKIP_BUILD:=false}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "Cần Azure CLI (https://aka.ms/azure-cli)"
az account show >/dev/null 2>&1 || die "Chưa đăng nhập Azure: chạy 'az login'"
[[ -n "${AZ_SUBSCRIPTION:-}" ]] && az account set --subscription "$AZ_SUBSCRIPTION"

# Secret JWT: authn-service hardcode secret trong source (lỗ hổng cố ý của lab), gallery-service
# phải dùng đúng secret đó. Mặc định lấy từ gallery-service/config.json để không nhân bản giá trị.
if [[ -z "${JWT_SECRET:-}" ]]; then
  JWT_SECRET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["secret"])' \
    "$REPO_ROOT/gallery-service/config.json")"
fi

PARAMS_FILE="$(mktemp)"
chmod 600 "$PARAMS_FILE"
trap 'rm -f "$PARAMS_FILE"' EXIT

# Ghi file parameters (tránh để secret xuất hiện trên command line)
write_params() {
  local deploy_apps="$1"
  DEPLOY_APPS="$deploy_apps" python3 - "$PARAMS_FILE" <<'PY'
import json, os, sys
e = os.environ.get
p = {
    "prefix": e("PREFIX"),
    "location": e("AZ_LOCATION"),
    "deployApps": e("DEPLOY_APPS") == "true",
    "imageTag": e("IMAGE_TAG"),
    "githubClientId": e("GITHUB_CLIENT_ID", ""),
    "githubClientSecret": e("GITHUB_CLIENT_SECRET", ""),
    "jwtSecret": e("JWT_SECRET", ""),
    "alwaysOn": e("ALWAYS_ON") == "true",
    "deployStorageService": e("DEPLOY_STORAGE_SERVICE") == "true",
    "awsS3Bucket": e("AWS_S3_BUCKET", ""),
    "awsRegion": e("AWS_REGION", "us-east-1"),
    "awsAccessKeyId": e("AWS_ACCESS_KEY_ID", ""),
    "awsSecretAccessKey": e("AWS_SECRET_ACCESS_KEY", ""),
    "frontendAllowedCidrs": [c.strip() for c in e("FRONTEND_ALLOWED_CIDRS", "").split(",") if c.strip()],
}
doc = {
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {k: {"value": v} for k, v in p.items()},
}
with open(sys.argv[1], "w") as f:
    json.dump(doc, f)
PY
}

export PREFIX AZ_LOCATION IMAGE_TAG JWT_SECRET ALWAYS_ON DEPLOY_STORAGE_SERVICE
export GITHUB_CLIENT_ID="${GITHUB_CLIENT_ID:-}" GITHUB_CLIENT_SECRET="${GITHUB_CLIENT_SECRET:-}"
export AWS_S3_BUCKET="${AWS_S3_BUCKET:-}" AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export FRONTEND_ALLOWED_CIDRS="${FRONTEND_ALLOWED_CIDRS:-}"

deploy_bicep() {
  local deploy_apps="$1" name
  name="aca-${PREFIX}-$(date +%Y%m%d%H%M%S)"
  write_params "$deploy_apps"
  az deployment group create \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --name "$name" \
    --template-file "$SCRIPT_DIR/infra/main.bicep" \
    --parameters "@$PARAMS_FILE" \
    --query properties.outputs -o json
}

output() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]]["value"])' "$1"; }

case "$ACTION" in
  destroy)
    log "Xoá resource group $AZ_RESOURCE_GROUP"
    az group delete --name "$AZ_RESOURCE_GROUP" --yes --no-wait
    echo "Đã gửi yêu cầu xoá (chạy nền)."
    exit 0
    ;;
  all|infra) ;;
  *) die "Action không hợp lệ: $ACTION (all | infra | destroy)" ;;
esac

if [[ "$ACTION" == "all" ]]; then
  [[ -n "$GITHUB_CLIENT_ID" && -n "$GITHUB_CLIENT_SECRET" ]] \
    || die "Cần GITHUB_CLIENT_ID và GITHUB_CLIENT_SECRET (xem README). Chạy './deploy.sh infra' trước để lấy callback URL."
  if [[ "$DEPLOY_STORAGE_SERVICE" == "true" ]]; then
    [[ -n "$AWS_S3_BUCKET" && -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] \
      || die "DEPLOY_STORAGE_SERVICE=true cần AWS_S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
  fi
fi

log "Resource group $AZ_RESOURCE_GROUP ($AZ_LOCATION)"
az group create --name "$AZ_RESOURCE_GROUP" --location "$AZ_LOCATION" --tags project=ghas-bootcamp -o none

log "Pha 1: hạ tầng (Log Analytics, ACR, identity, Container Apps environment)"
OUTPUTS="$(deploy_bicep false)"
ACR_NAME="$(output acrName <<<"$OUTPUTS")"
CALLBACK_URL="$(output oauthCallbackUrl <<<"$OUTPUTS")"
FRONTEND_URL="$(output frontendUrl <<<"$OUTPUTS")"
echo "ACR:          $ACR_NAME"
echo "Frontend URL: $FRONTEND_URL"
echo "Callback URL: $CALLBACK_URL"

if [[ "$ACTION" == "infra" ]]; then
  cat <<EOF

Tiếp theo: tạo GitHub OAuth App với
  Homepage URL:               $FRONTEND_URL
  Authorization callback URL: $CALLBACK_URL
rồi điền GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET vào deploy.env và chạy lại './deploy.sh'.
EOF
  exit 0
fi

SERVICES=(authn-service gallery-service frontend)
[[ "$DEPLOY_STORAGE_SERVICE" == "true" ]] && SERVICES+=(storage-service)

if [[ "$SKIP_BUILD" != "true" ]]; then
  for svc in "${SERVICES[@]}"; do
    log "Build image $svc:$IMAGE_TAG trên ACR $ACR_NAME"
    az acr build \
      --registry "$ACR_NAME" \
      --image "$svc:$IMAGE_TAG" \
      --file "$REPO_ROOT/deploy/azure/$svc/Dockerfile" \
      "$REPO_ROOT"
  done
else
  log "Bỏ qua build (SKIP_BUILD=true), dùng tag $IMAGE_TAG"
fi

log "Pha 2: container apps (tag $IMAGE_TAG)"
# Role AcrPull mới gán có thể mất vài phút để có hiệu lực -> thử lại một lần.
if ! OUTPUTS="$(deploy_bicep true)"; then
  echo "Triển khai lỗi, có thể do role AcrPull chưa kịp có hiệu lực. Thử lại sau 60s..." >&2
  sleep 60
  OUTPUTS="$(deploy_bicep true)"
fi

cat <<EOF

Hoàn tất.
  Ứng dụng:      $FRONTEND_URL
  Image tag:     $IMAGE_TAG

Kiểm tra GitHub OAuth App (client id $GITHUB_CLIENT_ID) có:
  Homepage URL:               $FRONTEND_URL
  Authorization callback URL: $CALLBACK_URL
EOF
