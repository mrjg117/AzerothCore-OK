#!/usr/bin/env bash
# AzerothCore-OK —— 部署前用本机 .env 替换 ./env/dist/etc/*.conf 里的 __SOAP_LOGIN__ / __SOAP_PASSWORD__ 占位符。
# 镜像仓库默认不写秘密，配置模板保留占位符；此处替换（与 config/extra-config/docker-entrypoint.sh 同 awk 逻辑）。
# 用法：先 cp .env.example .env 填真实值，再 bash deploy/inject-config.sh
set -e
if [ -f ./.env ]; then set -a; . ./.env; set +a; fi
if [ -z "${SOAP_PASSWORD:-}" ]; then
  echo "ERROR: 未设置 SOAP_PASSWORD，请在 .env 显式配置（与 Cloudflare Worker 端一致）。" >&2
  exit 1
fi
ETC="./env/dist/etc"
[ -d "$ETC" ] || { echo "ERROR: $ETC 不存在，请先解压 etc.tar.zst"; exit 1; }
for f in "$ETC"/*.conf; do
  [ -f "$f" ] || continue
  awk '
    { line=$0
      while (match(line, /__[A-Za-z0-9_]+__/)) {
        token=substr(line,RSTART,RLENGTH)
        vname=substr(token,3,RLENGTH-4)
        val=(vname in ENVIRON)?ENVIRON[vname]:""
        line=substr(line,1,RSTART-1) val substr(line,RSTART+RLENGTH)
      }
      print line }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
echo "已用本机 .env 替换 $ETC 配置占位符"
