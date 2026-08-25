#!/usr/bin/env bash
# 修复 TopHatMan/mod-playerbots-world-pvp 上游 SQL 写死作者库名 azc_world_ashbringer（模组级补丁，与现有 build-patches 补丁同机制）。
# 根因：模组 data/sql 两处第 1 行硬编码 USE azc_world_ashbringer;（作者自己服务器的 world 库名），
#       违反官方“模组 SQL 不写死库名”规范；db-import 已在 acore_world 上下文装配导入 -> ERROR 1049 Unknown database -> exit 1。
# 处置：删掉两处 data/sql 第 1 行的 USE azc_world_ashbringer;（db-import 已指定 -D acore_world，无需该 USE）。
# 约定：workflow 已 cd 进 official/modules/mod-playerbots-world-pvp 后执行本脚本。
set -e
for f in \
  data/sql/db-world/updates/2026_06_26_01_playerbot_world_pvp.sql \
  data/sql/manual/world_playerbot_world_pvp.sql; do
  if [ -f "$f" ]; then
    sed -i '/^USE azc_world_ashbringer;/d' "$f"
    echo "  patched: $f"
  else
    echo "  skip (not found): $f"
  fi
done
echo "world-pvp: removed hardcoded USE azc_world_ashbringer; (now relies on db-import -D acore_world)"
