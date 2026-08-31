#!/usr/bin/env bash
# 修复 mod-ale：放开 Lua 侧对 7-11（RandomProperties）附魔槽的写入限制。
#
# 根因（已读 mod-ale 源码 + Brytenwally/Random-Item-Enchants 模组 README 实证）：
#   ALE 的 item:SetEnchantment 绑定在槽内做硬校验：
#       EnchantmentSlot slot = (EnchantmentSlot)ALE::CHECKVAL<uint32>(L, 3);
#       if (slot >= MAX_INSPECTED_ENCHANTMENT_SLOT)   // =7
#           return luaL_argerror(L, 2, "valid EnchantmentSlot expected");
#   而模组要往 7-11（PROP_ENCHANTMENT_SLOT_0~4 = 7..11）写随机属性，全被这道校验挡死，
#   Lua 层报 "bad argument #1 to 'SetEnchantment' (valid EnchantmentSlot expected)"，
#   附魔一次都写不进去（实测 acok 账号 15 件物品槽 0-6 / 7-11 全 0）。
#   这是 ALE 绑定层限制（非核心；核心 EnchantmentSlot 枚举本身含 7-11），
#   纯 Lua / DBC 无法绕过，必须改 ALE 的 C++ 绑定。
#
# 修复：把该校验上限从 MAX_INSPECTED_ENCHANTMENT_SLOT(=7) 提到 MAX_ENCHANTMENT_SLOT(=12)，
#   正好等于核心 EnchantmentSlot 枚举的 MAX(=12)，从而允许写 0..11 全部槽位。
#   此改动逐字等同于模组作者提交给上游 ALE 的 PR #387
#   （https://github.com/azerothcore/mod-ale/pull/387，至今未合并；作者自家 fork 已含），
#   模组 Random-Item-Enchants 无需任何改动即可正常利用 7-11 闲置槽。
#
# 兼容性原则：本补丁只改这一处 ALE 绑定，官方仓库一个字不动；与你给
#   mod-challenge-modes / mod-junk-to-gold-plus / mod-playerbots-world-pvp 等打的补丁
#   是同一套"上层打补丁、不动官方本体"玩法。
#
# 幂等：仅当 2 行锚点（含 CHECKVAL<uint32>(L, 3)）仍存在 MAX_INSPECTED 时才替换；
#   替换后锚点不再匹配，重复执行是 no-op。找不到文件/锚点 → 告警并 exit 0（keep-going），
#   错误在 CI 日志暴露、不中断补丁链（真正的 gate 在编译步）。
# 约定：CI 已 cd 进 official/modules/mod-ale 后执行本脚本，直接改 src/。
set -euo pipefail

F="src/LuaEngine/methods/ItemMethods.h"
if [ ! -f "$F" ]; then
  echo "warn: $F not found under $(pwd), skip ALE prop-slot patch" >&2
  exit 0
fi

python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

# SetEnchantment 内的唯一锚点：CHECKVAL<uint32>(L, 3)（区别于另一处 CHECKVAL<uint32>(L, 2)）
anchor_old = (
    "        EnchantmentSlot slot = (EnchantmentSlot)ALE::CHECKVAL<uint32>(L, 3);\n"
    "        if (slot >= MAX_INSPECTED_ENCHANTMENT_SLOT)\n"
)
anchor_new = (
    "        EnchantmentSlot slot = (EnchantmentSlot)ALE::CHECKVAL<uint32>(L, 3);\n"
    "        if (slot >= MAX_ENCHANTMENT_SLOT)\n"
)

if anchor_old in s:
    s = s.replace(anchor_old, anchor_new, 1)
    open(p, "w", encoding="utf-8").write(s)
    print("patched: ALE SetEnchantment now allows slots 0..11 (MAX_ENCHANTMENT_SLOT)")
elif anchor_new in s:
    print("already patched (MAX_ENCHANTMENT_SLOT present in SetEnchantment), skip")
else:
    print("warn: SetEnchantment slot-check anchor not found in %s; ALE prop-slot NOT patched (upstream may have changed)" % p, file=sys.stderr)
PY
