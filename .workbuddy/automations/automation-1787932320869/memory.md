# 自动化执行记忆：build-static-verify run 33189529504 全量审查

- 触发时间：2026-08-29 01:48 (+08) / run 结束 2026-08-28 17:50:57Z
- 目标 run：33189529504（build-static-verify，commit 043959ea，标题 "ccache 跨 run 持久化改用 buildx local cache；功能 gate"），conclusion=**success**，总时长 ≈ 1h30m。
- 日志已落地 run33189529504.log（8050 行，分析后已清理临时脚本与日志）。

## 关键结论
1. **无 ##[error]、无 BUILD 失败、无 worldserver 致命错误**；gate 最终输出 "部署无错误（db-import 完成 + worldserver 运行中且无致命错误）"，FAIL=0 → 放行（未误拦）。
2. **我方改动全部成功 apply、无报错**：
   - dockerfile_ccache_persist.sh：ok（不改动 Dockerfile，ccache 仍用 buildkit named cache mount）。
   - dockerfile_playerbots_sql.sh：patched "worldserver now COPYs mod-playerbots data/sql"，且 #45 COPY 实际执行成功。
   - 泛型功能 gate（ea0e939）：动态检出 acore_playerbots（30 表）+ 核心三库，验证通过。
   - 冻库修复（ps -q --all）：`CID=$(docker compose ps -q --all ac-database)` 成功取到容器 ID，优雅停库后打出 ac-db-data.tar.zst 238M。
3. **库建表核验**（gate 运行时输出）：acore_playerbots=30、acore_auth=23、acore_characters=127、acore_world=328；首次空库已 auto-populate 完成，无 "not up to date"、无 data/sql base 缺失。
4. **编译慢根因 = ccache 仍 cold/miss，非"命中但仍慢"**：
   - actions/cache "Cache ccache" 还原 `Cache Size: ~0 MB (192 B)`（空），restore-key 命中上一次 commit；Post 阶段保存同样 ~192B。
   - 本次把 2159 个编译目标全量重编（16:23→17:42，约 80min），与 77min 基线基本持平。
   - 原因：actions/cache 持久化路径是 `/home/runner/.cache/ccache`，但容器内 ccache 实际写到 buildkit `type=cache,target=/ccache` 挂载，二者路径错位 → 持久化的永远是空缓存；buildx builder 在 job 末尾被 rm，/ccache 随之销毁，跨 run 不保留。注释声称的 "buildx --cache-to/from=type=local" 在本日志未见实际导出/导入 /ccache 的证据。
5. **非致命提示**：worldserver 启动有 `WarriorAdditions.Enable` 等 config missing property 黄色警告（非错误，不影响运行），来自 mod-warrior-additions 模块缺默认配置，非我方引入。

## 后续建议（供用户决策，未执行）
- 要让 ccache 真正跨 run 复用：要么把 ccache 目录显式指向被 actions/cache 持久化的路径（如 `-DCCACHE_DIR=/home/runner/.cache/ccache` 并在 Dockerfile 内使用该路径），要么在 `docker compose build` 真正加 `--cache-to=type=local,mode=max` / `--cache-from` 指向 /ccache 并持久化该 local cache 目录（再经 actions/cache 保存）。当前两种机制都未真正打通。

## 二次执行（2026-08-31 触发，审查 run 33289297078）
- 触发：本自动化原 schedule 2026-08-29，于 2026-08-31 09:41 +08 延迟触发。仓库最新 run = 33289297078（build-static-verify，commit "fix(build): 打包不带配置 + SQL路径归一化 + CI密码统一官方默认"，2026-08-30T03:01Z，23m17s，conclusion=**success**）。**无"半小时前"的 run**（最新即 ~22h 前）。
- 本 run 相对上轮重大变化：SQL 分发改为"通用归置引擎"（Normalize module SQL paths），另新增 Verify module SQL completeness（L1 声明级+L2 文件级对账）。

### 关键结论
1. **run success，全链路无 ##[error]、无 BUILD 失败、无 worldserver 致命错误**；Gate 输出"全链路无暴露错误，进入打包分发"→ 放行（未误拦）；冻库 240M + 5 镜像打包完成。
2. **我方改动全部成功 apply、零报错**：core 三脚本 dockerfile_ccache_persist.sh / dockerfile_playerbots_sql.sh / keep_going.sh 及多模组 patch/shell 均跑通，无 [ERR]/PATCH FAIL/SHELL FAIL/OVERLAY FAIL 真实触发；SQL 归置引擎"复制1/告警1/拒绝0"（黄色告警为 eluna-accountwide 清理非自建表，非错）；playerbots 库建 30 表正常（acore_playerbots=30、acore_auth=23、acore_characters=143、acore_world=328）；冻库修复 `ps -q --all` 取到 CID 成功导出 240M。
3. **编译慢根因已消除——本次很快**：Build core images 03:02:54→03:10:26 ≈ 7.5min（对比 80min 基线 ~10x 加速）。ccache 真正命中：actions/cache `Cache hit for restore-key: ccache-6c1a329...`、`Cache Size: ~462 MB`（真实内容，非上轮 192B 空缓存），buildkit-cache-dance 注入 /ccache；`== build 退出码 = 0 ==`、ac-authserver Built。用户"速度不快"的疑问针对的是上轮 33189529504（ccache 冷/空缓存），本 run 已修复。
4. **非致命**：Node.js 20 deprecated 警告（actions/cache/checkout/upload/buildx 被强制 Node24 跑），仅警告。

### 提示
- 本 run primary key `ccache-0481ab85...` 与还原 restore-key `ccache-6c1a329...` 不同 → 源码/编译指纹有变，命中上一次部分缓存（前缀匹配），仍大幅加速；若下轮源码大改命中率或降。Post Cache ccache 已回存（仅 DEP0169 弃用警告）。

## 三次执行（2026-08-31 09:47 +08 触发，重新拉全量日志 7579 行独立审查）
- 因无"半小时前"的 run（最新即 33289297078，~22h 前），本次仍审查 33289297078。`gh run list` 仅返回 2 条（最新 33289297078 / 33244052025），无新 run。
- 独立重拉 `run33289297078.log`（7579 行）并逐项 grep 验证，结论与二次执行完全一致，且补齐行号证据：ccache 还原 462MB（L374/L379/L382）、build 退出码 0（L6411）、编译 ~6.6min、四库表数（L7276–7279）、Gate 放行"全链路无暴露错误"（L7345/L7350）、冻库 240M（L7374）、bundle 2.2G + OneDrive 上传完成（L7452/L7493/L7498）。全日志 `[ERR]`/FAIL=1 实际触发 0 条。
- 交付：`run33289297078_full_audit.md`（先结论后细节 + 证据行）。
