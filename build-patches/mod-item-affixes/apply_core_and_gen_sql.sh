#!/usr/bin/env bash
# build-patch for mod-item-affixes (Nevaden/mod-item-affixes)
#
# 在「官方流程之上」补该模组非标准安装步骤（官方流程不动、不碰官方文件）：
#   1) 规范化模组自带 pwsh 脚本里的反斜杠路径为斜杠
#      —— 模组脚本作者按 Windows 写死 `src\server\...` / `data\sql\db-world\...`，
#         Linux 上 pwsh 不把 `\` 当路径分隔符 → Test-Path / WriteAllText 找不到文件。
#         改的是 CI 里我们自己的模组 clone，不碰官方仓库。
#   2) 给 AzerothCore 核心 clone 打 9 处补丁（scripts/apply_core_patches.ps1）
#      —— 默认 AzerothCoreRoot = scripts/ 三级上 = official 根；workflow 已 cd 进模组目录，无需手传。
#   3) 从 JSON 重新生成 affix_template.sql + talent_affix_def.sql
#      —— 这两张核心表的 CREATE 由 build_affixes.ps1 / build_talent_affixes.ps1 现生成，
#         仓库只提交了 affix_spec_tree_*.sql（UPDATE affix_template）和 imprints/，从不提交 CREATE。
#   4) 把生成文件改名 000_ 前缀，保证 CREATE 先于已提交的 affix_spec_tree_*.sql（UPDATE）执行
#      —— db-import 按字母序灌模组 SQL：affix_spec_tree_*（a-f-f-i-x-_s）原本排在 affix_template.sql
#        （a-f-f-i-x-_t）之前，会先 UPDATE 一个还没建的表 → ERROR 1146。000_ 前缀使 CREATE 最先。
#
# 执行时机：workflow「Mount modules + apply build-patches」步，在 docker compose build 之前。
# 生成的 SQL 落在 official/modules/mod-item-affixes/data/sql/db-world/，被 db-import 镜像烘焙进去，
# 部署（db-import 容器）时自动灌入 world DB —— 不需要任何自定义灌库步骤。
# SQL 内容随 JSON 变化而变；db-import 的 UpdateFetcher 用 SHA1 哈希比对，内容变即重灌（持久化 DB 场景）。
#
# 约定：workflow 已 cd 进 official/modules/mod-item-affixes 后执行本脚本（cwd = 模组根）。

set -euo pipefail

# 模组根（不依赖调用方 cwd，按脚本自身位置推导）
MODROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$MODROOT"

echo "== mod-item-affixes build-patch (MODROOT=$MODROOT) =="

# 0) 定位 pwsh（GitHub-hosted ubuntu runner 预装 pwsh 7）
if command -v pwsh >/dev/null 2>&1; then
  PWSH=pwsh
elif command -v powershell >/dev/null 2>&1; then
  PWSH=powershell
else
  echo "!! pwsh/powershell not found on PATH" >&2
  exit 1
fi
echo "using shell: $PWSH"

# 1) 规范化反斜杠 -> 斜杠（仅作用我们 clone 里的模组脚本，不动官方仓库）
for f in scripts/apply_core_patches.ps1 scripts/build_affixes.ps1 scripts/build_talent_affixes.ps1; do
  if [ -f "$f" ]; then
    sed -i 's/\\/\//g' "$f"
    echo "normalized backslashes: $f"
  else
    echo "warn: $f not found, skip normalization" >&2
  fi
done

# 2) 给核心 clone 打 9 处补丁（默认 root = ../../../ from scripts = official 根）
echo "== applying core patches to AzerothCore =="
"$PWSH" scripts/apply_core_patches.ps1

# 3) 从 JSON 生成两张核心表的 SQL
echo "== generating affix_template.sql =="
"$PWSH" scripts/build_affixes.ps1
echo "== generating talent_affix_def.sql =="
"$PWSH" scripts/build_talent_affixes.ps1

# 4) 改名 000_ 前缀，保证 CREATE 先于已提交 UPDATE（字母序加载）
SQLDIR="data/sql/db-world"
if [ -d "$SQLDIR" ]; then
  for f in affix_template.sql talent_affix_def.sql; do
    if [ -f "$SQLDIR/$f" ]; then
      mv "$SQLDIR/$f" "$SQLDIR/000_$f"
      echo "prefixed for load order: $SQLDIR/000_$f"
    else
      echo "!! $SQLDIR/$f not generated — build_*.ps1 may have failed" >&2
      exit 1
    fi
  done
else
  echo "!! $SQLDIR not found — module layout unexpected" >&2
  exit 1
fi

echo "== mod-item-affixes build-patch done =="
