#!/usr/bin/env bash
set -e
# ============================================================================
# 核心级补丁：把所有纯 Lua 模组（ALE 脚本）烘焙进 worldserver 运行时镜像。
#
# 根因（已读官方 apps/docker/Dockerfile + ALE 源码实证）：
#   官方 build 阶段 `COPY modules /azerothcore/modules` 只把模块带进镜像，
#   但 C++ 模组被编译进二进制，而「纯 Lua 模组」没有任何 C++ 可编译 —— 它的
#   逻辑全在 *.lua 里。本构建统一用 mod-ale（ALE；modules.txt 已显式排除
#   mod-eluna），ALE 在运行时只读 ALE.ScriptPath 目录（默认 "lua_scripts"，
#   相对 worldserver 的 cwd=/azerothcore → /azerothcore/lua_scripts）里的
#   *.lua，且 ALE 的加载器 GetScripts() 是**递归**的（子目录一并加载），
#   但 ALE 从不扫描 modules/ 目录。结果：所有纯 Lua 模组的脚本从未进入
#   worldserver 运行时镜像（Dockerfile 的 runtime/worldserver 阶段只 COPY 了
#   env/dist/etc，没有 modules 也没有 lua_scripts），worldserver 启动后不加载
#   任何 Lua 逻辑（Brytenwally 等全部失效，且不崩，CI 仍显示绿）。
#   这是「构建流程缺失」，不是 BUG、也不是没编译。
#
# 修复（与 dockerfile_playerbots_sql.sh 同范式，补丁打到官方 clone 副本，
# 不动官方本体；本地构建不套本补丁时仍是官方原行为）：
#   1) build 阶段：COPY modules 之后，把所有 modules 下的 *.lua 收集到
#      /azerothcore/lua_scripts（cd 进 modules 后用 cp --parents，保留模块
#      子目录，避免不同模组同名 .lua 互相覆盖）。
#      mkdir -p 兜底：即便 modules 下没有任何 .lua，目录也必建，避免步骤2 COPY 源 not found 整链失败。
#   2) worldserver 运行时阶段：从 build 阶段 COPY /azerothcore/lua_scripts 进
#      镜像 /azerothcore/lua_scripts。该路径正是 ALE 默认 ALE.ScriptPath
#      解析到的位置（cwd=/azerothcore），故 ALE 启动时自动递归加载全部模组
#      脚本。
#   3) worldserver 运行时阶段：ALE 默认 **关闭**（ALEConfig.cpp 中
#      ALE.Enabled 默认 "false"），必须往 worldserver.conf（含 .dist）写入
#      `ALE.Enabled = 1` + `ALE.ScriptPath = "/azerothcore/lua_scripts"` 才
#      真正加载脚本；否则步骤 1/2 收集的 lua 仍不加载（此前遗漏的关键一步）。
#
# 幂等：每段用唯一标记注释（ACOK_LUA_COLLECT / ACOK_LUA_COPY / ACOK_LUA_ALE_ENABLE）守卫，
# 重复执行不会重复插入。
# ============================================================================
DF="apps/docker/Dockerfile"
if [ ! -f "$DF" ]; then
  echo "!! $DF not found, skip lua_scripts patch"
  exit 0
fi

# --- 1) build 阶段：COPY modules 之后收集所有 *.lua ---
if grep -q 'ACOK_LUA_COLLECT' "$DF"; then
  echo "lua collect already patched, skip"
else
  if grep -qF 'COPY modules /azerothcore/modules' "$DF"; then
    python3 - "$DF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "COPY modules /azerothcore/modules\n"
inject = (
    "COPY modules /azerothcore/modules\n"
    'RUN mkdir -p /azerothcore/lua_scripts && cd /azerothcore/modules && find . -type f -name "*.lua" '
    '-exec cp --parents {} /azerothcore/lua_scripts/ \\;  # ACOK_LUA_COLLECT\n'
)
if anchor in s and "ACOK_LUA_COLLECT" not in s:
    s = s.replace(anchor, inject, 1)
    open(p, "w").write(s)
    print("patched: build stage collects all modules/*.lua -> /azerothcore/lua_scripts")
else:
    print("anchor not found or already patched; skip lua collect")
PY
  else
    echo "!! anchor 'COPY modules /azerothcore/modules' not found, skip lua collect"
  fi
fi

# --- 2) worldserver 运行时阶段：把 lua_scripts 拷进镜像 ---
if grep -q 'ACOK_LUA_COPY' "$DF"; then
  echo "lua copy already patched, skip"
