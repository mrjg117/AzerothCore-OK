#!/usr/bin/env bash
set -e
# 官方 Dockerfile 的 runtime 阶段（L112 `FROM skeleton AS runtime`）只 COPY 了
# `env/dist/etc`，没有把 modules 带进运行时镜像；build 阶段（L77 `COPY modules
# /azerothcore/modules`）虽然拷了整个 modules，但 runtime/worldserver 阶段没有继承。
# 结果 worldserver 运行时镜像里不存在 /azerothcore/modules/mod-playerbots/data/sql，
# 启动 auto-populate `acore_playerbots` 库时找不到 base SQL 目录 ->
# `Directory .../mod-playerbots/data/sql/playerbots/base/ not exist` -> 库空 -> bot 系统失效
# （`.playerbots`/`co`/`initself`/`self` 全不可用，但 worldserver 不崩故 CI 仍显示绿）。
# 官方本地靠挂 `./modules` volume 补这个缺口；我们是烘焙镜像分发（无 volume），
# 所以在 worldserver 阶段从 build 阶段 COPY 进 data/sql（对齐官方机制，复用 auto-updater）。
# 改的是 clone 副本（官方流程之上的补丁），不动官方本体；本地构建不套本补丁时仍是官方原行为。
DF="apps/docker/Dockerfile"
if [ ! -f "$DF" ]; then
  echo "!! $DF not found, skip playerbots sql patch"
  exit 0
fi
if grep -q 'mod-playerbots/data/sql' "$DF"; then
  echo "playerbots data/sql already copied, skip"
  exit 0
fi
if grep -q '^ENV ACORE_COMPONENT=worldserver$' "$DF"; then
  sed -i '/^ENV ACORE_COMPONENT=worldserver$/a COPY --chown=$DOCKER_USER:$DOCKER_USER --from=build /azerothcore/modules/mod-playerbots/data/sql /azerothcore/modules/mod-playerbots/data/sql' "$DF"
  echo "patched: worldserver now COPYs mod-playerbots data/sql from build stage"
else
  echo "!! anchor 'ENV ACORE_COMPONENT=worldserver' not found (Dockerfile 可能已改), skip"
  exit 1
fi
