#!/usr/bin/env bash
# 通用 SQL 归置引擎 —— 解决"模组自带 SQL 因路径不合规而未被官方 db-import 灌入"。
#
# 位置：workflow「Mount modules + apply build-patches」之后、「Build core images」之前。
#       必须在 build-patches 之后：apply_core_and_gen_sql.sh 会生成仓库里没有的 SQL。
#
# 设计原则（详见 docs/build-static-verify-notes.md R11）：
#   - 一个引擎、全规则驱动、零模组名硬编码、零目录名黑名单
#   - 默认不动，只有明确"放错了"才动（保守默认）
#   - db-import 只跑一次，不多跑
#
# 四步规则：
#   S1 结构性：在 data/sql/ 下 → 作者用了 AC 约定，尊重其选择，跳过
#   S2 内容安全：RED 不归置记 [ERR] 继续；GREEN/YELLOW 继续
#   S3 目标库判定：路径 → 内容 USE → 表名查 information_schema（需活库，无则跳过此信号）
#   S4 归属：有 C++ 源码（在 AC_MODULES_LIST）→ 复制到 data/sql/db-<库>/base/
#            无（纯脚本包，不在列表）        → 生成 updates_include 注册行写入核心 base 目录
#
# 用法：bash normalize_module_sql.sh <official 目录>

set +e

OFFICIAL="${1:?用法: normalize_module_sql.sh <official 目录>}"
MODULES="$OFFICIAL/modules"
: "${CI_ERR:=/tmp/ci_errors.log}"
touch "$CI_ERR"
rec()  { echo "[ERR] $*"  | tee -a "$CI_ERR"; }
warn() { echo "[WARN] $*" | tee -a "$CI_ERR"; }
log()  { echo "$*"; }

[ -d "$MODULES" ] || { rec "NORMALIZE: modules 目录不存在: $MODULES"; exit 0; }

# 收集待处理文件：modules 下所有 .sql，且不在 data/sql/ 之下（S1）
mapfile -t CANDIDATES < <(find "$MODULES" -name "*.sql" -type f | grep -viE "/data/sql/" | sort)

log "== 通用 SQL 归置引擎 =="
log "   模组目录: $MODULES"
log "   data/sql 之外（待判定）的 .sql: ${#CANDIDATES[@]} 个"

# ---------- 工具函数 ----------

# S2: 内容安全分级。
# 注意：以 "判定|原因" 单行输出——classify 在命令替换的子 shell 中执行，
# 用全局变量回传原因会丢失（子 shell 退出即丢弃），必须走 stdout。
classify() {
  local f="$1"

  # RED: 库级/权限级破坏
  if grep -qiE "DROP[[:space:]]+DATABASE|DROP[[:space:]]+USER|REVOKE[[:space:]]" "$f"; then
    echo "RED|库级/权限破坏(DROP DATABASE|DROP USER|REVOKE)"; return
  fi
  # RED: TRUNCATE
  if grep -qiE "TRUNCATE" "$f"; then
    echo "RED|TRUNCATE"; return
  fi
  # RED: USE 非标准库名（作者自己环境的脚本）
  local bad_use
  bad_use=$(grep -oiE "^[[:space:]]*USE[[:space:]]+[\`]?[A-Za-z_][A-Za-z0-9_]*" "$f" \
            | grep -oiE "[\`]?[A-Za-z_][A-Za-z0-9_]*$" | tr -d '`' \
            | grep -viE "^acore_(auth|characters|world|playerbots)$" | head -1)
  if [ -n "$bad_use" ]; then
    echo "RED|USE 非标准库名($bad_use)"; return
  fi
  # YELLOW: 清理（DELETE/DROP）非本文件自建的表
  local self t
  self=$(grep -oiE "CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?[\`][A-Za-z_][A-Za-z0-9_]*[\`]" "$f" \
         | grep -oiE "[A-Za-z_][A-Za-z0-9_]*\`$" | tr -d '`' | sort -u)
  for t in $(grep -oiE "^(DELETE[[:space:]]+FROM|DROP[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+EXISTS)?)[[:space:]]+[\`][A-Za-z_][A-Za-z0-9_]*[\`]" "$f" \
             | grep -oiE "[A-Za-z_][A-Za-z0-9_]*\`$" | tr -d '`' | sort -u); do
    if ! echo "$self" | grep -qx "$t"; then
      echo "YELLOW|清理非本文件自建表($t)"; return
    fi
  done
  echo "GREEN|"
}

# S3: 目标库判定（三级信号）
detect_db() {
  local f="$1" db=""
  # 信号1：路径含库名
  case "$f" in
    *"/characters/"*) db="characters";;
    *"/world/"*)      db="world";;
    *"/auth/"*)       db="auth";;
    *"/playerbots/"*) db="playerbots";;
  esac
  [ -n "$db" ] && { echo "$db"; return; }
  # 信号2：内容里的 USE `acore_<db>`
  db=$(grep -oiE "^[[:space:]]*USE[[:space:]]+[\`]?acore_[A-Za-z0-9_]*" "$f" \
       | head -1 | grep -oiE "acore_[A-Za-z0-9_]*$" | sed 's/^acore_//')
  [ -n "$db" ] && { echo "$db"; return; }
  # 信号3：文件内表名查 information_schema（需活库；无 MYSQL_PING 能力则跳过）
  if [ -n "$DB_QUERY" ]; then
    local tbl
    tbl=$(grep -oiE "CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?[\`][A-Za-z_][A-Za-z0-9_]*[\`]" "$f" \
          | grep -oiE "[A-Za-z_][A-Za-z0-9_]*\`$" | tr -d '`' | head -1)
    if [ -n "$tbl" ]; then
      db=$($DB_QUERY "SELECT table_schema FROM information_schema.tables WHERE table_name='$tbl' LIMIT 1;" 2>/dev/null | grep -oE "^acore_[a-z]+$" | sed 's/^acore_//')
    fi
  fi
  [ -n "$db" ] && { echo "$db"; return; }
  echo ""
}

