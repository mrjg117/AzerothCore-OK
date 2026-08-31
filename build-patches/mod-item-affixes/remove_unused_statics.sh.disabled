#!/usr/bin/env bash
# 删除 ItemAffixScripts.cpp 中两个「本翻译单元内从未引用」的 static 常量，
# 消除 -Wunused-const-variable（行 263 SPELL_CELESTIAL_RESONANCE、行 372 SPELL_VANISHING_BACKSTAB_ID）。
#
# 安全性核证（已 grep 全模组确认）：
#   - 二者均为 static constexpr（内部链接），仅作用于本 .cpp；
#   - 同名常量在 Imprints/Priest/CelestialResonance.cpp 另有独立 static 定义并正常使用，
#     与本处互不影响；本处这两个声明在本 .cpp 内无任何引用点 → 确为死代码。
#   - 删除不改变任何运行时行为。
# 约定：workflow 已 cd 进 official/modules/mod-item-affixes 后执行本脚本，直接扫 src/。
set -e
if [ -f src/ItemAffixScripts.cpp ]; then
  sed -i '/static constexpr uint32 SPELL_CELESTIAL_RESONANCE  = 600002;/d' src/ItemAffixScripts.cpp
  sed -i '/static constexpr uint32 SPELL_VANISHING_BACKSTAB_ID = 600003;/d' src/ItemAffixScripts.cpp
  echo "mod-item-affixes: removed 2 unused static constexpr in ItemAffixScripts.cpp"
else
  echo "mod-item-affixes: src/ItemAffixScripts.cpp not found, skip" >&2
fi
