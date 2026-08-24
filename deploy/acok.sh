#!/usr/bin/env bash
# ============================================================
# AzerothCore-OK —— 服务端多功能管理脚本（含 42 个模组）
# ------------------------------------------------------------
# 一行安装（服务器终端，需公网 IP、装好 Docker）：
#   curl -fsSL https://<你的Worker域名>/acok.sh | bash
#   （非交互运行时自动进入安装向导；本地 `bash acok.sh` 进入菜单）
#
# 功能菜单：
#   1 网络设置   2 安装向导   3 配置与维护   4 服务操作   5 凭据管理   q 退出
#
# 设计要点：
#   - 纯 bash + read，零外部依赖，单文件 curl|bash。
#   - 敏感/基础配置(SOAP 登录/密码/端口、DB 密码、对外地址)全部变量化：
#     值存于部署机持久化 .env / .soap_creds，重拉配置时由配置镜像注入同一真值，不冲、不泄露。
#   - 仅暴露 WORK_DIR 与少量凭据；./env/dist/etc、命名卷等内部路径不向用户暴露。
#   - 不改动 wrangler.toml 与构建流程。
#
# 可用环境变量（通常无需传）：
#   WORKER_BASE   本仓 Cloudflare Worker 域名（构建时烤进脚本；自定义域名可传 WORKER_BASE= 覆盖）
#   REALM_ADDRESS / IMAGE_NS / SOAP_LOGIN / SOAP_PASSWORD / DOCKER_DB_ROOT_PASSWORD / WORK_DIR
# ============================================================
set -euo pipefail

WORK_DIR="${WORK_DIR:-/opt/azerothcore-ok}"
WORKER_BASE="${WORKER_BASE:-REPLACE_WORKER_BASE}"
HISTORY_DIR=""
PLAN="fresh"

# 持久化凭据（位于 WORK_DIR，chmod 600，不进仓库/不进公开 .env）
SOAP_CREDS="$WORK_DIR/.soap_creds"
DB_CREDS="$WORK_DIR/.db_creds"
SOAP_LOGIN=""; SOAP_PASSWORD=""; DB_PW=""; REALM_ADDRESS=""; IMAGE_NS=""; GM_NAME=""; GM_PASS=""
# 外置储存部署状态（DEPLOY_SRC=ghcr | external）
EXT_STORAGE_BASE=""; AC_VERSION=""; DEPLOY_SRC="ghcr"
# 整镜像 bundle 的源命名空间（与 CI 推送所用 repository_owner 一致；部署端 docker load 后按 IMAGE_NS 重打标签）
BUNDLE_NS="ghcr.io/mrjg117"
PROXY=""
# 默认值常量（提示语括号显示用，非历史当前值）。以本文件 SPEC.md 第 0 节为准。
DEF_WORKDIR="/opt/azerothcore-ok"; DEF_REALM="play.example.com"; DEF_NS="ghcr.io/mrjg117"

# ---------- 输出与输入 ----------
c_info(){ printf '\033[36m[信息]\033[0m %s\n' "$*"; }
c_warn(){ printf '\033[33m[警告]\033[0m %s\n' "$*"; }
c_err() { printf '\033[31m[错误]\033[0m %s\n' "$*"; }
c_ok()  { printf '\033[32m[完成]\033[0m %s\n' "$*"; }

# 统一读取入口：文件模式(stdin 即终端)直接读 stdin；curl|bash 管道模式(stdin 是脚本本身)
# 改从 /dev/tty 读。提示语固定输出到终端(/dev/tty 或回退 stdout)，不污染命令替换捕获的返回值。
ask(){ ask_tty "$1" "${2:-}"; }
ask_s(){ ask_tty "$1" ""; }

# 交互读取：文件模式下 stdin 本身就是终端，直接读 stdin 最稳；
# 仅在 [ -t 0 ] 为假(管道)且 /dev/tty 存在时才改读 /dev/tty。
ask_tty(){
  local p="$1" d="${2:-}" s="${3:-}" v=""
  local src=/dev/stdin
  if [ ! -t 0 ] && [ -c /dev/tty ]; then src=/dev/tty; fi
  printf '%s' "$p" >/dev/tty 2>/dev/null || printf '%s' "$p"
  if [ -n "$s" ]; then
    read -rs v <"$src" 2>/dev/null; printf '\n' >/dev/tty 2>/dev/null
  else
    read -r v <"$src" 2>/dev/null
  fi
  printf '%s' "${v:-$d}"
}
maybe_back(){ [ "$1" = "b" ] || [ "$1" = "B" ]; }
confirm(){
  local p="$1" expect="${2:-YES}" a=""
  if [ -c /dev/tty ]; then
    printf '%s ' "$p" >/dev/tty
    read -r a </dev/tty
  else
    read -r -p "$p " a
  fi
  [ "$a" = "$expect" ]
}
set_env(){
  # set_env KEY VALUE：写入/更新 $WORK_DIR/.env 的 KEY=VALUE（纯 bash，不依赖 sed/mktemp）
  local key="$1" val="$2" f="$WORK_DIR/.env" tmp
  if [ ! -f "$f" ]; then printf '%s=%s\n' "$key" "$val" > "$f"; return 0; fi
  tmp="$f.tmp.$$"
  while IFS= read -r line; do
    if [ "${line#"$key"=}" != "$line" ]; then printf '%s=%s\n' "$key" "$val" >> "$tmp"
    else printf '%s\n' "$line" >> "$tmp"; fi
  done < "$f"
  grep -q "^${key}=" "$tmp" || printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$f"
}
default_gm_pass(){ printf '%s%s' "$(hostname)" "$(date +%m%d)"; }

