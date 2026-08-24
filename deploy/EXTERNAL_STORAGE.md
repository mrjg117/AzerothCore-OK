# 外置储存部署（整镜像打包 / 免 ghcr 拉取）

> 配套改造：`build-core.yml` / `build-maps.yml`（构建完传外置）、`acok.sh`（外置源菜单 + 整包下载载入）、`keepalive.yml`（B6）。

## 一、它解决什么

原流程所有镜像走 `ghcr.io` 拉取，国内慢且不稳。本方案把**编译产物以整镜像包**形态上传到你的外置储存（OneDrive E5 / 任意 S3 兼容），部署端下载 → `docker load` → `compose up`，**部署时不碰 ghcr**。

- 外置只保留**最新版**（`ac-bundle-latest.tar.zst` / `ac-maps-latest.tar.zst`），多版本仍由 ghcr 承担。
- 上传后端**叠加非互斥**：OneDrive 凭证配了就传 OneDrive、S3 配了就传 S3、都配就双写；都没配则只留 ghcr（外置是增量优化，不报错）。

## 二、CI 侧：配置仓库 Secrets

在 GitHub 仓库 `Settings → Secrets and variables → Actions → Repository secrets` 添加。任一后端不配置即跳过。

### OneDrive（E5 账号 + 自建应用 + 证书鉴权，app-only 非交互）

| Secret | 说明 |
|---|---|
| `ONEDRIVE_CLIENT_ID` | Azure AD 企业应用的(客户端) ID |
| `ONEDRIVE_TENANT` | 租户 ID（如 `zh33.onmicrosoft.com` 或 GUID） |
| `ONEDRIVE_CERT` | **证书 PEM**（含 `-----BEGIN CERTIFICATE-----` 整段，含换行） |
| `ONEDRIVE_KEY` | **私钥 PEM**（含 `-----BEGIN PRIVATE KEY-----` 整段） |
| `ONEDRIVE_DRIVE_ID` | 目标 OneDrive 的 drive ID（Graph `/users/{upn}/drive` 获取） |

应用权限需 `Files.ReadWrite.All`（Application 类型）。本方案**不使用 client secret**：
rclone 的 onedrive 后端不支持证书直连，因此由 `.github/scripts/onedrive_token.py` 用 msal
以**证书签名 client_assertion** 换 Graph app-only 令牌，再把令牌喂给 rclone 的 `token`+`drive_id` 配置上传。

### S3（通用：AWS / Cloudflare R2 / B2-S3 / MinIO 等，仅 endpoint 不同）

| Secret | 说明 |
|---|---|
| `S3_BUCKET` | 桶名 |
| `S3_ACCESS_KEY` | 访问密钥 ID |
| `S3_SECRET_KEY` | 私密密钥 |
| `S3_ENDPOINT` | 可选，非 AWS 时填（如 R2 `https://<acctid>.r2.cloudflarestorage.com`） |
| `S3_REGION` | 可选，如 `auto` |

所有 S3 兼容服务共用同一套 AK/SK/签名协议，仅 `S3_ENDPOINT` 不同；上传走 rclone `s3` remote 或 `aws s3 cp`。

## 三、外置储存上的文件布局

```
<BASE>/
  ac-bundle-latest.tar.zst          # 整镜像：worldserver/authserver/db-import/tools/mysql
  ac-bundle-latest.tar.zst.sha256
  ac-maps-latest.tar.zst            # 地图镜像 ac-maps
  ac-maps-latest.tar.zst.sha256
```

`<BASE>` 即 OneDrive index 软件挂出的根目录 URL（或 S3 桶前缀 URL）。例如你把包放进 OneDrive 的 `acok/` 文件夹并用 index 软件挂出，则 `EXT_STORAGE_BASE=https://disk.example.org/acok`。

## 四、部署侧：启用外置

运行 `acok.sh` → `1) 网络设置` → `2) 配置外置存储源` → 输入基础目录 URL。
脚本写入 `.env` 的 `DEPLOY_SRC=external` / `EXT_STORAGE_BASE=...`。之后安装/重部署会：

1. 仍从 Worker 拉取**小型配置文件**（`docker-compose.yml` / `.env` / `env.ac`）；
2. 用 **aria2c**（外置模式下若未装则自动安装）多线程下载两个 `*.tar.zst`；
3. `sha256sum -c` 校验 → `zstd -d | docker load` → 按 `IMAGE_NS` 重打标签；
4. `docker compose up -d` 直接起（镜像已在本地，不再 `docker pull`）。

## 五、回退

`1) 网络设置 → 外置存储源 → 1) 切换为 ghcr 直连` 即切回原流程。
