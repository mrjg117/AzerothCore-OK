#!/usr/bin/env bash
set -e
# 官方 Dockerfile 第 83 行用 `RUN --mount=type=cache,target=/ccache,sharing=locked` 做 ccache 缓存。
# 但 BuildKit 的 type=cache 挂载是匿名本地缓存，在 GitHub Actions 的全新 runner 上
# 每次 run 都不保留 -> ccache 永远冷启动 -> 2159 个 .o 每次全量重编（77 分钟）。
# 改成绑定到名为 ccache 的 build-context（由 CI 用 --build-context / additional_contexts
# 指向经 actions/cache 持久化的目录），让 ccache 跨 run 复用。
# 改的是 clone 副本（官方流程之上的补丁），不动官方本体。本地构建不套本补丁时仍是官方原挂载，无影响。
DF="apps/docker/Dockerfile"
if [ ! -f "$DF" ]; then
  echo "!! $DF not found, skip ccache patch"
  exit 0
fi
if grep -q 'type=cache,target=/ccache,sharing=locked' "$DF"; then
  sed -i 's#type=cache,target=/ccache,sharing=locked#type=bind,from=ccache,target=/ccache,rw#' "$DF"
  echo "patched: ccache mount -> type=bind,from=ccache (persisted via build-context)"
else
  echo "!! ccache mount line not found (Dockerfile 可能已改), skip"
fi