# ---------- 环境检测 ----------
detect_distro(){
  if [ -f /etc/os-release ]; then . /etc/os-release; echo "${ID:-unknown}"; else echo unknown; fi
}
ensure_docker(){
  if command -v docker >/dev/null 2>&1; then return 0; fi
  c_info "未检测到 Docker，尝试安装..."
  local id; id="$(detect_distro)"
  case "$id" in
    ubuntu|debian|centos|rhel|fedora) curl -fsSL https://get.docker.com | sh ;;
    *) c_err "未知发行版 $id，请手动安装 Docker 后重试"; return 1 ;;
  esac
  command -v docker >/dev/null 2>&1 || { c_err "Docker 安装失败"; return 1; }
  c_ok "Docker 已安装"
}
ensure_aria2c(){
  # 仅在外置存储模式下需要：多线程 + 断点续传下载整镜像包。缺失则自动安装。
  command -v aria2c >/dev/null 2>&1 && return 0
  [ "${DEPLOY_SRC:-ghcr}" != "external" ] && return 0
  c_warn "未检测到 aria2c（外置存储下载所需），尝试自动安装..."
  local id; id="$(detect_distro)"
  case "$id" in
    ubuntu|debian) apt-get update -y >/dev/null 2>&1 && apt-get install -y aria2 >/dev/null 2>&1 ;;
    centos|rhel|fedora) ( command -v dnf >/dev/null 2>&1 && dnf install -y aria2 || yum install -y aria2 ) >/dev/null 2>&1 ;;
    alpine) apk add --no-cache aria2 >/dev/null 2>&1 ;;
    *) c_err "未知发行版 $id，请手动安装 aria2 后重试"; return 1 ;;
  esac
  command -v aria2c >/dev/null 2>&1 && { c_ok "aria2c 已安装"; return 0; }
  c_err "aria2c 自动安装失败，请手动安装后重试"; return 1
}
find_history(){
  local cand="/opt/azerothcore-ok $HOME/azerothcore-ok /srv/azerothcore-ok /root/azerothcore-ok $(pwd)"
  # 历史装在非标准路径时，从运行中的容器 label 精确定位其 compose 工作目录
  local from_docker
  from_docker="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' ac-worldserver 2>/dev/null)"
  if [ -n "$from_docker" ] && [ -d "$from_docker" ]; then HISTORY_DIR="$from_docker"; return 0; fi
  for d in $cand; do
    [ -d "$d" ] || continue
    if [ -f "$d/.soap_creds" ] || [ -f "$d/docker-compose.yml" ] || [ -f "$d/.env" ]; then
      HISTORY_DIR="$d"; return 0
    fi
  done
  return 1
}
load_creds(){
  local d="$1"
  [ -f "$d/.soap_creds" ] && {
    SOAP_LOGIN="$(grep '^SOAP_LOGIN=' "$d/.soap_creds" 2>/dev/null | cut -d= -f2-)"
    SOAP_PASSWORD="$(grep '^SOAP_PASSWORD=' "$d/.soap_creds" 2>/dev/null | cut -d= -f2-)"
  }
  [ -f "$d/.db_creds" ] && DB_PW="$(cat "$d/.db_creds" 2>/dev/null)"
  [ -f "$d/.env" ] && {
    [ -z "$REALM_ADDRESS" ] && REALM_ADDRESS="$(grep '^REALM_ADDRESS=' "$d/.env" 2>/dev/null | cut -d= -f2-)"
    [ -z "$IMAGE_NS" ] && IMAGE_NS="$(grep '^IMAGE_NS=' "$d/.env" 2>/dev/null | cut -d= -f2-)"
    [ -z "$DEPLOY_SRC" ] && DEPLOY_SRC="$(grep '^DEPLOY_SRC=' "$d/.env" 2>/dev/null | cut -d= -f2-)"
    [ -z "$EXT_STORAGE_BASE" ] && EXT_STORAGE_BASE="$(grep '^EXT_STORAGE_BASE=' "$d/.env" 2>/dev/null | cut -d= -f2-)"
    [ -z "$AC_VERSION" ] && AC_VERSION="$(grep '^AC_VERSION=' "$d/.env" 2>/dev/null | cut -d= -f2-)"
  }
}
save_creds(){
  mkdir -p "$WORK_DIR"
  [ -n "$SOAP_LOGIN" ] && printf 'SOAP_LOGIN=%s\nSOAP_PASSWORD=%s\n' "$SOAP_LOGIN" "$SOAP_PASSWORD" > "$SOAP_CREDS" && chmod 600 "$SOAP_CREDS"
  [ -n "$DB_PW" ] && printf '%s' "$DB_PW" > "$DB_CREDS" && chmod 600 "$DB_CREDS"
}
require_workdir(){
  if [ ! -d "$WORK_DIR" ] || [ ! -f "$WORK_DIR/docker-compose.yml" ]; then
    c_err "未找到部署目录 $WORK_DIR，请先运行『2 安装向导』"
    return 1
  fi
  cd "$WORK_DIR" || return 1
  return 0
}

