# Triển khai OctoGallery lên Azure Container Apps

Thư mục này chứa mọi thứ cần để chạy ứng dụng của ghas-bootcamp trên Azure Container Apps (ACA). Source code (`frontend/`, `authn-service/`, `gallery-service/`, `storage-service/`) được giữ nguyên để phục vụ các lab GHAS. Những chỗ hardcode cho môi trường local được xử lý trong lúc build image hoặc lúc container khởi động, chỉ tác động lên bản copy bên trong image.

## Kiến trúc

```
Internet ──HTTPS──> <prefix>-frontend   (ingress external, nginx :8080)
                      ├─ /              -> SPA Vue (static)
                      ├─ /api/authn/*   -> http://<prefix>-authn-service   (ingress internal, :5000)
                      └─ /api/gallery/* -> http://<prefix>-gallery-service (ingress internal, :8081, SQLite)
                    <prefix>-storage-service (tuỳ chọn, ingress internal, :8082, cần AWS S3)

Dùng chung: Log Analytics, Azure Container Registry (Basic), user-assigned identity (AcrPull),
Container Apps environment (Consumption).
```

Chỉ frontend được public. Browser gọi API cùng origin qua nginx nên không phát sinh CORS, và backend không lộ ra Internet.

## Cấu trúc

| File | Vai trò |
|---|---|
| `deploy.sh` | Script triển khai: hạ tầng → build image trên ACR → container apps |
| `deploy.env.example` | Mẫu cấu hình, copy thành `deploy.env` (đã gitignore) |
| `infra/main.bicep` | Toàn bộ hạ tầng Azure |
| `*/Dockerfile` | Dockerfile từng service, build context là thư mục gốc repo |
| `../../.dockerignore` | Loại `.git`, `**/.env`, `node_modules`, `target`... khỏi build context |

## Xử lý hardcode mà không sửa source

| Service | Hardcode trong source | Cách xử lý |
|---|---|---|
| frontend | `http://localhost:5000`, `http://localhost:8081` (`src/main.js`) | Thay bằng `/api/authn`, `/api/gallery` khi build image |
| frontend | `client_id=aad2f5434c1efdb25ce6` (`src/components/Login.vue`) | Thay bằng placeholder khi build, điền từ `GITHUB_CLIENT_ID` lúc container start |
| frontend | Lỗi ESLint cố ý (`someUnusedProperty`) làm `npm run build` fail | Build qua `frontend/build.js` (bỏ plugin eslint) |
| authn-service | `redirect_uri = http://localhost:8080/login/callback` | `entrypoint.sh` thay bằng `OAUTH_REDIRECT_URI` lúc start |
| authn-service | `requirements.txt` chứa gói cũ không build được (PyGObject, pycrypto...) | Image dùng `requirements.runtime.txt`: chỉ các gói thực sự import, giữ nguyên phiên bản |
| gallery-service | `config.json` bind `localhost` | `entrypoint.sh` sinh config riêng từ biến môi trường (bind `0.0.0.0`) |

Build image sẽ fail nếu không tìm thấy chuỗi cần thay. Nếu lab làm thay đổi các đoạn code này, hãy cập nhật Dockerfile tương ứng.

## Yêu cầu

- Azure CLI ≥ 2.60 và đã `az login`
- Quyền Owner hoặc Contributor + User Access Administrator trên resource group (script gán role AcrPull)
- `python3`, `git`
- Không cần Docker local: image được build bằng `az acr build`

## Các bước triển khai

1. Tạo file cấu hình:

   ```bash
   cp deploy/azure/deploy.env.example deploy/azure/deploy.env
   # sửa AZ_RESOURCE_GROUP, AZ_LOCATION, PREFIX, FRONTEND_ALLOWED_CIDRS...
   ```

2. Tạo hạ tầng để biết trước URL của frontend:

   ```bash
   ./deploy/azure/deploy.sh infra
   ```

   Script in ra `Frontend URL` và `Callback URL`, dạng `https://<prefix>-frontend.<env-domain>/login/callback`.

3. Tạo GitHub OAuth App (GitHub → Settings → Developer settings → OAuth Apps → New OAuth App):
   - Homepage URL: `Frontend URL` ở bước 2
   - Authorization callback URL: `Callback URL` ở bước 2
   - Tạo client secret, điền `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` vào `deploy.env`

