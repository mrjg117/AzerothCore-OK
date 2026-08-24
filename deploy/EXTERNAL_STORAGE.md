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
| `ONEDRIVE_USER_ID` | 二选一 | 目标用户的 UPN 或 object id（如 `admin@zh33.onmicrosoft.com`）；告诉 rclone 传到**谁的盘** |
| `ONEDRIVE_DRIVE_ID` | 二选一 | 目标 drive 的 ID；填了则忽略 `USER_ID`，直接指定盘（免 rclone 解析） |
| `ONEDRIVE_UPLOAD_PATH` | 否 | 包上传到该用户盘**内**的目标目录（默认 `acok`）；即你要挂载/存放构建包的文件夹 |

> 选盘：`USER_ID` 与 `DRIVE_ID` 至少其一必填。app-only 证书模式下没有 `/me`，**必须显式告知传到哪个用户的哪个盘**——这正是 `USER_ID`（或 `DRIVE_ID`）的作用。
> 目录：`UPLOAD_PATH` 决定包落在该盘的哪个子目录，对应部署端 `EXT_STORAGE_BASE` 指向的那个文件夹。

应用权限需 `Files.ReadWrite.All`（Application 类型）。本方案**不使用 client secret**：
rclone 的 onedrive 后端不支持证书直连，因此由 `.github/scripts/onedrive_token.py` 用 msal
以**证书签名 client_assertion** 换 Graph app-only 令牌，再把令牌喂给 rclone 的 `token` +（`drive_id` 或 `user`）配置上传。

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

## 二之二、CI 依赖安装（rclone 必须显式安装）

GitHub 官方 `ubuntu-latest` runner **默认不含 `rclone`**，脚本依赖它做 OneDrive / S3 上传。
因此上传步骤里必须先安装 rclone 再调用脚本（已 pin 版本 v1.68.2，安装失败直接 `exit 1` 中断，
避免静默跳过导致"以为传了其实没传"）：

```yaml
# 上传步骤内、调用 upload_artifacts.sh 之前
curl -sSfL https://rclone.org/install.sh | sudo bash -s -- --version v1.68.2
command -v rclone || { echo "rclone 安装失败" >&2; exit 1; }
```

脚本侧同步加固：`backend_onedrive` 也加了 `command -v rclone` 前置检查，缺失时打印明确告警并跳过
（与 `backend_s3` 行为一致），不再出现裸 `rclone: command not found`。

> 注：早期提交的脚本头注释写"CI 镜像自带 / 可 apt 安装"是错误假设，已修正为"必须由调用方 CI 步骤显式安装"。

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