# ---------- 1 网络设置 ----------
net_menu(){
  while true; do
    echo; echo "=== 1 网络设置 ==="
    echo "1) 设置临时代理（仅本次会话）"
    echo "2) 配置外置存储源（整镜像包下载，免 ghcr 拉取）"
    echo "q) 返回主菜单"
    local c; c="$(ask '网络> ')"; case "$c" in
      1) set_proxy;;
      2) ext_storage_menu;;
      q|Q) break;;
      *) c_warn "无效选择";;
    esac
  done
}
set_proxy(){
  local p; p="$(ask '输入代理地址(如 http://127.0.0.1:7890，留空取消): ')"
  if [ -n "$p" ]; then export http_proxy="$p" https_proxy="$p"; PROXY="$p"; c_ok "本次会话已设置代理 $p"; else unset http_proxy https_proxy; PROXY=""; c_info "已清除代理"; fi
}
ext_storage_menu(){
  while true; do
    echo; echo "=== 2 外置存储源（整镜像包下载，免 ghcr 拉取）==="
    echo "当前: $([ "${DEPLOY_SRC:-ghcr}" = external ] && echo "外置(${EXT_STORAGE_BASE:-未配置})" || echo "ghcr 直连")"
    echo "1) 切换为 ghcr 直连（默认）"
    echo "2) 切换为外置存储（输入基础目录 URL）"
    echo "q) 返回"
    local c; c="$(ask '存储> ')"; case "$c" in
      1) DEPLOY_SRC=ghcr; set_env DEPLOY_SRC ghcr; c_ok "已切回 ghcr 直连";;
      2)
        local b
        b="$(ask_tty '基础目录 URL（网盘 index / S3 挂载根，如 https://disk.example.org/acok/）: ' "${EXT_STORAGE_BASE:-}")"
        [ -n "$b" ] && {
          EXT_STORAGE_BASE="${b%/}"; DEPLOY_SRC=external
          set_env EXT_STORAGE_BASE "$EXT_STORAGE_BASE"
          set_env DEPLOY_SRC external
          c_ok "已启用外置存储: $EXT_STORAGE_BASE（部署时下载 ac-bundle-latest.tar.zst 并 docker load）"
        };;
      q|Q) break;;
      *) c_warn "无效选择";;
    esac
  done
}