else
  if grep -qF 'ENV ACORE_COMPONENT=worldserver' "$DF"; then
    python3 - "$DF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "ENV ACORE_COMPONENT=worldserver\n"
inject = (
    "ENV ACORE_COMPONENT=worldserver\n"
    "COPY --chown=$DOCKER_USER:$DOCKER_USER --from=build \\\n"
    "     /azerothcore/lua_scripts /azerothcore/lua_scripts  # ACOK_LUA_COPY\n"
)
if anchor in s and "ACOK_LUA_COPY" not in s:
    s = s.replace(anchor, inject, 1)
    open(p, "w").write(s)
    print("patched: worldserver stage copies lua_scripts into image")
else:
    print("anchor not found or already patched; skip lua copy")
PY
  else
    echo "!! anchor 'ENV ACORE_COMPONENT=worldserver' not found, skip lua copy"
  fi
fi

# --- 3) worldserver 运行时阶段：开启 ALE 引擎（默认关闭）+ 指定 ScriptPath ---
# 步骤 1/2 只把 *.lua 搬进镜像；但 ALE 引擎的 ALE.Enabled 默认 "false"（ALEConfig.cpp），
# 不显式开启则搬进去的 lua 一个都不加载，而镜像构建依旧显示绿 —— 这正是此前
# "构建流程缺失"的最后一环（也是最隐蔽的一环：文件都在，引擎没开）。
# 修正：往 worldserver.conf.dist 写入 ALE.Enabled = 1 + ALE.ScriptPath（指向步骤 2
# 拷入的 /azerothcore/lua_scripts），运行时由 entrypoint 把 ref/etc/*.dist 铺成
# dist/etc/*.conf，从而开箱即加载全部纯 Lua 模组。
# 遵循既有 CI debug 逻辑：找不到配置文件 → RUN 返回非 0 → 由构建 gate 暴露并停止
# （"继续执行时暴露错误、只在关键步骤停止"），绝不留"镜像绿但 ALE 关"的静默故障。
# 幂等：ACOK_LUA_ALE_ENABLE 标记守卫 + RUN 内 grep -qxF 重复追加保护。
if grep -q 'ACOK_LUA_ALE_ENABLE' "$DF"; then
  echo "ALE enable already patched, skip"
else
  if grep -qF 'ENV ACORE_COMPONENT=worldserver' "$DF"; then
    python3 - "$DF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "ENV ACORE_COMPONENT=worldserver\n"
inject = r'''ENV ACORE_COMPONENT=worldserver
# ACOK_LUA_ALE_ENABLE: ALE(Lua 引擎)已编译进 worldserver，但默认关闭
# (ALEConfig.cpp: ALE.Enabled 默认 "false")。不显式开启，步骤 1/2 收集的 lua 全不加载。
# 故在此开启引擎，并把 ScriptPath 指向烘焙进镜像的 /azerothcore/lua_scripts。
# 找不到配置文件就让 RUN 返回非 0 —— 由构建 gate 暴露并停止，避免"镜像绿但 ALE 关"。
# 幂等：grep -qxF 守卫，重复构建不重复追加。
RUN CONF=/azerothcore/env/ref/etc/worldserver.conf.dist; \
    if [ ! -f "$CONF" ]; then CONF=$(find /azerothcore/env -name 'worldserver.conf.dist' 2>/dev/null | head -1); fi; \
    if [ -z "$CONF" ]; then echo "!! ALE: worldserver.conf.dist not found, cannot enable ALE" >&2; exit 1; fi; \
    grep -qxF 'ALE.Enabled = 1' "$CONF" || echo 'ALE.Enabled = 1' >> "$CONF"; \
    grep -qxF 'ALE.ScriptPath = "/azerothcore/lua_scripts"' "$CONF" || echo 'ALE.ScriptPath = "/azerothcore/lua_scripts"' >> "$CONF"; \
    echo "ALE enabled in $CONF"
'''
if anchor in s and "ACOK_LUA_ALE_ENABLE" not in s:
    s = s.replace(anchor, inject, 1)
    open(p, "w").write(s)
    print("patched: worldserver stage enables ALE (ALE.Enabled=1) + ScriptPath")
else:
    print("anchor not found or already patched; skip ALE enable")
PY
  else
    echo "!! anchor 'ENV ACORE_COMPONENT=worldserver' not found, skip ALE enable"
  fi
fi

echo "== dockerfile_lua_scripts build-patch done =="
