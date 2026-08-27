# build-static-verify 工作流 — 注意事项备忘

> 配合 `.github/workflows/build-static-verify.yml` 使用。
> 新建**独立**工作流，不改动 `build-core.yml`。
> 本备忘记录流程模型、官方流程还原要点、已知坑、首跑前置、铁律。

## 0. 一句话定位
**纯官方流程搬到云**：把你在本地跑官方 Playerbot 部署那套，原样在 Actions 上跑一遍（clone 核心 → 挂模组+补丁 → `docker compose build` → `docker compose up -d` → grep 暴露错），全干净才冻库打包分发。
只叠加两件事：**暴露错误**（grep 部署日志）+ **打包分发**（docker save 本地镜像 + 冻库 + 配置 + 地图 → tarball 传外置存储）。**完全不破坏官方逻辑，不碰 ghcr。**

## 1. 流程模型（单 job，镜像本地复用，不跨 job 搬）
- 单 job `build-and-verify`，按官方顺序分步：
  1. Clone 官方核心 `mod-playerbots/azerothcore-wotlk` @`Playerbot`
  2. 挂 `config/modules.txt` 的 40 模组 + `apply build-patches/`（项目侧输入）
  3. 准备 etc 配置（叠仓库模组 conf，核心 conf 用官方默认）
  4. `docker compose build --profile tools`（官方编译；**跑完暴露全部错误，有错才停在打包前——不是出错马上停**）
  5. `docker compose up -d --no-build`（官方部署；**跑完暴露全部错误，有错才停在打包前——不是出错马上停**）
  6. grep 暴露 db-import / worldserver 错误（**全量扫、不早退、不 break，最后统一判定**）
  7. 全干净才 `docker compose stop` 冻库 + 打包 + 上传
- 段间"有错不进打包"：build/up 任一步非零退出 → 后续 `if: success()` 步全不跑（不冻库不打包），日志全暴露。**这是"步骤跑完它的正常流程后再判定停"，不是"一出错就掐断"**——用户原话："暴漏全部错误，彻底完成前一步停，不想再有错误的情况下完成"。
- 段内"收全错误"：编译门各服务独立 build，单服务遇错非零退出暴露该服务错误（注：官方 `cmake --build` 不带 `-k`，单服务内多个文件编译错只报第一个，是官方工具链行为，非本工作流截断）；部署门 grep 累计 FAIL、最后统一判定，worldserver 循环不 break、全量扫日志。

## 2. 不碰 ghcr（分发靠 tarball，不靠 registry）
- 砍掉历史上 login/push/pull ghcr 的全部逻辑。build 编译出的镜像留在本地 runner，deploy 用 `--no-build` 直接起；package 用 `docker save` 本地镜像打 tarball。
- 打包：`docker save` 5 主镜像(官方 tag `acore/ac-wotlk-{worldserver,authserver,db-import,tools}:master` + `mysql:8.4`) → 与 `etc.tar.zst`(配置模板,保留 __SOAP_*__ 占位符) + `ac-db-data.tar.zst`(冻库) 一并 `tar -I zstd` 成 `ac-bundle-latest.tar.zst`(+`.sha256`) → `.github/scripts/upload_artifacts.sh` 传外置储存（OneDrive 证书 / S3 凭证,有哪个传哪个）。
- 地图 `ac-maps-latest.tar.zst` = 从官方 `ac-client-data` 卷导出的 `data.tar.zst`（wowgaming/client-data 的 Data.zip 解压,非镜像）→ 单独传,不进大包（便于单独更新）。
- 用户机：下载两包 → 解大包得 `images.tar.zst`(docker load 出官方名镜像) + `etc.tar.zst` + `ac-db-data.tar.zst` → 解地图包 → `cp .env.example .env` 填真实 SOAP/IP/DB 密码 → `bash deploy/inject-config.sh` 替换占位符 → `docker compose -f docker-compose.bundle.yml up -d` = 满状态,免重导。

