#!/usr/bin/env bash
set -e
# ccache 跨 run 持久化现由 buildx 负责（见 build-core.yml 的 --cache-to/from=type=local），
# 不再通过 build-context 只读挂载（旧方案 type=bind 写不回宿主，实测缓存键命中但内容空、复用失败）。
# 本脚本仅作为「官方 Dockerfile 仍使用 buildkit named cache mount」的守卫：
# 若官方把 ccache 挂载写法改掉，这里会告警，提示重新评估 ccache 持久化策略。
DF="apps/docker/Dockerfile"
if [ ! -f "$DF" ]; then
  echo "!! $DF not found, skip ccache guard"
  exit 0
fi
if grep -q 'type=cache,target=/ccache,sharing=locked' "$DF"; then
  echo "ok: 官方 ccache 仍用 buildkit named cache mount（由 buildx --cache-to/from=type=local 跨 run 持久化），本补丁不改动 Dockerfile"
else
  echo "!! 警告：官方 ccache 挂载写法已变（不再是 type=cache,target=/ccache,sharing=locked），需重新评估 build-core.yml 的 ccache 持久化方案"
fi