# ---------- 2 安装向导 ----------
run_wizard(){
  ensure_docker || return 1
  local steps=(wz_history wz_env wz_creds wz_plan wz_deploy wz_maps)
  local wi=0 n=${#steps[@]}
  while [ $wi -lt $n ]; do
    if "${steps[$wi]}"; then wi=$((wi+1)); else wi=$((wi-1)); [ $wi -lt 0 ] && wi=0; fi
  done
}
wz_history(){
  echo; echo "--- ① 检测历史安装与部署方案 ---"
  if find_history; then
    c_info "发现历史安装：$HISTORY_DIR"
    load_creds "$HISTORY_DIR"
    c_info "已载入历史凭据"
    echo "  1) 原地更新（保留一切数据，仅拉最新镜像并重起）"
    echo "  2) 清理重装（销毁数据库与所有数据，全新开始）"
    local v; v="$(ask_tty "选择 [1]: " "1")"; if maybe_back "$v"; then return 1; fi
    case "$v" in
      2)
        if confirm "确认清理重装？将销毁玩家账号/角色等所有数据！输入 YES 继续:" "YES"; then PLAN="clean"; else PLAN="update"; fi ;;
      *) PLAN="update" ;;
    esac
  else
    c_info "未发现历史安装，将执行全新安装"
    HISTORY_DIR=""; PLAN="fresh"
  fi
  return 0
}
wz_env(){
  echo; echo "--- ② 部署目录与外网地址（输入 b 返回上一步）---"
  local v
  # 默认值从发布的 .env.example 取（build.sh 已把 WORLD_HOST/IMAGE_NS 烤进去），
  # 避免向导显示空默认、甚至回车被 play.example.com 覆盖真值。
  if [ -z "$REALM_ADDRESS" ] || [ -z "$IMAGE_NS" ]; then
    _env_tpl="$(curl -fsSL --max-time 20 "$WORKER_BASE/.env.example" 2>/dev/null)"
    [ -z "$REALM_ADDRESS" ] && REALM_ADDRESS="$(printf '%s\n' "$_env_tpl" | grep '^REALM_ADDRESS=' | cut -d= -f2-)"
    [ -z "$IMAGE_NS" ] && IMAGE_NS="$(printf '%s\n' "$_env_tpl" | grep '^IMAGE_NS=' | cut -d= -f2-)"
  fi
  REALM_ADDRESS="${REALM_ADDRESS:-play.example.com}"
  IMAGE_NS="${IMAGE_NS:-ghcr.io/mrjg117}"
  v="$(ask_tty "部署目录 [$DEF_WORKDIR]: " "${WORK_DIR:-$DEF_WORKDIR}")"; if maybe_back "$v"; then return 1; fi; WORK_DIR="${v:-$DEF_WORKDIR}"
  SOAP_CREDS="$WORK_DIR/.soap_creds"; DB_CREDS="$WORK_DIR/.db_creds"
  v="$(ask_tty "对外地址(域名或IP) [$DEF_REALM]: " "${REALM_ADDRESS:-$DEF_REALM}")"; if maybe_back "$v"; then return 1; fi; REALM_ADDRESS="${v:-$REALM_ADDRESS}"
  v="$(ask_tty "镜像命名空间 [$DEF_NS]: " "${IMAGE_NS:-$DEF_NS}")"; if maybe_back "$v"; then return 1; fi; IMAGE_NS="${v:-$IMAGE_NS}"
  return 0
}
wz_creds(){
  echo; echo "--- ③ 凭据（GM 与 SOAP 凭据 / 数据库，输入 b 返回）---"
  local v
  # GM 游戏账号（给人登录游戏、管理服务器）
  v="$(ask_tty "GM 账号名 [${GM_NAME:-acok}]: " "${GM_NAME:-acok}")"; if maybe_back "$v"; then return 1; fi; GM_NAME="${v:-acok}"
  v="$(ask_tty "GM 登录密码 [$(default_gm_pass)]: " "")"; if maybe_back "$v"; then return 1; fi
  [ -z "$v" ] && v="$(default_gm_pass)"; GM_PASS="$v"
  # SOAP 机器账号（专供 Worker ↔ worldserver 鉴权）
  while :; do
    v="$(ask_tty "SOAP 账号名: " "")"; if maybe_back "$v"; then return 1; fi
    [ -n "$v" ] && break
    c_warn "SOAP 账号名不能为空"
  done
  SOAP_LOGIN="$v"
  # 同名冲突提示：GM 与 SOAP 账号名不能相同（同 realm 账号名唯一）
  while [ "$SOAP_LOGIN" = "$GM_NAME" ]; do
    c_warn "SOAP 账号名不能与 GM 账号名($GM_NAME)相同，请换一个"
    v="$(ask_tty "SOAP 账号名: " "")"; if maybe_back "$v"; then return 1; fi
    [ -n "$v" ] && SOAP_LOGIN="$v" || { c_warn "SOAP 账号名不能为空"; continue; }
  done
  while :; do
    v="$(ask_tty "SOAP 密码: " "")"; if maybe_back "$v"; then return 1; fi
    [ -n "$v" ] && break
    c_warn "SOAP 密码不能为空"
  done
  SOAP_PASSWORD="$v"
  v="$(ask_tty "数据库 root 密码 [AcokDbRoot2026!]: " "${DB_PW:-AcokDbRoot2026!}")"; if maybe_back "$v"; then return 1; fi; DB_PW="${v:-AcokDbRoot2026!}"
  return 0
}
wz_plan(){
  echo; echo "--- ④ 部署确认（输入 b 返回上一步，y 直接部署）---"
  while true; do
    echo "当前配置："
    echo "  部署目录:     $WORK_DIR"
    echo "  对外地址:     $REALM_ADDRESS"
    echo "  镜像命名空间:  $IMAGE_NS"
    echo "  GM 账号:      $GM_NAME"
    echo "  SOAP 账号:    $SOAP_LOGIN"
    echo "  DB root 密码: $DB_PW"
    echo "  部署方案:      $([ "$PLAN" = clean ] && echo 清理重装 || echo 原地更新/全新)"
    echo "选项："
    echo "  1) 修改 部署目录/外网地址/镜像源"
    echo "  2) 修改 GM/SOAP/数据库凭据"
    echo "  3) 修改 部署方案(原地更新/清理重装)"
    echo "  y) 确认并部署（默认）"
    echo "  b) 返回上一步"
    local v; v="$(ask_tty "确认部署 [y]: " "y")"; if maybe_back "$v"; then return 1; fi
    case "$v" in
      1) wz_env;;
      2) wz_creds;;
      3) wz_history;;
      y|Y|"") return 0;;
      *) c_warn "无效选择";;
    esac
  done
}
wz_deploy(){
  echo; echo "--- ⑤ 部署（拉取最新镜像并启动）---"
  mkdir -p "$WORK_DIR" && cd "$WORK_DIR" || { c_err "无法进入 $WORK_DIR"; return 1; }
  c_info "下载部署文件到 $WORK_DIR ..."
  curl -fsSL "$WORKER_BASE/docker-compose.override.yml" -o docker-compose.override.yml
  curl -fsSL "$WORKER_BASE/.env.example" -o .env
  curl -fsSL "$WORKER_BASE/docker-compose.yml" -o docker-compose.yml
  # 官方 compose 硬引用 conf/dist/env.ac 作为 worldserver/authserver 的 env_file；
  # 缺失会导致 docker compose up 报 env.ac not found。只拉这一个运行期有用的文件。
  mkdir -p conf/dist
  if ! curl -fsSL "$WORKER_BASE/conf/dist/env.ac" -o conf/dist/env.ac; then
    c_err "下载 conf/dist/env.ac 失败（配置来源缺失，部署无法继续）"; return 1
  fi
  [ -n "$REALM_ADDRESS" ] && set_env REALM_ADDRESS "$REALM_ADDRESS"
  [ -n "$IMAGE_NS" ] && set_env IMAGE_NS "$IMAGE_NS"
  set_env SOAP_LOGIN "$SOAP_LOGIN"
  set_env SOAP_PASSWORD "$SOAP_PASSWORD"
  [ -n "$DB_PW" ] && set_env DOCKER_DB_ROOT_PASSWORD "$DB_PW"
  save_creds
  chmod 600 "$WORK_DIR/.env" 2>/dev/null || true   # B5: .env 含 SOAP/DOCKER_DB_ROOT_PASSWORD 明文，收紧权限与 .soap_creds 一致
  if [ "$PLAN" = "clean" ]; then
    c_warn "清理重装：备份凭据并销毁容器与数据卷..."
    local bk="$WORK_DIR.bak.$(date +%s)"; mkdir -p "$bk"; cp -a .env .soap_creds .db_creds "$bk"/ 2>/dev/null || true
    docker compose down -v || true
  fi
  fix_env_perms
  pull_with_eta || return 1
  c_info "启动服务 (docker compose up -d) ... 首次启动数据库初始化约 1-3 分钟"
  # 只起核心栈；地图(ac-client-data-init)随 worldserver 依赖自动导入；配置(ac-extra-config)改部署后可选
  docker compose up -d ac-worldserver ac-authserver ac-database ac-db-import
  c_info "等待 worldserver 并创建账号（GM=$GM_NAME / SOAP=$SOAP_LOGIN）..."
  for _k in $(seq 1 36); do docker compose exec -T ac-worldserver acore account list >/dev/null 2>&1 && break; sleep 5; done
  # GM 游戏账号（给人登录游戏、管理服务器）
  docker compose exec -T ac-worldserver acore account create "$GM_NAME" "$GM_PASS" >/dev/null 2>&1 || true
  docker compose exec -T ac-worldserver acore account set gmlevel "$GM_NAME" 3 >/dev/null 2>&1 \
    && c_ok "GM 账号 $GM_NAME 就绪(gmlevel 3)" \
    || c_warn "GM 建号失败，请手动: docker compose exec ac-worldserver acore account create $GM_NAME <密码> 3"
  # SOAP 机器账号（喂 worldserver.conf，须与 CF 后台一致）
  docker compose exec -T ac-worldserver acore account create "$SOAP_LOGIN" "$SOAP_PASSWORD" >/dev/null 2>&1 || true
  docker compose exec -T ac-worldserver acore account set gmlevel "$SOAP_LOGIN" 3 >/dev/null 2>&1 \
    && c_ok "SOAP 账号 $SOAP_LOGIN 就绪(gmlevel 3)" \
    || c_warn "SOAP 建号失败，请手动: docker compose exec ac-worldserver acore account create $SOAP_LOGIN <密码> 3"
  REALM="$REALM_ADDRESS"; REALM_SQL="${REALM//\'/\'\'}"
  c_info "写入 realm 对外地址 ($REALM) ..."
  for _k in $(seq 1 36); do docker compose exec -T ac-database mysql -uroot -p"$DB_PW" -e "SELECT 1" acore_auth >/dev/null 2>&1 && break; sleep 3; done
  docker compose exec -T ac-database mysql -uroot -p"$DB_PW" acore_auth -e "UPDATE realmlist SET address='$REALM_SQL' WHERE id=1;" >/dev/null 2>&1 \
    && c_ok "realm 地址已更新" \
    || c_warn "realmlist 未就绪，请手动: UPDATE acore_auth.realmlist SET address='$REALM' WHERE id=1;"
  c_ok "部署完成！"
  echo
  if confirm "是否现在导入配置(启用 SOAP 注册通道等)? [y/N]: " "y"; then import_config; else c_info "可稍后在『3 配置与维护 → 导入配置』中导入"; fi
  c_info "世界服端口 8085 / 3724；注册 SOAP 7878；玩家连接地址 $REALM"
  c_info "GM 账号: $GM_NAME   密码: $GM_PASS"
  c_info "SOAP 账号(Worker 鉴权): $SOAP_LOGIN   密码: $SOAP_PASSWORD"
  return 0
}
wz_maps(){
  echo; echo "--- ⑥ 地图数据（随部署按官方流程已导入）---"
  if docker volume inspect ac-client-data >/dev/null 2>&1; then
    c_info "地图已随部署导入（卷 ac-client-data 已存在）"
  else
    c_warn "未检测到地图数据卷（部署时导入可能未完成或失败），是否现在补拉？(y/N)"
    if confirm "拉取地图? [y/N]: " "y"; then import_maps; else c_info "可稍后在『3 配置与维护 → 导入地图』中拉取"; fi
  fi
  return 0
}