# S4: 模组目录下有无 C++ 源码（决定是否在 AC_MODULES_LIST 内）
has_cxx() {
  local moddir="$1"
  [ -d "$moddir/src" ] && return 0
  [ -n "$(find "$moddir" -maxdepth 3 \( -name '*.cpp' -o -name '*.h' \) -print -quit 2>/dev/null)" ] && return 0
  return 1
}

# ---------- 主流程 ----------

declare -A INCLUDE_DIRS   # key: "<db>|<相对源码根的路径>"  -> 需要注册进 updates_include 的目录
COPIED=0; SKIPPED_RED=0; WARNED=0

for f in "${CANDIDATES[@]}"; do
  [ -f "$f" ] || continue
  rel="${f#$OFFICIAL/}"                    # modules/<mod>/...
  mod="${rel#modules/}"; mod="${mod%%/*}"  # <mod>
  moddir="$MODULES/$mod"

  line=$(classify "$f")
  verdict="${line%%|*}"
  reason="${line#*|}"
  case "$verdict" in
    RED)
      rec "NORMALIZE: 拒绝自动归置 $rel —— $reason"
      SKIPPED_RED=$((SKIPPED_RED+1))
      continue
      ;;
    YELLOW)
      log "  [YELLOW] $rel —— $reason"
      WARNED=$((WARNED+1))
      ;;
    *)
      log "  [GREEN ] $rel"
      ;;
  esac

  db=$(detect_db "$f")
  if [ -z "$db" ]; then
    rec "NORMALIZE: 无法判定目标库，跳过 $rel"
    continue
  fi

  if has_cxx "$moddir"; then
    # 在 AC_MODULES_LIST 内 → 复制到合规路径，让官方 db-import 自动扫到
    target_dir="$moddir/data/sql/db-$db/base"
    mkdir -p "$target_dir"
    if cp -f "$f" "$target_dir/$(basename "$f")"; then
      log "           -> 复制至 data/sql/db-$db/base/（官方自动灌入）"
      COPIED=$((COPIED+1))
    else
      rec "NORMALIZE: 复制失败 $rel -> $target_dir"
    fi
  else
    # 纯脚本包（不在 AC_MODULES_LIST）→ 记录目录，稍后注册进 updates_include
    srcdir=$(dirname "$f")
    incpath="\$/modules/$mod/${srcdir#$moddir/}"
    INCLUDE_DIRS["$db|$incpath"]=1
    log "           -> 登记 updates_include: $incpath (CUSTOM)"
  fi
done

# 输出 updates_include 注册文件到核心 base 目录（单次 db-import 即生效）。
#
# **每次运行重建（覆盖），不是追加** —— 必须如此：若 modules.txt 里摘掉某个模组，
# 追加模式会让指向已不存在目录的注册行残留，db-import 会对着空路径报目录不存在。
# 重建语义下，注册行始终与当前 modules.txt 严格一致。
#
# 约束（实测，缺一不可）：
#   - state 枚举只有 RELEASED/ARCHIVED/CUSTOM/PENDING，无 MODULE → 用 CUSTOM
#   - path 是 PRIMARY KEY → 必须 INSERT IGNORE
#   - $ 代表源码根 → $/modules/<mod>/<dir>
# 每条一个完整语句，天然幂等，避免多行 VALUES 拼接的逗号问题。
declare -A BY_DB
for key in "${!INCLUDE_DIRS[@]}"; do
  db="${key%%|*}"; incpath="${key#*|}"
  BY_DB["$db"]="${BY_DB[$db]} $incpath"
done

# 注意：BY_DB 的键是 detect_db 返回的**裸名**（auth/characters/world/playerbots），
# 不是 acore_* 全名；核心 base 目录则是 data/sql/base/db_<裸名>。键名必须对齐，否则取到空。
for db in auth characters world playerbots; do
  base_dir="$OFFICIAL/data/sql/base/db_$db"
  out="$base_dir/zz_project_updates_include.sql"
  [ -d "$base_dir" ] || continue
  if [ -z "${BY_DB[$db]}" ]; then
    # 本轮该库无需要注册的目录 → 清掉上一轮可能留下的文件，避免残留指向不存在路径
    if [ -f "$out" ]; then rm -f "$out"; log "  -> 清理无用的注册文件: data/sql/base/db_$db/zz_project_updates_include.sql"; fi
    continue
  fi
  {
    echo "-- 项目侧自动注入（normalize_module_sql.sh）：注册不在 AC_MODULES_LIST 内的纯脚本包 SQL 目录"
    echo "-- 每次运行重建（非追加）：modules.txt 中移除的模组，其注册行不会残留"
    echo "-- state 必须为 CUSTOM（该枚举不含 MODULE）；path 是主键，故用 INSERT IGNORE 保证幂等"
    for incpath in ${BY_DB[$db]}; do
      echo "INSERT IGNORE INTO \`updates_include\` (\`path\`, \`state\`) VALUES ('$incpath', 'CUSTOM');"
    done
  } > "$out"
  log "  -> 注册文件重建: data/sql/base/db_$db/zz_project_updates_include.sql"
done

log "== 归置引擎完成：复制 $COPIED 个、告警 $WARNED 个、拒绝 $SKIPPED_RED 个（错误见 [ERR] 与 Gate 汇总）=="
