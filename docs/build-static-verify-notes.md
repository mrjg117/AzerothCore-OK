# build-static-verify 工作流 — 注意事项备忘

> 配合 `.github/workflows/build-static-verify.yml` 使用。
> 新建**独立**工作流，不改动 `build-core.yml`。
> 本备忘记录门控模型、复用关系、官方流程还原要点、已知坑、首跑前置、铁律。

## 0. 一句话定位
核心 + 40 模块整体静态云编译 → 云端真起全栈跑一遍（导 SQL / 挂地图 / 注入真实配置）→ 干净才打包分发。
**编译坏就停在编译、部署坏就停在部署、两门都干净才打包**；段与段之间"错就停"，但**每一段内部把该段能报的错都一次性报全**（不遇首错即退）。

## 1. 门控模型（最关键，别再改反）
- 三段：`build`（编译门）→ `deploy-test`（部署门）→ `package`（打包门）。
- `deploy-test` 用 `needs: build` —— **编译失败 → 部署门被自动跳过**（没镜像可测，硬测没意义）。
- `package` 用 `needs: [build, deploy-test]` —— **两门都成功才打包**。
- 这就是「编译出错编译完成前停查一遍错 → 再测部署 → 部署出错再查部署 → 都干净才完成打包」。
- 段间"错就停"；段内"收全错误"：编译门遇任一错即非零退出暴露该错；部署门 grep 累计 FAIL 标志、最后统一判定，不中途退。

## 2. 参照以前（复用 build-core.yml，不另起炉灶）
build 与 package 两阶段直接搬 `build-core.yml` 的真实步：
- **编译**：`clone Playerbot fork @Playerbot` → 按 `config/modules.txt` 拉 40 模块（去 `-master` 后缀）→ `Apply build-patches`（沿用现有约定：`*.patch` 走 `git apply`，失败回退 `patch -p1`；`*.sh` 在目标目录执行；`overlay/` 整目录覆盖）→ `docker buildx ... --target <t> -f apps/docker/Dockerfile --build-arg CMODULES=static --push`（worldserver/authserver/db-import/tools 四 target）→ 拉 `mysql:8.4` 打 tag 推 `ac-wotlk-mysql`。
- **打包**：`docker save` 七个镜像 → 与 `ac-db-data.tar.zst`(冻好的数据库) 一并 `tar -I zstd` 成 `ac-bundle-latest.tar.zst`(+`.sha256`) → `.github/scripts/upload_artifacts.sh` 传外置储存（OneDrive 证书 / S3 凭证，有哪个传哪个）→ 设 ghcr 公开 → prune 保留最新 12 版。
- **一个大包（用户明确要求「不另拉」）**：bundle = 五个主镜像(worldserver/authserver/db-import/tools/mysql) + 地图(ac-maps) + 配置(ac-extra-config) + 冻好的数据库(`ac-db-data.tar.zst`)。用户机下载后 `docker load` + 解压数据库进卷 + `compose up` = 满状态，不另拉镜像、不重导数据。

## 3. 一切用官方流程（尽量完整还原，不偷改）
- **静态是官方默认**：`config.cmake` 里 `set(MODULES "static")` 即官方默认；官方 Dockerfile `ARG CMODULES="static"`。动态需补 `COPY --from=build .../*.so`，反而要改官方 Dockerfile → 选静态。
- **官方标准流程** = `docker compose build` + `docker compose up -d`；`db-import` 是**一次性 init 容器**，随 `up` 自动跑、跑完即 `exited`。本工作流完全照此，没替换官方 Dockerfile / compose / db-import。
- **数据持久化走官方卷**：数据库卷、地图卷由官方 compose 声明；CI 里测完即 `down -v` 拆掉，**不把数据库冻结进镜像/bundle**（避免"缺功能 / 没法持久化"的坑）。用户机首次 `docker load && compose up` 时 db-import 会再跑一次——那也是官方流程的一部分。
- **动态 vs 静态**：SQL 处理两者等价（都靠 db-import 镜像携带 `modules/`）→ 选静态不影响 SQL 正确性。