# ---------- 3 配置与维护 ----------
maintain_menu(){
  require_workdir || return 1
  while true; do
    echo; echo "=== 3 配置与维护 ==="
    echo "1) 导入地图（检测 + 重拉，约 1.2GiB）"
    echo "2) 导入配置（备份 ./env/dist/etc + 重跑 ac-extra-config，变量不冲关键配置）"
    echo "3) 重跑 db-import"
    echo "4) 完整重部署（拉最新镜像 + 重建，保留数据）"
    echo "q) 返回主菜单"
    local c; c="$(ask '维护> ')"; case "$c" in
      1) import_maps;;
      2) import_config;;
      3) rerun_db_import;;
      4) full_redeploy;;
      q|Q) break;;
      *) c_warn "无效选择";;
    esac
  done
}
import_maps(){
  c_info "拉取地图数据（ac-client-data-init，写入命名卷 ac-client-data，约 1.2GiB）..."
  docker compose up ac-client-data-init
  c_ok "地图数据已导入（卷 ac-client-data）"
}
import_config(){
  c_warn "重拉配置将覆盖 worldserver.conf / playerbots.conf / mod_item_affixes.conf"
  local bk="./env/dist/etc.bak.$(date +%s)"
  mkdir -p ./env/dist
  cp -a ./env/dist/etc "$bk" 2>/dev/null && c_ok "已备份到 $bk" || c_warn "备份失败（可能尚未生成配置）"
  docker compose rm -f ac-extra-config >/dev/null 2>&1 || true
  docker compose up ac-extra-config
  c_ok "配置已重拉。worldserver 需重启(4.2)或热重载(4.1)生效。"
}
rerun_db_import(){ c_info "重跑 db-import ..."; docker compose up ac-db-import; c_ok "完成"; }
full_redeploy(){ c_info "完整重部署：拉最新镜像并重建（保留数据卷）..."; fix_env_perms; pull_with_eta || return 1; docker compose up -d ac-worldserver ac-authserver ac-database ac-db-import; c_ok "完成"; }

