# 外置储存部署（整镜像打包 / 免 ghcr 拉取）

> 配套改造：`build-core.yml` / `build-maps.yml`（构建完传外置）、`acok.sh`（外置源菜单 + 整包下载载入）、`keepalive.yml`（B6）。

## 一、它解决什么

原流程所有镜像走 `ghcr.io` 拉取，国内慢且不稳。本方案把**编译产物以整镜像包**形态上传到你的外置储存（OneDrive E5 / 任意 S3 兼容），部署端下载 → `docker load` → `compose up`，**部署时不碰 ghcr**。

- 外置只保留**最新版**（`ac-bundle-latest.tar.zst` / `ac-maps-latest.tar.zst`），多版本仍由 ghcr 承担。
- 上传后端**叠加非互斥**：OneDrive 凭证配了就传 OneDrive、S3 配了就传 S3、都配就双写；都没配则只留 ghcr（外置是增量优化，不报错）。

## 二、CI 侧：配置仓库 Secrets

在 GitHub 仓库 `Settings → Secrets and variables → Actions → Repository secrets` 添加。任一后端不配置即跳过。

### OneDrive（E5 账号 + 自建应用 + 证书鉴权，app-only 非交互）

| Secret | 必填 | 说明 |
|---|---|---|
| `ONEDRIVE_CLIENT_ID` | 是 | Azure AD 企业应用的(客户端) ID |
| `ONEDRIVE_TENANT` | 是 | 租户 ID（如 `zh33.onmicrosoft.com` 或 GUID） |
| `ONEDRIVE_CERT` | 是 | **证书 PEM**（含 `-----BEGIN CERTIFICATE-----` 整段） |
| `ONEDRIVE_KEY` | 是 | **私钥 PEM**（含 `-----BEGIN PRIVATE KEY-----` 整段） |

> **PEM 格式容错**：`onedrive_token.py` 在交给 msal 前会**自动归一化**证书/私钥——无论你在 Secret 里粘贴的是标准多行、被压平的一行、还是带 `\r`，脚本都会重建为标准 `头行\n每64字符换行主体\n尾行` 的 PEM。即 Secret 粘贴压平一行也能用，无需手动 `fold` 重整。归一化不改变密钥内容，仅重排换行。若 Secret 根本不含 `-----BEGIN/END-----` 标签则仍会明确报错。
| `ONEDRIVE_USER_ID` | **必填** | 目标用户 UPN（如 `admin@zh33.onmicrosoft.com`）；Graph 直传经 `users/{UPN}/drive/...` 路径定位其盘，无需 drive_id |
| `ONEDRIVE_UPLOAD_PATH` | 否 | 包上传到该盘**内**的目标目录（默认 `acok`）；即你要挂载/存放构建包的文件夹 |

> **重要（2026-08-24 方案定稿）**：OneDrive 上传**改用 Microsoft Graph upload session 直传**（`.github/scripts/onedrive_upload.py`），不再依赖 rclone。原因：rclone onedrive 后端在 **app-only（证书）场景下官方明确不支持**（`onedrive` 类型不能用于 client_credentials，只能走 `sharepoint` 类型 + 显式 `drive_id`，配置繁琐）。Graph 直传原生支持 app-only，用 **UPN 路径**定位用户盘，**免 drive_id、免 rclone、免 user 配置项**。
> 目录：`UPLOAD_PATH` 决定包落在该盘的哪个子目录，对应部署端 `EXT_STORAGE_BASE` 指向的那个文件夹。

应用权限需 `Files.ReadWrite.All`（Application 类型）。本方案**不使用 client secret**：
由 `.github/scripts/onedrive_upload.py` 用 msal 以**证书签名 client_assertion** 换 Graph app-only 令牌，
再调用 Graph 的 `createUploadSession` + 分片 `PUT` 直传（单分片 60 MiB、顺序上传、支持断点续传）。
效率说明：单文件分片顺序上传（Graph 协议层不支持同 session 并发分片），但通过大分片(60MiB)+HTTP 持久连接即可跑满带宽；
每次同时传 `.tar.zst` 与 `.sha256` 两个文件，可各自开 session **并行**，整体不比 rclone 慢。

### S3（通用：AWS / Cloudflare R2 / B2-S3 / MinIO 等，仅 endpoint 不同）

| Secret | 说明 |
|---|---|
| `S3_BUCKET` | 桶名 |
| `S3_ACCESS_KEY` | 访问密钥 ID |
| `S3_SECRET_KEY` | 私密密钥 |
| `S3_ENDPOINT` | 可选，非 AWS 时填（如 R2 `https://<acctid>.r2.cloudflarestorage.com`） |
| `S3_REGION` | 可选，如 `auto` |

所有 S3 兼容服务共用同一套 AK/SK/签名协议，仅 `S3_ENDPOINT` 不同；上传走 rclone `s3` remote 或 `aws s3 cp`。