## 4. 已知坑（错误暴露之所以要做，是因为官方流程会"带病成功"）
R1–R5（已在 192.168.10.99 服务端**手工**修复，但**未固化进仓库**——本工作流的价值就是把这些再暴露出来、逼仓库修）：
- **R1**：db-import 是 "sick-continue + exit 0"，报错也当成功退出 → **必须 grep 它的日志**抓 `Unhandled / errno N / does not exist / Duplicate entry / truncated for column / Unexpected behaviour / ERROR N`，光看容器状态看不出。
- **R2**：mod-enhanced-worldchat 的 SQL 路径缺 `data/` 层 → 缺 `character_worldchat` 表。
- **R3**：mod-playerbots 独立 `acore_playerbots` 库的基础 SQL 标准 dbimport 不导 → 缺库。
- **R4**：base 只在首次跑 + db-import 被重复跑过 → up-to-date → 缺表永久留。
- **R5**：mod-item-affixes 版本漂移，`mythic_plus_level` 缺 `random_affix_count` 列。
- **worldserver 侧**：`ABORT / Could not prepare / Table ... doesn't exist / Unknown column / WORLD NOT Initialized` 也要 grep。
- **关键**：deploy-test 的 grep 步骤 `if: always()` 且**累计 FAIL、最后统一判定**，保证所有错误一次列全。

## 4.5 冻库（方案B）与用户机部署（本次新增）
- **冻库方式 = 方案B（冷拷数据目录）**：部署门干净后，`docker compose stop ac-database` 优雅停库 → `docker cp` 拷出 `/var/lib/mysql` 整个目录 → `tar -I zstd` 压成 `ac-db-data.tar.zst` → 作为 artifact 传给 package 并进大包。
- **为什么选 B 而非 A**：大包已含 `ac-wotlk-mysql:8.4` 镜像，用户机 MySQL 版本与云上完全一致，B 的「版本绑定」副作用被消除；用户机 load 后直接挂上即可，**零重导**（A 还需多一条还原命令）。若日后用户换 MySQL 大版本，再退回 A（mysqldump）兜底。
- **大包内容**：`ac-bundle-latest.tar.zst` = 7 个镜像(worldserver/authserver/db-import/tools/mysql/ac-maps/ac-extra-config) 的 `docker save` tar + `ac-db-data.tar.zst`。
- **用户机部署步骤（极简）**：① `docker load` 大包里的 images.tar；② 把 `ac-db-data.tar.zst` 解压进 mysql 数据卷（**解压≠重导**，秒级，不跑 SQL）；③ `compose up`。db-import 检测到库已存在会自动跳过，不重复导。
- **偏离官方之处（用户明确要求）**：官方每次 `compose up` 都重跑 db-import 导数据；本流程改为「云上导一次、冻进包、用户机免导」。官方流程仍用于云上「构建+测试+验证」阶段（db-import 照跑、照抓错），只改了「交付物」形态。
- **体积预警**：ac-maps 约 3.24GB + 数据库若干 GB，大包可能 7–9GB，上传/下载耗时，属预期。

## 5. 首跑前置（必看，否则部署门直接挂）
- 镜像仓库先有 `ac-maps:latest`（先跑一次 `build-maps.yml`）和 `ac-extra-config:latest`，否则 `compose up` 拉不到、部署门挂。
- CI 里配 `SOAP_LOGIN` / `SOAP_PASSWORD` secrets（realm 真实账号）。
- runner 磁盘：部署吃 18–21GB，建议加 `free_disk.sh` 腾空间；内存 worldserver ~8GiB + MySQL ~1GiB。
- 部署门对"镜像缺失 / 容器未起来"也判 FAIL（拉镜像失败即 exit 1；db-import 未在超时内 exited、worldserver 未初始化且未捕获崩溃也判 FAIL），避免假阴性漏报。

## 6. 不要做的事（铁律）
- 不要改 `build-core.yml`（新建独立工作流）。
- 不要加 `do_publish` 之类的开关（用户明确反对"彻底停"；打包应"两门干净自动发生"）。
- 不要替换官方 Dockerfile / compose / db-import（只在上面叠 grep 错误暴露）。
- repo 改动（item-affixes 补列、worldchat 补 SQL、playerbots 补库）仍走"改吧/推吧"，不在本工作流里偷偷改。

## 7. 触发与产物
- `workflow_dispatch` 手动触发（默认）；schedule 段留了每日/每周/每月模板，按需解注释。
- 产物：`ac-bundle-latest.tar.zst`（+ `.sha256`）传外置储存，ghcr 五个包设公开，保留最新 12 版。