# ---------- 4 服务操作 ----------
svc_menu(){
  require_workdir || return 1
  while true; do
    echo; echo "=== 4 服务操作 ==="
    echo "1) 热重载配置（.reload config）"
    echo "2) 重启 worldserver（智能：已停则启动）"
    echo "3) 停止服务"
    echo "4) 查看状态"
    echo "5) 查看日志（最近 200 行）"
    echo "q) 返回主菜单"
    local c; c="$(ask '服务> ')"; case "$c" in
      1) svc_reload;;
      2) svc_restart_world;;
      3) svc_stop;;
      4) svc_status;;
      5) svc_logs;;
      q|Q) break;;
      *) c_warn "无效选择";;
    esac
  done
}
svc_reload(){
  c_info "尝试热重载配置（.reload config）..."
  if docker compose exec -T ac-worldserver acore reload config >/dev/null 2>&1; then
    c_ok "已发送 reload config"
  else
    c_warn "自动 reload 失败；请手动进入 worldserver 控制台执行： .reload config"
  fi
}
svc_restart_world(){
  if docker compose ps ac-worldserver 2>/dev/null | grep -q 'running'; then
    c_info "worldserver 正在运行，重启..."; docker compose restart ac-worldserver
  else
    c_info "worldserver 未运行，启动..."; docker compose up -d ac-worldserver
  fi
  c_ok "完成"
}
svc_stop(){ c_warn "将停止全部服务（数据保留，可用 4.2 重新启动）..."; docker compose stop; c_ok "已停止"; }
svc_status(){ docker compose ps; }
svc_logs(){ docker compose logs --tail=200 ac-worldserver; c_info "实时日志: docker compose logs -f ac-worldserver"; }