## 3. 一切用官方流程（完整还原,不偷改）
- **静态是官方默认**：官方 Dockerfile `ARG CMODULES="static"`（第 51 行），本工作流不覆盖、不传参。
- **官方标准流程** = `docker compose build` + `docker compose up -d`；`db-import` 是一次性 init 容器,随 `up` 自动跑、跑完即 `exited`；`ac-client-data-init` 按官方 `target: client-data` 从 wowgaming 拉地图填卷。本工作流完全照此,没替换官方 Dockerfile / compose / db-import。
- **已核实事实（2026-08-27）**：`mod-playerbots/azerothcore-wotlk` @`Playerbot` 根目录**无 `.gitmodules`** → 官方 clone **不需要 `--recursive`**（无 git submodule 依赖）；官方 Dockerfile 编译用 `cmake --build . --config "$CTYPE" -j $(($(nproc)+1))`（**不带 `-k`**），故单服务内编译错只报第一个是官方行为。
- **数据持久化走官方卷**：数据库卷、地图卷由官方 compose 声明；CI 测完即 `down -v` 拆卷。数据库在部署门干净后**冻进 bundle(方案B：冷拷 `/var/lib/mysql` 数据目录,见 §4.5)**,用户机解压进卷即满状态、免导——这是用户要求的「一个大包直接部署」交付形态,与官方"每次 up 重跑 db-import"不同,但官方流程仍用于云上构建+测试+抓错阶段。
- **动态 vs 静态**：SQL 处理两者等价(都靠 db-import 镜像携带 `modules/`)→ 选静态不影响 SQL 正确性。

## 4. 已知坑(错误暴露之所以要做,是因为官方流程会"带病成功")
R1–R5(已在 192.168.10.99 服务端**手工**修复,但**未固化进仓库**——本工作流的价值就是把这些再暴露出来、逼仓库修):
- **R1**：db-import 是 "sick-continue + exit 0",报错也当成功退出 → **必须 grep 它的日志**抓 `Unhandled / errno N / does not exist / Duplicate entry / truncated for column / Unexpected behaviour / ERROR N`,光看容器状态看不出。
- **R2**：mod-enhanced-worldchat 的 SQL 路径缺 `data/` 层 → 缺 `character_worldchat` 表。
- **R3**：mod-playerbots 独立 `acore_playerbots` 库的基础 SQL 标准 dbimport 不导 → 缺库。
- **R4**：base 只在首次跑 + db-import 被重复跑过 → up-to-date → 缺表永久留。
- **R5**：mod-item-affixes 版本漂移,`mythic_plus_level` 缺 `random_affix_count` 列。
- **worldserver 侧**：全量 grep 致命错误（`ABORT / Could not prepare / Table ... doesn't exist / Unknown column / Segmentation / SIGSEGV / FATAL / panic / refused to start / cannot (load|open) / failed to initialize` 等）。**不早退、不 break、循环扫全日志**；容器 running 只是前提，**必须日志无致命错误才判成功**（running 但内部崩不算过）。不强制 "WORLD Initialized" 关键字,避免误判。
- **关键**：deploy 验证步 `if: success()` 且**累计 FAIL、最后统一判定**,保证所有错误一次列全。