## 二之一、脚本调用方式（权限说明）

CI 用  **显式调用**上传脚本，不依赖文件的可执行位（）。

> 原因：仓库先前在 Windows 上提交时 git 未记录可执行位，checkout 到 Linux runner 后脚本为 ，
> 直接执行会报 （exit 126）。用  前缀可彻底规避，无需手动 。
> 本地手测若直接执行，记得先 。

### 二之一·甲、CI checkout 路径约定（避坑）

`build-core.yml` / `build-maps.yml` 的 `Checkout this repo` 步骤把本仓库 checkout 到
**`acore-build-repo/` 子目录**（即 `${{ github.workspace }}/acore-build-repo`），而非仓库根。
因此上传步骤（cwd 为 `${{ github.workspace }}`）调用上传脚本时**必须用绝对路径**：

```yaml
# 正确：基于 github.workspace 的绝对路径，与 build-patches 步骤写法一致
bash "${{ github.workspace }}/acore-build-repo/.github/scripts/upload_artifacts.sh" "ac-bundle-latest.tar.zst"
bash "${{ github.workspace }}/acore-build-repo/.github/scripts/upload_artifacts.sh" "ac-bundle-latest.tar.zst.sha256"
```

> 反例（会 exit 127）：`bash .github/scripts/upload_artifacts.sh ...`
> —— 相对路径在仓库根找不到文件（实际在 `acore-build-repo/.github/scripts/` 下）。
> 脚本内部用 `$(dirname "$0")` 定位 `onedrive_upload.py`，因此用绝对路径调用时
> Python 脚本的相对引用也自动正确，无需额外处理。

## 二之二、CI 依赖安装（rclone 仅 S3 需要）

OneDrive 走 Graph 直传（`.github/scripts/onedrive_upload.py`），**仅需 `msal`、无需 rclone**。
`rclone` 只服务于 **S3 后端**，且 GitHub 官方 `ubuntu-latest` runner 默认不含，因此 workflow 中
**仅当配置了 `S3_BUCKET` 才安装 rclone**（官方 `install.sh` 只支持装最新 stable 或 `beta`，
**不支持指定版本**，安装失败直接 `exit 1` 中断）：

```yaml
# 上传步骤内、调用 upload_artifacts.sh 之前（仅 S3 场景）
if [ -n "$S3_BUCKET" ]; then
  curl -sSfL https://rclone.org/install.sh | sudo bash
  command -v rclone || { echo "rclone 安装失败" >&2; exit 1; }
fi
```

`msal` 在所有场景都需要（OneDrive 证书换令牌）：`pip install --quiet msal`。

> 注：早期提交的脚本头注释写"CI 镜像自带 / 可 apt 安装"是错误假设，已修正为"必须由调用方 CI 步骤显式安装"。

## 三、外置储存上的文件布局

```
<BASE>/
  ac-bundle-latest.tar.zst          # 整镜像：worldserver/authserver/db-import/tools/mysql
  ac-bundle-latest.tar.zst.sha256
  ac-maps-latest.tar.zst            # 地图镜像 ac-maps
  ac-maps-latest.tar.zst.sha256
```

`<BASE>` 即「外置储存下载前缀」，你输入**完整下载前缀**（含网盘 index 的 `/api/raw?path=` 结构），
脚本把自身生成的文件名直接拼到后面。例如 `EXT_STORAGE_BASE=https://dro.zhbq.eu.org/api/raw?path=/acok/`，
则 bundle 最终直链 = `https://dro.zhbq.eu.org/api/raw?path=/acok/ac-bundle-latest.tar.zst`。
本地路径同理：`EXT_STORAGE_BASE=/srv/acok/` → `/srv/acok/ac-maps-latest.tar.zst`。

## 四、部署侧：启用外置

运行 `acok.sh` → `1) 网络设置` → `2) 配置外置存储源` → 输入完整下载前缀（如 `https://dro.zhbq.eu.org/api/raw?path=/acok/` 或本地 `/srv/acok/`）。
脚本写入 `.env` 的 `DEPLOY_SRC=external` / `EXT_STORAGE_BASE=...`。之后安装/重部署会：

1. 仍从 Worker 拉取**小型配置文件**（`docker-compose.yml` / `.env` / `env.ac`）；
2. 用 **aria2c**（外置模式下若未装则自动安装）多线程下载两个 `*.tar.zst`；
3. `sha256sum -c` 校验 → `zstd -d | docker load` → 按 `IMAGE_NS` 重打标签；
4. `docker compose up -d` 直接起（镜像已在本地，不再 `docker pull`）。

## 五、回退

切回 ghcr 直连：在外置存储源菜单把前缀清空（或直接在 `.env` 删掉 `EXT_STORAGE_BASE=` 一行）并重跑 `acok.sh` 即可恢复 ghcr 拉取。