# ---------- 5 凭据管理 ----------
creds_menu(){
  require_workdir || return 1
  while true; do
    echo; echo "=== 5 凭据管理 ==="
    echo "1) 改 SOAP 账号名(Worker 鉴权)"
    echo "2) 改 SOAP 密码"
    echo "3) 改数据库 root 密码"
    echo "4) 查找历史安装位置"
    echo "5) 账号管理（新建普通 / 新建 GM 带等级 / 改 GM 等级）"
    echo "q) 返回主菜单"
    local c; c="$(ask '凭据> ')"; case "$c" in
      1) change_soap_login;;
      2) change_soap_pass;;
      3) change_db_pass;;
      4) find_history_menu;;
      5) account_mgmt;;
      q|Q) break;;
      *) c_warn "无效选择";;
    esac
  done
}
change_soap_login(){
  local v; v="$(ask '新 SOAP 账号名: ')"; [ -z "$v" ] && return
  SOAP_LOGIN="$v"
  set_env SOAP_LOGIN "$SOAP_LOGIN"
  printf 'SOAP_LOGIN=%s\nSOAP_PASSWORD=%s\n' "$SOAP_LOGIN" "$SOAP_PASSWORD" > "$SOAP_CREDS" && chmod 600 "$SOAP_CREDS"
  c_ok "已更新。需重拉配置(3.2)+重启worldserver(4.2)生效。"
}
change_soap_pass(){
  local v; v="$(ask_s '新 SOAP 密码: ')"; [ -z "$v" ] && return
  SOAP_PASSWORD="$v"
  set_env SOAP_PASSWORD "$SOAP_PASSWORD"
  printf 'SOAP_LOGIN=%s\nSOAP_PASSWORD=%s\n' "$SOAP_LOGIN" "$SOAP_PASSWORD" > "$SOAP_CREDS" && chmod 600 "$SOAP_CREDS"
  c_ok "已更新本地。需重拉配置(3.2)+重启(4.2)生效。"
}
change_db_pass(){
  local v; v="$(ask_s '新数据库 root 密码: ')"; [ -z "$v" ] && return
  DB_PW="$v"
  set_env DOCKER_DB_ROOT_PASSWORD "$DB_PW"
  printf '%s' "$DB_PW" > "$DB_CREDS" && chmod 600 "$DB_CREDS"
  c_ok "已更新 .env。需重启数据库服务生效（docker compose restart ac-database）。"
}
find_history_menu(){
  if find_history; then c_ok "历史安装位于: $HISTORY_DIR"; else c_warn "未发现历史安装"; fi
}
account_mgmt(){
  while true; do
    echo; echo "=== 5.5 账号管理 ==="
    echo "a) 新建普通账号"
    echo "b) 新建 GM 账号（带等级）"
    echo "c) 修改某账号 GM 等级"
    echo "q) 返回"
    local c n p l
    c="$(ask '账号> ')"; case "$c" in
      a)
        n="$(ask '账号名: ')"; p="$(ask_s '密码: ')"
        docker compose exec -T ac-worldserver acore account create "$n" "$p" && c_ok "已建" || c_err "失败"
        ;;
      b)
        n="$(ask '账号名: ')"; p="$(ask_s '密码: ')"; l="$(ask 'GM 等级(1-3): ')"
        docker compose exec -T ac-worldserver acore account create "$n" "$p"
        docker compose exec -T ac-worldserver acore account set gmlevel "$n" "$l" && c_ok "已建 GM($l)" || c_err "失败"
        ;;
      c)
        n="$(ask '账号名: ')"; l="$(ask '新 GM 等级(1-3): ')"
        docker compose exec -T ac-worldserver acore account set gmlevel "$n" "$l" && c_ok "已改($l)" || c_err "失败"
        ;;
      q|Q) break;;
      *) c_warn "无效选择";;
    esac
  done
}

# ---------- 公共：拉取（带进度/ETA） ----------
# 修正配置/日志目录归属：以 root 部署时 Docker 会自建 ./env/dist/etc|logs 并归 root，
# 而容器内进程以 uid 1000 运行、无写权限 -> ac-db-import/worldserver 报 Permission denied。
# 真机原生 Linux 下 chown 生效；NTFS 挂载(chown 无效)环境需配合 .env 里 DOCKER_USER=root。
fix_env_perms(){
  mkdir -p "$WORK_DIR/env/dist/etc" "$WORK_DIR/env/dist/logs"
  if chown -R 1000:1000 "$WORK_DIR/env/dist/etc" "$WORK_DIR/env/dist/logs" 2>/dev/null; then
    c_info "已修正 env/dist/etc|logs 归属(uid 1000)"
  else
    c_warn "chown 未生效（可能为 NTFS 挂载）；若仍 Permission denied，请在 .env 加 DOCKER_USER=root 后重跑"
  fi
}