## 4.5 冻库(方案B)与用户机部署
- **冻库方式 = 方案B(冷拷数据目录)**：部署门干净后,`docker compose stop ac-database` 优雅停库 → `docker cp` 拷出 `/var/lib/mysql` 整个目录 → `tar -I zstd` 压成 `ac-db-data.tar.zst` → 并进大包。
- **为什么选 B 而非 A**：大包已含 `mysql:8.4` 镜像,用户机 MySQL 版本与云上完全一致,B 的「版本绑定」副作用被消除;用户机 load 后直接挂上即可,**零重导**。
- **大包内容**：`ac-bundle-latest.tar.zst` = 5 个镜像(worldserver/authserver/db-import/tools/mysql,官方 tag) 的 `docker save` tar + `etc.tar.zst`(配置模板) + `ac-db-data.tar.zst`(冻库);地图单独：`ac-maps-latest.tar.zst` = `data.tar.zst`(wowgaming/client-data 的 Data.zip 解压,非镜像)。
- **用户机部署步骤(极简,无 ghcr / 无 ac-maps / ac-extra-config 镜像)**：① 解 `ac-bundle-latest.tar.zst` → `docker load images.tar.zst` + 解 `etc.tar.zst`→`./env/dist/etc` + 解 `ac-db-data.tar.zst`→`./env/dist/mysql-data`；② 解 `ac-maps-latest.tar.zst`→`./env/dist/data`；③ `cp .env.example .env` 填真实 SOAP/IP/DB 密码；④ `bash deploy/inject-config.sh` 替换 `./env/dist/etc` 占位符；⑤ `docker compose -f docker-compose.bundle.yml up -d` = 满状态。db-import 仍随 `up` 跑(官方流程),库已完整→幂等空转。
- **偏离官方之处(用户明确要求)**：官方每次 `compose up` 都重跑 db-import 导数据;本流程改为「云上导一次、冻进包、用户机免导」。官方流程仍用于云上「构建+测试+验证」阶段(db-import 照跑、照抓错),只改了「交付物」形态。
- **体积预警**：大包(5主镜像+etc.tar.zst+冻库)可能 ~4–6GB;地图单独包 ac-maps ~3.24GB。两者分开传/下,地图可单独更新,属预期。

## 5. 首跑前置(必看,否则部署门直接挂)
- **配置/地图不再构建镜像**：`ac-extra-config` / `ac-maps` 镜像已废弃。配置 = 仓库 `config/extra-config/confs/` 叠加进 `./env/dist/etc`(核心 conf 用官方默认);地图 = 官方 `ac-client-data-init` 从 wowgaming 拉 (`target: client-data`),不 pull 外部镜像、不建自定义镜像。
- **云端测试不较真配置**:deploy-test 用占位值 `ci-test` 填 `.env` 的 `SOAP_LOGIN/PASSWORD`(只验部署链路);打包的 `etc.tar.zst` 保留仓库原始 `__SOAP_*__` 占位符,真实值在**用户机 `.env`** 提供,经 `deploy/inject-config.sh` 替换。CI 无需配 SOAP secrets。
- runner 磁盘:部署吃 18–21GB(含下载 ~3.24GB Data.zip + 编译 C++),建议加 `free_disk.sh` 腾空间;内存 worldserver ~8GiB + MySQL ~1GiB。
- 部署验证对"容器未起来 / worldserver 崩溃"也判 FAIL(避免假阴性漏报)。

## 6. 不要做的事(铁律)
- 不要改 `build-core.yml`(新建独立工作流)。
- 不要加 `do_publish` 之类的开关(打包应"全干净自动发生")。
- 不要替换官方 Dockerfile / compose / db-import(只在上面叠 grep 错误暴露)。**编译"暴漏全部错误"受官方 `cmake --build` 不带 `-k` 限制:单服务内多文件编译错只报第一个。若要在单服务内也全暴露,需 `build-patches/core/` 加补丁把 `cmake --build . ...` 改为带 `-k`(项目侧输入,不擅自改官方 Dockerfile,待用户确认再加)。**
- 不要碰 ghcr(分发靠 tarball,不靠 registry)。
- repo 改动(item-affixes 补列、worldchat 补 SQL、playerbots 补库)仍走"改吧/推吧",不在本工作流里偷偷改。

## 7. 触发与产物
- `workflow_dispatch` 手动触发(默认);schedule 段留了每日/每周/每月模板,按需解注释。
- 产物:`ac-bundle-latest.tar.zst`(大包:5 主镜像 + etc.tar.zst + 冻库) + `ac-maps-latest.tar.zst`(地图 data.tar.zst) 均传外置储存,不进 ghcr。