4. Build image và tạo container apps:

   ```bash
   ./deploy/azure/deploy.sh
   ```

5. Mở `Frontend URL` và chọn "Login with GitHub".

Cập nhật code (ví dụ sau khi sửa lỗi trong một lab): chạy lại `./deploy/azure/deploy.sh`. Mỗi lần chạy build image với tag mới (`<git-sha>-<timestamp>`) và tạo revision mới.

Dọn dẹp: `./deploy/azure/deploy.sh destroy` xoá toàn bộ resource group.

## Biến cấu hình (`deploy.env`)

| Biến | Mặc định | Ghi chú |
|---|---|---|
| `AZ_SUBSCRIPTION` | subscription hiện tại | |
| `AZ_RESOURCE_GROUP` | `rg-ghas-bootcamp` | |
| `AZ_LOCATION` | `southeastasia` | |
| `PREFIX` | `ghas` | Tiền tố tên resource, 2–12 ký tự |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | | Bắt buộc khi deploy app |
| `FRONTEND_ALLOWED_CIDRS` | rỗng (mở toàn bộ) | Danh sách CIDR được truy cập frontend, phân cách bằng dấu phẩy |
| `ALWAYS_ON` | `false` | `true` giữ 1 replica frontend/authn để tránh cold start |
| `IMAGE_TAG` / `SKIP_BUILD` | tự sinh / `false` | Dùng lại image có sẵn: `SKIP_BUILD=true IMAGE_TAG=<tag>` |
| `JWT_SECRET` | lấy từ `gallery-service/config.json` | Phải trùng secret hardcode trong `authn-service.py` |
| `DEPLOY_STORAGE_SERVICE` + `AWS_*` | `false` | storage-service cần bucket S3 thật |

Các giá trị secret được truyền qua file parameters tạm (quyền 600, tự xoá) và lưu thành secret của Container App, không nằm trên command line.

## Lưu ý

- Bảo mật: ứng dụng này cố ý chứa lỗ hổng cho lab GHAS (SQL injection ở `Gallery.Update`, JWT secret hardcode, không kiểm tra thuật toán JWT, secret trong repo...). Khi triển khai public, bất kỳ ai cũng có thể khai thác. Nên đặt `FRONTEND_ALLOWED_CIDRS`, dùng subscription/resource group riêng cho lab và `destroy` sau khi dùng xong.
- Dữ liệu gallery nằm trong SQLite trên filesystem của replica (gallery-service cố định 1 replica). Dữ liệu mất khi có revision mới hoặc replica restart. Mount Azure Files cho SQLite không được khuyến nghị (SMB không hỗ trợ tốt file locking).
- Cold start: với `ALWAYS_ON=false`, frontend và authn scale về 0 khi không có traffic. Request đầu tiên có thể chậm vài giây.
- Khi GitHub trả lỗi không có `error_description` (ví dụ client ID sai), authn-service trả HTTP 500 (`KeyError`). Đây là hành vi có sẵn của source; xem log bằng:

  ```bash
  az containerapp logs show -g <rg> -n <prefix>-authn-service --follow
  ```

- Lần deploy đầu, role AcrPull có thể chưa kịp có hiệu lực. Script tự thử lại sau 60 giây; nếu vẫn lỗi, chạy lại `./deploy/azure/deploy.sh`.

## Chạy thử bằng Docker local

```bash
docker build -f deploy/azure/authn-service/Dockerfile   -t ghas/authn .
docker build -f deploy/azure/gallery-service/Dockerfile -t ghas/gallery .
docker build -f deploy/azure/frontend/Dockerfile        -t ghas/frontend .

docker network create ghas
docker run -d --name authn-service   --network ghas -e CLIENT_ID=... -e CLIENT_SECRET=... \
  -e OAUTH_REDIRECT_URI=http://localhost:8080/login/callback ghas/authn
docker run -d --name gallery-service --network ghas \
  -e JWT_SECRET="$(python3 -c 'import json;print(json.load(open("gallery-service/config.json"))["secret"])')" ghas/gallery
# Local không có ingress của ACA (port 80 -> target port) nên chỉ định port upstream
docker run -d --name frontend --network ghas -p 8080:8080 -e GITHUB_CLIENT_ID=... \
  -e AUTHN_UPSTREAM=http://authn-service:5000 -e GALLERY_UPSTREAM=http://gallery-service:8081 ghas/frontend
```