# 外置存储：下载整镜像 bundle → sha256 校验 → docker load → 按 IMAGE_NS 重打标签
fetch_bundle(){
  ensure_aria2c || return 1
  local base="${EXT_STORAGE_BASE%/}"
  [ -z "$base" ] && { c_err "未配置外置存储源：『1 网络设置 → 外置存储源』先配置基础目录 URL"; return 1; }
  mkdir -p "$WORK_DIR" && cd "$WORK_DIR" || { c_err "无法进入 $WORK_DIR"; return 1; }
  local imgs="worldserver authserver db-import tools mysql maps"
  local bn sum ok
  for f in ac-bundle-latest.tar.zst ac-maps-latest.tar.zst; do
    bn="$f"; sum="$f.sha256"
    c_info "下载 $base/$bn（aria2c 多线程 + 断点续传）..."
    if ! aria2c -c -x16 -s16 -k1M --summary-interval=10 --console-log-level=warn \
         -d "$WORK_DIR" -o "$bn" "$base/$bn"; then
      c_err "下载失败（$bn），可重试（支持断点续传）"; return 1
    fi
    c_info "下载校验文件并校验 sha256 ..."
    curl -fsSL "$base/$sum" -o "$WORK_DIR/$sum" || { c_err "下载校验文件失败（$sum）"; return 1; }
    ( cd "$WORK_DIR" && sha256sum -c "$sum" ) || { c_err "校验失败，包可能损坏：$bn"; return 1; }
    c_ok "校验通过，载入镜像（docker load）..."
    zstd -d -c "$WORK_DIR/$bn" | docker load
  done
  # 按部署机 IMAGE_NS 重打标签，使 docker compose 本地命中（不回退 ghcr 拉取）
  local ns="$BUNDLE_NS" dst="${IMAGE_NS:-ghcr.io/mrjg117}"
  local core_imgs="worldserver authserver db-import tools mysql"
  for t in $core_imgs; do
    docker tag "$ns/ac-wotlk-$t:latest" "$dst/ac-wotlk-$t:latest" 2>/dev/null || true
  done
  docker tag "$ns/ac-maps:latest" "$dst/ac-maps:latest" 2>/dev/null || true
  c_ok "整镜像包载入完成（已按 $dst 重打标签）"
}

pull_with_eta(){
  # 外置存储模式：整镜像包已 docker load，跳过 ghcr 拉取
  if [ "${DEPLOY_SRC:-ghcr}" = "external" ]; then
    fetch_bundle || return 1
    return 0
  fi
  local start end
  start=$(date +%s)
  c_info "开始拉取核心镜像（docker 原生进度含实时 ETA）..."
  # 只拉核心栈 + 地图；配置镜像(ac-extra-config)改部署后可选，不在此强制拉取
  if ! docker compose pull ac-worldserver ac-authserver ac-database ac-db-import ac-client-data-init; then
    c_err "核心镜像拉取失败（检查网络/镜像源/IMAGE_NS，确认 ac-maps 等镜像已公开）"
    return 1
  fi
  end=$(date +%s)
  c_ok "拉取完成，用时 $((end-start)) 秒"
}

# ---------- 主菜单 ----------
show_main(){
  echo; echo "========== AzerothCore-OK 管理菜单 =========="
  echo " 1) 网络设置    2) 安装向导    3) 配置与维护"
  echo " 4) 服务操作    5) 凭据管理    q) 退出"
  echo " 部署目录: $WORK_DIR"
}
menu_loop(){
  while true; do
    show_main
    local c; c="$(ask '请选择: ')"; case "$c" in
      1) net_menu;;
      2) run_wizard;;
      3) maintain_menu;;
      4) svc_menu;;
      5) creds_menu;;
      q|Q|quit|exit) c_info "再见"; break;;
      *) c_warn "无效选择";;
    esac
  done
}

main(){
  if [ -z "$WORKER_BASE" ] || echo "$WORKER_BASE" | grep -q "REPLACE_WORKER_BASE"; then
    c_err "WORKER_BASE 仍是占位符：请在 deploy/wrangler.toml 的 [vars] 把 WORKER_BASE 改成真实 Worker 地址后重新构建部署。"
    exit 1
  fi
  if [ -t 0 ] || [ -t 1 ]; then
    # 交互运行（本地 bash acok.sh 或 curl|bash 在终端）：先探测历史安装以便后续操作定位 WORK_DIR
    find_history && WORK_DIR="${HISTORY_DIR:-$WORK_DIR}" && load_creds "$WORK_DIR" || true
    menu_loop
  else
    c_info "检测到非交互运行（无终端），直接进入安装向导..."
    run_wizard
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${BASH_SOURCE[0]}" ]; then
  main "$@"
fi
