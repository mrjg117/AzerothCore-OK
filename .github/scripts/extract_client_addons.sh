#!/usr/bin/env bash
# ============================================================================
# 从已克隆的模组(modules/)中提取「客户端插件」与「zhCN 数据/MPQ」到 client-patches/。
# 供 .github/workflows/build-static-verify.yml 在 Mount modules 之后调用；
# 提取结果（构建期临时产物，已被 .gitignore 忽略）由 client-patches/make-archive.py
# 打包成玩家客户端补丁(zip)。
#
# 通用规则(不靠目录名/模组名，避免换个名字就漏判)：
#   客户端插件 = 其目录树中存在 .toc 文件
#     (WoW 客户端插件 MUST 有 .toc；服务端 Eluna/ALE 脚本永远不会有 .toc)。
#     该 .toc 所在目录即「插件根目录」，整目录复制到
#       client-patches/<模组名>/Interface/addons/<插件根目录名>/
#   MPQ / 数据文件 = *.mpq 以及 data/ 下的文件(DBC/贴图/客户端资源)：
#     复制到 client-patches/<模组名>/data/zhcn/<相对模组根的 path，但剥掉模组自身
#       data/zhCN(或 data/zhcn、data) 前缀，避免双重嵌套>
#       (即：让文件落到客户端 Data/zhCN/ 下对应位置，而非 Data/zhCN/data/zhCN/...)。
#
# 仅处理 modules.txt 启用集合内的模组(复用 is_active 锁，与 build-patches 一致)。
# 幂等：目标已存在则覆盖(每次重新提取，保证新鲜)；无客户端内容时静默跳过。
#
# 实现说明：用 `for f in $(find ...)` 遍历(而非 find|while read)，原因有二：
#   1) 本机沙箱 wsl 的 read 从管道读恒空(已知环境怪病)，用 for 才能在本地端到端验证；
#   2) CI runner(Ubuntu) 同样可用，且本仓库模组路径不含空格，无分词风险。
# ============================================================================
set -uo pipefail

MODULES_DIR="${1:-modules}"
CLIENT_PATCHES_DIR="${2:-client-patches}"
MODULES_TXT="${3:-config/modules.txt}"

[ -d "$MODULES_DIR" ] || { echo "!! modules dir not found: $MODULES_DIR"; exit 1; }
mkdir -p "$CLIENT_PATCHES_DIR"

# 启用集合(modules.txt)：basename 去 .git，再去掉 -master 后缀(与 build-patches 一致)
active=()
while IFS= read -r url; do
  [ -z "$url" ] && continue
  case "$url" in \#*) continue;; esac
  m=$(basename "$url" .git); m=${m%-master}; active+=("$m")
done < "$MODULES_TXT"
is_active() { local n="$1"; for a in "${active[@]}"; do [ "$a" = "$n" ] && return 0; done; return 1; }

echo "== 提取客户端插件 / zhCN 数据 (modules -> client-patches) =="
found=0
for moddir in "$MODULES_DIR"/*/; do
  [ -d "$moddir" ] || continue
  name=$(basename "$moddir")
  is_active "$name" || { echo "  (跳过未启用模组: $name)"; continue; }

  dest="$CLIENT_PATCHES_DIR/$name"
  mkdir -p "$dest/Interface/addons" "$dest/data/zhcn"

  # 1) 客户端插件：找 *.toc，复制其所在目录树到 Interface/addons/<插件名>/
  for toc in $(find "$moddir" -type f -name '*.toc'); do
    [ -z "$toc" ] && continue
    addon_root=$(dirname "$toc")
    addon_name=$(basename "$addon_root")
    target="$dest/Interface/addons/$addon_name"
    rm -rf "$target"
    cp -r "$addon_root" "$target"
    echo "  [addon] $name -> client-patches/$name/Interface/addons/$addon_name"
    found=1
  done

  # 2) MPQ / 数据：*.mpq 以及 data/ 树 -> data/zhcn/<相对模组根的 path>
  #    剥掉模组自身 data/zhCN(data/zhcn)/data 前缀，避免双重嵌套。
  #    排除 .lua：服务端脚本(无 .toc)由 dockerfile 补丁收集进 lua_scripts，绝不可进客户端补丁。
  for f in $(find "$moddir" -type f \( -name '*.mpq' -o \( -path '*/data/*' ! -name '*.lua' \) \) ); do
    [ -z "$f" ] && continue
    rel=${f#"$moddir"}; rel=${rel#/}
    case "$rel" in
      data/zhCN/*) rel=${rel#data/zhCN/} ;;
      data/zhcn/*) rel=${rel#data/zhcn/} ;;
      data/*)      rel=${rel#data/} ;;
    esac
    target="$dest/data/zhcn/$rel"
    mkdir -p "$(dirname "$target")"
    cp -f "$f" "$target"
    echo "  [data]  $name -> client-patches/$name/data/zhcn/$rel"
    found=1
  done

  echo "  -- $name 提取完成"
done
[ "$found" = 0 ] && echo "  (无客户端插件/数据可提取)"
echo "== 客户端插件/数据提取完成 =="
