#!/usr/bin/env bash
# 核心级补丁：让官方编译暴露全部错误（而非遇第一个错就中断）。
# 根因：官方 apps/docker/Dockerfile 用 `cmake --build . --config "$CTYPE" -j N`（不带 -k），
#       底层 make 遇首个编译错即退出，日志只报一个模组的错，其余 39 个模组编没编、错没错看不到。
# 修正：在 cmake --build 后追加 ` -- -k`，把 -k 透传给底层 make，使其遇错继续编译，暴露所有模组错误。
#       编译有错时 make 返回非 0，`&& cmake --install` 不执行，整个构建步失败 → 符合“跑完暴露全部、有错不打包”。
# 约定：workflow 已 cd 进 official（核心 clone 根，core 补丁 target=$PWD），故 Dockerfile 路径为 apps/docker/Dockerfile。
set -e
F="apps/docker/Dockerfile"
if [ ! -f "$F" ]; then echo "core keep-going: $F not found, skip" >&2; exit 0; fi
if grep -qF 'cmake --build . --config "$CTYPE" -j' "$F"; then
  if grep -qF -- '-- -k' "$F"; then
    echo "core keep-going: already patched, skip"
  else
    sed -i 's#cmake --build \. --config "$CTYPE" -j .* \\#cmake --build . --config "$CTYPE" -j $(($(nproc) + 1)) -- -k \\#' "$F"
    echo "core keep-going: patched -> make -k (expose all compile errors)"
    grep -n 'cmake --build' "$F"
  fi
else
  echo "core keep-going: cmake --build line not found, skip" >&2
fi
