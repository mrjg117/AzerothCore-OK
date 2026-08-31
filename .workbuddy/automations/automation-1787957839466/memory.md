# automation-1787957839466: cache-dance 生效复查

- 触发 run: 33218675109（workflow build-static-verify，headSha 91ec66e3，conclusion success，总时长 1h5m17s）
- 关键发现（最重要）：该 run 来自 build-static-verify.yml，仅用 actions/cache@v4 持久化 /home/runner/.cache/ccache，**完全不含 buildkit-cache-dance step**。
- 真正的 buildkit-cache-dance 写在 build-core.yml（含 reproducible-containers/buildkit-cache-dance@v3，映射 /home/runner/.cache/ccache ↔ 容器 /ccache）。但 build-core.yml 触发方式为 `on: workflow_dispatch:`（仅手动），**从未被触发**——仓库全部历史仅 2 次 run，均为 build-static-verify。
- 结论：cache-dance 效果“未验证/从未运行”，无法判定成败；本次 run 的 200B 空缓存是 build-static-verify 的 actions/cache（旧机制），不代表 cache-dance 失败。
- 缓存证据：Cache Size: ~0 MB (200 B)（line 378）；save 201B（line 8057）。无 cache-dance inject/extract 输出。
- 编译：2159/2159 全量完成，worldserver 链接成功（line 6055）；~52min 纯编译，无 ccache 命中证据 → 全量重编。
- 功能 gate：通过。acore_playerbots=30 表（line 7867），auth=23/characters=127/world=328（7868-7870）；结论“部署无错误”（7871）。无 ##[error]，无 build FAILED，无 worldserver 致命错误。
- 我方改动：dockerfile_ccache_persist.sh 守卫 OK（line 597 “ok: ...本补丁不改动 Dockerfile”）；build-core.yml cache-dance 已正确定义但未执行；additional_contexts 本 run 无报错。
- 下一步建议：手动 dispatch build-core.yml 验证 cache-dance（第二次 dispatch 看 Cache Size 是否变几十~几百 MB）；或走备选 A（CI 宿主 cmake+ccache）；结构性修复＝把 cache-dance 也搬进 build-static-verify.yml 使其 on-push 生效。
