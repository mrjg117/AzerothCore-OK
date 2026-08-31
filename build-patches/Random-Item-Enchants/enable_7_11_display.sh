#!/usr/bin/env bash
# build-patch for Brytenwally/Random-Item-Enchants
# 目的：让 7-11 槽（RandomProperties 预留槽）在客户端 tooltip 真正显示。
#
# 根因（已读 ale + 核心源码实证）：
#   客户端仅在 ITEM_FIELD_RANDOM_PROPERTIES_ID != 0 时才渲染 7-11 槽。
#   原模组只调 item:SetEnchantment(id, 7..11)，从不设 randomPropertyId -> 闸关 -> 7-11 不显示（仅聊天播报）。
#   修复：在 SetEnchantment 循环前调 item:SetRandomProperty(GATE_ID) 开闸。
#
# ⚠️ 前置依赖（必须另做，本脚本无法替代）：
#   GATE_ID 必须是一条「空」RandomProperties.dbc 条目
#   （Enchantment[5] 全 0、name 空）。否则：
#     - 条目不存在 -> SetItemRandomProperties 查不到 -> 闸不开（本脚本 pcall 保护，不崩溃，仅不显示）；
#     - 条目是真实绿装属性 -> 会用其 Enchantment[5] 覆盖我们手写的 7-11 附魔，且给物品名加 "of the X" 后缀。
#   添加空条目的方法（任选其一，需 DBC 工具）：
#     a) 用 DBC 编辑器（如 WarTools / niya / wdbx）在 RandomProperties.dbc 加一行 id=GATE_ID，5 个 Enchantment 填 0，Name 留空；
#     b) 或改 RandomProperties.dbc 里一条永不使用的废条目为全 0 + GATE_ID。
#   完成 DBC 编辑后，本补丁即完整生效（7-11 在 tooltip 显示，且因条目为空、无后缀、不覆盖附魔）。
#
# 附：用户要求取消英文聊天播报 -> 注释 SendBroadcastMessage 行（零英文残留，tooltip 仍显示中文附魔名，因附魔走 spell_item_enchantment DBC 已自带 zhCN）。
set -euo pipefail

# 空 RandomProperties.dbc 条目 id（请与你的 DBC 编辑保持一致）
# ⚠️ 必须 ≤ 32767：item_instance.randomPropertyId 是 smallint（有符号，上限 32767），
# 此前用 900000 会触发 SQL [1264] Out of range、附魔存不进库。取 32000 留出余量且不冲突
# （真实 DBC id 范围约 5..2164）。
GATE_ID=32000

# 脚本由 CI 在 official/modules/Random-Item-Enchants 下执行（cwd = 模组根）
MOD_ROOT="$(pwd)"
LUA=""
for f in "$MOD_ROOT"/*.lua; do
  case "$(basename "$f")" in
    *Random*Enchant*) LUA="$f"; break ;;
  esac
done
if [ -z "$LUA" ] || [ ! -f "$LUA" ]; then
  echo "warn: Random Item Enchantments lua not found under $MOD_ROOT, skip"
  exit 0
fi
echo "patching lua: $LUA (GATE_ID=$GATE_ID)"

# 1) 开闸：在 SetEnchantment 循环前插入 SetRandomProperty（pcall 保护）
if ! grep -q "ACOK_GATE_RANDOM_PROP" "$LUA"; then
  python3 - "$LUA" "$GATE_ID" <<'PY'
import sys
p, gid = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
anchor = "    for i = 1, slotsToEnchant do"
inject = (
    "    -- [ACOK-PATCH] 开 7-11 显示闸：设 randomPropertyId(空 RandomProperties.dbc 条目) 让客户端渲染 7-11 槽\n"
    "    -- 前置：需 RandomProperties.dbc 存在 id=%s 的空条目(Enchantment[5]=0, name 空)，否则仅不显示、不崩溃\n"
    "    local acok_ok, acok_err = pcall(function() return item:SetRandomProperty(%s) end)\n"
    "    if not acok_ok then print(\"[InstantEnchants] gate SetRandomProperty failed (need empty RandomProperties.dbc id=%s): \" .. tostring(acok_err)) end\n"
    "    -- ACOK_GATE_RANDOM_PROP\n"
    "\n" % (gid, gid, gid)
)
if anchor in s and "ACOK_GATE_RANDOM_PROP" not in s:
    s = s.replace(anchor, inject + anchor, 1)
    open(p, "w", encoding="utf-8").write(s)
    print("patched gate-open into lua")
else:
    print("anchor not found or already patched; skip lua gate inject")
PY
fi

# 2) 取消英文聊天播报（用户要求）：注释 SendBroadcastMessage 行
if grep -q "player:SendBroadcastMessage" "$LUA"; then
  sed -i 's/^[[:space:]]*player:SendBroadcastMessage/-- player:SendBroadcastMessage/' "$LUA"
  echo "broadcast disabled"
fi

echo "== Random-Item-Enchants build-patch done =="
