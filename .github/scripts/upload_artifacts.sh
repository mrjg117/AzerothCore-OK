#!/usr/bin/env bash
# ============================================================
# upload_artifacts.sh —— 把构建产物传到「已配置的外置后端」
# ------------------------------------------------------------
# 语义（重要）：不是二选一，而是「有哪个的凭证就传哪个、都填了就都传」。
#   - OneDrive：E5 账号 + 自建应用 + 证书鉴权（app-only，非交互）
#   - S3      ：通用 S3 凭证（AWS / Cloudflare R2 / B2-S3 / MinIO 等，仅 endpoint 不同）
# 任一后端未配置凭证则静默跳过，不会报错；都不配置则什么都不传（ghcr 仍保留）。
#
# 用法:  .github/scripts/upload_artifacts.sh <file> [remote-subdir]
#   <file>          本地文件路径（如 ac-bundle-latest.tar.zst）
#   [remote-subdir] 远端子目录（默认 acok/），文件落地为 <subdir>/<basename>
#
# 依赖: rclone（CI 镜像自带 / 可 apt 安装）；msal（仅 OneDrive，python3 -m pip install msal）
# ============================================================
set -euo pipefail

f="$1"
[ -f "$f" ] || { echo "upload: 文件不存在: $f" >&2; exit 1; }
# 上传目录：优先环境变量 ONEDRIVE_UPLOAD_PATH（用户在 CI Secret 指定盘内目录），
# 否则退到命令行第二参数，再退默认 acok
subdir="${ONEDRIVE_UPLOAD_PATH:-${2:-acok}}"
name="$(basename "$f")"

backend_onedrive(){
  # 选盘：user_id 或 drive_id 至少其一（缺则视为未配置 → 跳过）
  if [ -z "${ONEDRIVE_USER_ID:-}" ] && [ -z "${ONEDRIVE_DRIVE_ID:-}" ]; then
    return 0
  fi
  # 证书四件套 + 应用 ID 缺一不可
  [ -z "${ONEDRIVE_CLIENT_ID:-}" ] && return 0
  [ -z "${ONEDRIVE_TENANT:-}" ]    && return 0
  [ -z "${ONEDRIVE_CERT:-}" ]      && return 0
  [ -z "${ONEDRIVE_KEY:-}" ]       && return 0

  echo ">> [OneDrive] 证书鉴权上传 $name -> ${subdir}/$name (user=${ONEDRIVE_USER_ID:-drive_id=${ONEDRIVE_DRIVE_ID:-?}})"
  # 1) 用证书换 app-only 访问令牌（client_assertion，JWT 由证书私钥签名）
  token_json="$(python3 "$(dirname "$0")/onedrive_token.py")" || {
    echo "   OneDrive 令牌获取失败，跳过该后端" >&2; return 0
  }
  # 2) 写 rclone 配置：drive_id 优先直接指定盘；否则用 user_id 让 rclone
  #    解析该用户的 drive（app-only + Files.ReadWrite.All 权限，无需 client secret）
  drive_conf=""
  if [ -n "${ONEDRIVE_DRIVE_ID:-}" ]; then
    drive_conf="drive_id = ${ONEDRIVE_DRIVE_ID}"
  else
    drive_conf="user = ${ONEDRIVE_USER_ID}
drive_type = business"
  fi
  cat > /tmp/rclone-od.conf <<EOF
[acok]
type = onedrive
client_id = ${ONEDRIVE_CLIENT_ID}
token = ${token_json}
${drive_conf}
region = global
EOF
  # 3) 上传（失败不阻断，仅告警）
  rclone --config /tmp/rclone-od.conf copy "$f" "acok:${subdir}/$name" || {
    echo "   OneDrive 上传失败，跳过该后端" >&2; return 0
  }
  echo "   OneDrive 上传完成"
}

backend_s3(){
  # 通用 S3 凭证：AK/SK/BUCKET 三件套缺一即视为未配置 → 跳过
  [ -z "${S3_BUCKET:-}" ]     && return 0
  [ -z "${S3_ACCESS_KEY:-}" ] && return 0
  [ -z "${S3_SECRET_KEY:-}" ] && return 0

  echo ">> [S3] 通用凭证上传 $name -> ${S3_BUCKET}/${subdir}/$name"
  if command -v rclone >/dev/null 2>&1; then
    # rclone s3 remote：provider=Other + endpoint 即可通吃 R2/AWS/B2/MinIO
    cat > /tmp/rclone-s3.conf <<EOF
[acok]
type = s3
provider = $([ -n "${S3_ENDPOINT:-}" ] && echo 'Other' || echo 'AWS')
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION}
EOF
    rclone --config /tmp/rclone-s3.conf copy "$f" "acok:${S3_BUCKET}/${subdir}/$name" || {
      echo "   S3(rclone) 上传失败，跳过该后端" >&2; return 0
    }
  elif command -v aws >/dev/null 2>&1; then
    aws s3 cp "$f" "s3://${S3_BUCKET}/${subdir}/$name" \
      ${S3_ENDPOINT:+--endpoint-url "$S3_ENDPOINT"} ${S3_REGION:+--region "$S3_REGION"} || {
      echo "   S3(aws) 上传失败，跳过该后端" >&2; return 0
    }
  else
    echo "   S3 凭证已配但无 rclone/aws 可用，跳过该后端" >&2; return 0
  fi
  echo "   S3 上传完成"
}

# 依次调用各后端（各自独立自检）。叠加语义：都填都传、填哪个传哪个。
backend_onedrive "$f"
backend_s3 "$f"
echo ">> upload_artifacts 完成（无配置的后端已静默跳过）"
