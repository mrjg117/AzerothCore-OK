# build-static-verify 工作流 — 注意事项备忘

> 配合 `.github/workflows/build-static-verify.yml` 使用。
> 新建**独立**工作流，不改动 `build-core.yml`。
> 本备忘记录流程模型、官方流程还原要点、已知坑、首跑前置、铁律。

## 0. 一句话定位
**纯官方流程搬到云**：把你在本地跑官方 Playerbot 部署那套，原样在 Actions 上跑一遍（clone 核心 → 挂模组+补丁 → `docker compose build` → `docker compose up -d` → grep 暴露错），全干净才冻库打包分发。
只叠加两件事：**暴露错误**（grep 部署日志）+ **打包分发**（docker save 本地镜像 + 冻库 + 地图 → tarball 传外置存储；**配置不打进包，用户机走官方默认**）。**完全不破坏官方逻辑，不碰 ghcr。**

## 1. 流程模型（单 job，镜像本地复用，不跨 job 搬）
- 单 job `build-and-verify`，按官方顺序分步：
  1. Clone 官方核心 `mod-playerbots/azerothcore-wotlk` @`Playerbot`
  2. 挂 `config/modules.txt` 的 40 模组 + `apply build-patches/`（项目侧输入）
  3. 准备 etc 配置（**仅 CI 测试用**：叠仓库模组 conf 验能否起，核心 conf 用官方默认；本步产物不进包）
  4. `docker compose --profile tools build`（官方编译；**跑完暴露全部错误，有错才停在打包前——不是出错马上停**。`--profile tools` 是 compose v2 全局 flag，必须放 `docker compose` 后、`build` 前）
  5. `docker compose up -d --no-build`（官方部署；**跑完暴露全部错误，有错才停在打包前——不是出错马上停**）
  6. grep 暴露 db-import / worldserver 错误（**全量扫、不早退、不 break，最后统一判定**）
  7. 全干净才 `docker compose stop` 冻库 + 打包 + 上传
- 段间"有错不进打包"：build/up 任一步非零退出 → 后续 `if: success()` 步全不跑（不冻库不打包），日志全暴露。**这是"步骤跑完它的正常流程后再判定停"，不是"一出错就掐断"**——用户原话："暴漏全部错误，彻底完成前一步停，不想再有错误的情况下完成"。
- 段内"收全错误"：编译门各服务独立 build，且 core build-patch(keep_going.sh) 已给 `cmake --build` 加 `-- -k 0` 透传 ninja（官方 Dockerfile 用 Ninja 生成器，`-k` 必须带数字 `0`=无限继续，空 `-k` 会报 `option requires an argument`），单服务内遇错继续编译、暴露全部模组错误（未加补丁前官方不带 -k 只报第一个）；部署门 grep 累计 FAIL、最后统一判定，worldserver 循环不 break、全量扫日志。

## 2. 不碰 ghcr（分发靠 tarball，不靠 registry）
- 砍掉历史上 login/push/pull ghcr 的全部逻辑。build 编译出的镜像留在本地 runner，deploy 用 `--no-build` 直接起；package 用 `docker save` 本地镜像打 tarball。
- 打包：`docker save` 5 主镜像(官方 tag `acore/ac-wotlk-{worldserver,authserver,db-import,tools}:master` + `mysql:8.4`) + `ac-db-data.tar.zst`(冻库) 一并 `tar -I zstd` 成 `ac-bundle-latest.tar.zst`(+`.sha256`) → `.github/scripts/upload_artifacts.sh` 传外置储存（OneDrive 证书 / S3 凭证,有哪个传哪个）。**配置不打进包**（核心+模组 conf 均不随包），用户机解包后由官方 entrypoint 从 `.dist` 生成完整默认核心 conf、模组缺失键回退 C++ 默认。
- 地图 `ac-maps-latest.tar.zst` = 从官方 `ac-client-data` 卷导出的 `data.tar.zst`（wowgaming/client-data 的 Data.zip 解压,非镜像）→ 单独传,不进大包（便于单独更新）。
- 用户机：下载两包 → 解大包得 `images.tar.zst`(docker load 出官方名镜像) + `ac-db-data.tar.zst` → 解地图包 → 直接 `docker compose -f docker-compose.bundle.yml up -d`：官方 entrypoint 从 `.dist` 生成完整默认核心 conf、模组回退 C++ 默认 = 满状态、免重导。**如需定制（如 SOAP），由用户机部署脚本追写配置到官方默认 conf（inject 改 append 模式，待定），不污染默认基线。**

## 3. 一切用官方流程（完整还原,不偷改）
- **静态是官方默认**：官方 Dockerfile `ARG CMODULES="static"`（第 51 行），本工作流不覆盖、不传参。
- **官方标准流程** = `docker compose build` + `docker compose up -d`；`db-import` 是一次性 init 容器,随 `up` 自动跑、跑完即 `exited`；`ac-client-data-init` 按官方 `target: client-data` 从 wowgaming 拉地图填卷。本工作流完全照此,没替换官方 Dockerfile / compose / db-import。
- **已核实事实（2026-08-27）**：`mod-playerbots/azerothcore-wotlk` @`Playerbot` 根目录**无 `.gitmodules`** → 官方 clone **不需要 `--recursive`**（无 git submodule 依赖）；官方 Dockerfile 编译用 `cmake --build . --config "$CTYPE" -j $(($(nproc)+1))`（**不带 `-k`**），故单服务内编译错只报第一个是官方行为——此限制已由 `build-patches/core/keep_going.sh` 加 `-- -k 0`（ninja 透传）补丁消除。
- **数据持久化走官方卷**：数据库卷、地图卷由官方 compose 声明；CI 测完即 `down -v` 拆卷。数据库在部署门干净后**冻进 bundle(方案B：冷拷 `/var/lib/mysql` 数据目录,见 §4.5)**,用户机解压进卷即满状态、免导——这是用户要求的「一个大包直接部署」交付形态,与官方"每次 up 重跑 db-import"不同,但官方流程仍用于云上构建+测试+抓错阶段。
- **动态 vs 静态**：SQL 处理两者等价(都靠 db-import 镜像携带 `modules/`)→ 选静态不影响 SQL 正确性。

## 4. 已知坑(错误暴露之所以要做,是因为官方流程会"带病成功")
R1–R5(已在 192.168.10.99 服务端**手工**修复,但**未固化进仓库**——本工作流的价值就是把这些再暴露出来、逼仓库修):
- **R1**：db-import 是 "sick-continue + exit 0",报错也当成功退出 → **必须 grep 它的日志**抓 `Unhandled / errno N / does not exist / Duplicate entry / truncated for column / Unexpected behaviour / ERROR N`,光看容器状态看不出。
- **R2**：mod-enhanced-worldchat 的 SQL 路径缺 `data/` 层 → 缺 `character_worldchat` 表。
- **R3**：mod-playerbots 独立 `acore_playerbots` 库的基础 SQL 标准 dbimport 不导 → 缺库。
- **R4**：base 只在首次跑 + db-import 被重复跑过 → up-to-date → 缺表永久留。
- **R5（已确认·2026-08-28 #11）**：`mod-item-affixes` 在 db-import 阶段报 `ERROR 1146 (42S02) Table 'acore_world.affix_template' doesn't exist`（`affix_spec_tree_*.sql` 是 `UPDATE affix_template`，表此刻不存在）。**根因不是模组残缺/可删**：该模组有非标准安装流程——(1) 需 `apply_core_patches.ps1` **改 AzerothCore 核心源码**；(2) 其 `affix_template` 表由安装后脚本 `2-load-data`（`build_affixes.ps1` 从 JSON 生成 `affix_template.sql`）导入 world DB，**不放在 `data/sql/db-world/` 让 AC 标准 db-import 自动建**。故纯官方自动导入机制满足不了，db-import 阶段表尚未建 → UPDATE 失败。这是**模组选型/兼容性问题**，非流程 bug、非模组坏了。**重要纠正**：本人曾未经允许擅自将该模组从 `config/modules.txt` 删除并 push（违反铁律、越界），已 `git checkout 8345b6b -- config/modules.txt` 还原、模组已回到清单。**决策（2026-08-28 用户拍板）**：保留模组，走「模组补丁」修——新增 `build-patches/mod-item-affixes/apply_core_and_gen_sql.sh`，在 docker compose build 前于 host 侧：(a) 规范化模组 pwsh 脚本反斜杠路径；(b) 给核心 clone 打 9 处 core-patch；(c) 从 JSON 现生成 `affix_template.sql`+`talent_affix_def.sql` 落进模组 `data/sql/db-world/`；(d) 改名 `000_` 前缀保证 CREATE 先于已提交的 `affix_spec_tree_*.sql`（UPDATE）。SQL 随 build 烘焙进 db-import 镜像，部署（db-import 容器）时自动灌入 → 解决 R5。详见 R9。
- **worldserver 侧**：全量 grep 致命错误（`ABORT / Could not prepare / Table ... doesn't exist / Unknown column / Segmentation / SIGSEGV / FATAL / panic / refused to start / cannot (load|open) / failed to initialize` 等）。**不早退、不 break、循环扫全日志**；容器 running 只是前提，**必须日志无致命错误才判成功**（running 但内部崩不算过）。不强制 "WORLD Initialized" 关键字,避免误判。
- **关键**：deploy 验证步 `if: success()` 且**累计 FAIL、最后统一判定**,保证所有错误一次列全。
- **R6（2026-08-28 暴露的设计坑）**：`docker compose up -d` 因依赖服务（db-import）退出非零会返回非 0，若 step 9 用 `set -e` 会整步 abort，导致 step 10（抓容器日志、扫描致命错误）被 `if: success()` 跳过——**db-import 内部真正的 SQL 报错看不到**。修复：step 9 用 `docker compose up -d --no-build || echo ...` 接住非零返回、不让整步 aborted；step 10 **去掉 `if: success()` 始终执行**，先 `docker inspect` 取 `ac-db-import` 真实 exit code + `cat` 打印其**完整日志** + 宽 grep 错误关键字，db-import 失败即立即判停（worldserver 依赖它不会起、不必空等）；仅 db-import 干净才继续 worldserver 检查。这样部署错真正全暴露。

- **R7（2026-08-28 暴露的官方 bind-mount 权限坑）**：`ac-db-import`/`worldserver`/`authserver` 把 host 的 `./env/dist/etc` + `./env/dist/logs` **bind 挂载**进容器，容器以 `acore`(uid 1000, Dockerfile `USER $DOCKER_USER` 默认 acore)跑。CI 里 Docker 守护进程是 root，自动创建的 bind 目录是 **root 所有** → acore 写不进 → 官方 entrypoint `cp -rnv` 失败(`set -e`)→ 容器 exit 1。这**不是我们引入的**，是官方 Docker 已知坑（官方 entrypoint 警告原文即写 `sudo chown -R 1000:1000 ./env/dist/etc ./env/dist/logs` 或 `DOCKER_USER=root`）。官方本地流能跑是因为用户自己 chown 过 host 目录。修复（纯项目侧 CI 步骤，不改任何官方文件）：在 `docker compose up` 前 `mkdir -p env/dist/etc env/dist/logs && chown -R 1000:1000 env/dist`(runner 非 root 时用 `sudo`)，复刻官方本地前置条件。注意 compose 无 `user:` 字段、`DOCKER_USER` 仅是 build arg，故 `DOCKER_USER=root` 在 `--no-build` 的 `up` 下不生效——必须用 chown 方案。

- **R8（2026-08-28 #11 后开启编译缓存）**：GitHub 托管 runner 是一次性 VM，本地 Docker 层缓存不跨运行保留 → 每次 `docker compose build` 冷启动全重编(~77 分钟)。开启方案：项目侧新增 `docker-compose.override.yml`(仅给 5 个 build 服务加 `build.cache_from/to: type=gha`,不改任何官方文件),CI 在 `docker compose build` 前 `cp` 进 `official/` 自动合并。GHA 缓存(`type=gha`)在构建过程中逐层导出,**部分成功也存**(中途失败的前序层保留),且**内容寻址**——模组/源码变了对应层自动 miss 重编,不掩盖编译/部署错误。首次带缓存的本次仍全编(冷缓存)但会存层供下次复用;要强刷整段缓存改 override 里的 cache key 前缀或 GitHub UI(Settings→Actions→Caches)删条目。

- **R9（2026-08-28 解决 R5：mod-item-affixes 模组补丁）**：R5 的 `affix_template doesn't exist` 根因 = 该模组非标准安装（需 core-patch + 从 JSON 生成 CREATE 表 SQL），纯官方自动导入满足不了。修复 = `build-patches/mod-item-affixes/apply_core_and_gen_sql.sh`（workflow「Mount modules + apply build-patches」步在 `docker compose build` 前、host 侧执行，cwd=模组目录）：
  1. **反斜杠规范化**：模组自带 `scripts/*.ps1` 写死 Windows 反斜杠路径（`src\server\...`、`data\sql\db-world\...`），Linux pwsh 不把 `\` 当分隔符 → 找不到文件。**改的是 CI 里我们自己的模组 clone，不碰官方仓库**。
  2. **core-patch**：`pwsh scripts/apply_core_patches.ps1`（默认 `AzerothCoreRoot = scripts/ 三级上 = official 根`）给核心 clone 打 9 处补丁，幂等（detect 标记 skip 已应用的）。
  3. **生成 SQL**：`pwsh scripts/build_affixes.ps1` 读 `affixes/*.json`+`class_affixes/*.json` → 生成 `data/sql/db-world/affix_template.sql`（CREATE `affix_template`+`spell_swap_chain_spells`+INSERT）；`pwsh scripts/build_talent_affixes.ps1` 读 `talent_affixes/*.json` → 生成 `talent_affix_def.sql`（CREATE+INSERT）。仓库只提交了 `affix_spec_tree_*.sql`（UPDATE `affix_template`）和 `imprints/`，**从不提交这两个 CREATE**，故生成是必需的。
  4. **加载顺序（关键）**：db-import 按字母序灌模组 SQL，`affix_spec_tree_*`（a-f-f-i-x-_**s**）原本排在 `affix_template.sql`（a-f-f-i-x-_**t**）**之前** → 先 UPDATE 未建的表 → ERROR 1146。故生成后把两文件改名 `000_affix_template.sql` / `000_talent_affix_def.sql`，`0`<`a` 保证 CREATE 最先。
  - **为什么不需要自定义灌库步骤**：生成的 SQL 落在 `official/modules/mod-item-affixes/data/sql/db-world/` → `docker compose build` 把 modules 烘焙进 db-import 镜像（`Dockerfile` db-import 阶段 `COPY modules modules`）→ 部署时 db-import 容器自动灌入 world DB（worldserver 镜像不含 modules，模组 SQL 由 db-import 灌，非 worldserver 运行时自动加载）。SHA1 哈希比对使 JSON 变→重生成→内容变→持久化 DB 场景下自动重灌。
  - **注意**：`runtime` 阶段只拷 `env/dist/etc`+entrypoint，不含 `/azerothcore/modules`；worldserver 镜像 modules 为空——模组 SQL 经 db-import 灌入 world DB，世界服仅读表，不读 modules 目录的 SQL。

- **R10（2026-08-30 build-patch 全量上游核对 + 失效补丁清理）**：对 `build-patches/` 全部 11 个脚本逐个比对上游仓库当前 HEAD，判定去留。见下方「4.4.1 build-patch 上游核对台账」。
  - **判定前提（影响全部分类）**：AC(Playerbot) 编译只用 `-Wall -Wextra`、**无 `-Werror`**（实证 `src/cmake/compiler/gcc/settings.cmake` L42-43）。故 sign-compare / unused-const-variable 类**只是警告、不中断编译**；而 override 签名不匹配是 **C++ 硬错误**、注册函数名错配是**链接期 undefined reference**。
  - **本次动作**：删除已失效的 `build-patches/mod-playerbots/fix_sign_compare.sh`（上游已改掉 `warlockIndex < abyssals.size()`，脚本空转）。**未推送**（等「推吧」）。
  - **上游待提 issue/PR**：`mod-playerbots-world-pvp` 两处硬编码 `USE azc_world_ashbringer;` 与单/复数注册函数名错配——只有上游修了才能去掉对应两个补丁。
  - **仍未核**：`apply_core_patches.ps1` 那 9 处核心补丁是否仍被 Playerbot 分支需要。

### 4.4.1 build-patch 上游核对台账（2026-08-30，vs 各模组仓库当前 HEAD）
| 补丁 | 上游现状（实证） | 严重性 | 判定 |
|---|---|---|---|
| `mod-playerbots/fix_sign_compare.sh` | `warlockIndex < abyssals.size()` **上游已不存在** | — | ❌ **已删除**（本次） |
| `mod-junk-to-gold-plus/fix_sign_compare.sh` | 仍在 `mod_junk_to_gold_plus.cpp:90` | 仅警告 | ⚪ 留（清噪，删了也能编过） |
| `mod-mythic-plus/fix_sign_compare.sh` | 仍在 `mythic_plus_npc_support.cpp:175` | 仅警告 | ⚪ 留（清噪） |
| `mod-item-affixes/remove_unused_statics.sh` | 仍在 `ItemAffixScripts.cpp:286/395` | 仅警告 | ⚪ 留（清噪） |
| `mod-challenge-modes/fix_onplayerresurrect.sh` | 仍在 `ChallengeModes.cpp:448/629`（值 `bool`） | **C++ 硬错误** | ✅ 必留 |
| `mod-playerbots-world-pvp/fix_loader_name.sh` | 仍在 `mod_playerbot_world_pvp.cpp:1488`、`loader.h:5`（单数） | **链接错误** | ✅ 必留 |
| `mod-playerbots-world-pvp/fix_db_use_statement.sh` | 上游未修，两文件首行仍是 `USE azc_world_ashbringer;` | db-import 报 1049 | ✅ 必留 |
| `core/dockerfile_playerbots_sql.sh` | 上游 runtime 仍不 COPY modules | 必需 + 过我们的 Gate grep | ✅ 必留 |
| `mod-item-affixes/apply_core_and_gen_sql.sh` | 上游不提交 CREATE SQL | 必需 | ✅ 必留 |
| `core/keep_going.sh` | — | 流程必需（暴露全部编译错） | ✅ 必留 |
| `core/dockerfile_ccache_persist.sh` | **纯守卫，不改任何文件**，仅在官方写法变更时告警 | — | ⚪ 留（零副作用） |

- **两条硬证据**：① 核心 `PlayerScript.h:644` = `virtual void OnPlayerResurrect(Player*, float, bool& /*applySickness*/)`（**引用**），模组写值 `bool` + `override` → C++ 硬错误「marked override but does not override」，与 `-Werror` 无关。② AC `modules/CMakeLists.txt` 把目录名 `-`→`_` 后生成 `Add${目录名}Scripts()`；目录 `mod-playerbots-world-pvp` → 调用复数 `Addmod_playerbots_world_pvpScripts()`，源码定义单数 → undefined reference。
- **安全核证**：`remove_unused_statics.sh` 说明属实——`Imprints/Priest/CelestialResonance.cpp:7` 有自己独立的 `static constexpr SPELL_CELESTIAL_RESONANCE` 且被正常使用，与 `ItemAffixScripts.cpp` 那两个死常量互不干扰。

- **R11（2026-08-30 新增：通用 SQL 归置引擎）**：解决"模组自带 SQL 因路径不合规而未被官方 db-import 灌入"这一类缺陷（本流程唯一残存的功能性缺陷：`character_worldchat`、15 张 `accountwide_*`）。
  - **实现**：`.github/scripts/normalize_module_sql.sh`，workflow 在「Mount modules + apply build-patches」**之后**、「Build core images」**之前**执行（必须在 build-patches 之后——`apply_core_and_gen_sql.sh` 会生成仓库里没有的 SQL）。
  - **设计原则**：**一个引擎、全规则驱动、零模组名硬编码、零目录名黑名单**。默认不动，只有明确"放错了"才动（保守默认）。db-import **只跑一次**，不多跑。
  - **四步规则**：
    | 步 | 判据 | 动作 |
    |---|---|---|
    | **S1 结构性** | 文件是否位于 `data/sql/` 之下 | **是** → 作者主动用了 AC 约定，其子目录名不含库名即有意识地不让它自动灌 → **跳过，不动**；**否** → 作者没用约定＝放错了 → 进入 S2 |
    | **S2 内容安全** | 见下方分级 | RED → 不归置，`rec()` 记 `[ERR]` 后**继续**；GREEN/YELLOW → 进入 S3 |
    | **S3 目标库** | ① 路径含库名 ② 内容 `USE \`acore_<db>\`` ③ 文件内表名查 `information_schema`（需活库，无则跳过此信号） | 判定 `auth`/`characters`/`world`/`playerbots` |
    | **S4 归属** | 模组目录下有无 C++ 源码（`src/` 或 `.cpp`/`.h`） | **有**（在 `AC_MODULES_LIST`）→ 复制到 `modules/<mod>/data/sql/db-<库>/base/`；**无**（纯脚本包，不在列表）→ 生成 `updates_include` 注册行写入核心 base 目录 |
  - **S1 为什么能替代"manual 黑名单"**：判据是"是否使用了 `data/sql/` 约定"这个**结构性事实**，不是目录叫什么。作者把目录叫 `manual`/`手工`/`不自动`/任何名字，只要它在 `data/sql/` 下就一律尊重、不动。反向也成立：放在 `data/sql/` 之外视为"没用约定"。
  - **S2 内容安全分级**（修订版，已用 140 个合规 .sql 验证：GREEN 112 / YELLOW 24 / RED 4，且 4 个 RED 恰好全是真不该自动灌的）：
    - **RED（不归置，记 `[ERR]` 继续）**：`DROP DATABASE`、`DROP USER`、`REVOKE`、`TRUNCATE`、`USE` 非标准库名（非 `acore_auth|characters|world|playerbots`）
    - **YELLOW（归置 + 记 `[WARN]`）**：清理（`DELETE FROM` / `DROP TABLE`）**非本文件自建**的表
    - **GREEN（归置）**：其余
    - ⚠️ **不要**把"DELETE 非自建表"判成 RED：模组 data SQL 普遍会 `DELETE FROM creature_template`/`command`/`item_template` 清理旧数据再重插，是常规必要动作，判 RED 会误报 19%。
  - **S4 纯脚本包分支的三个硬约束（实测，缺一不可）**：
    1. `updates_include.path` 是 **`PRIMARY KEY`** → 必须用 **`INSERT IGNORE`**，否则重复跑报 duplicate key
    2. `updates_include.state` 枚举只有 **`RELEASED/ARCHIVED/CUSTOM/PENDING`，没有 `MODULE`** → 必须用 **`CUSTOM`**
    3. `$` = 源码根（表注释原文 "`$` means relative to the source directory"）→ 路径写 `$/modules/<mod>/<dir>`，在 db-import 镜像里解析为 `/azerothcore/modules/<mod>/<dir>`
  - **为什么 base 阶段注入能单次跑通**：单次 db-import 内部顺序是 `Populate（base 文件，建 updates/updates_include 表）` → `UpdateFetcher（读 updates_include 收集目录后灌入）`。注册行只要落在 `data/sql/base/db_<库>/` 里，就会在 Populate 阶段执行、被同一次运行的 UpdateFetcher 读到 —— **无需重跑 db-import**。
  - **S4 脚本包分支为什么能绕开 `AC_MODULES_LIST`**：`updates_include` 的路径是加进 `directories` 的**独立条目**，不走 `for (moduleName : moduleList)` 那个模块名循环，因此与模组是否在列表内无关。官方 `UpdateFetcher.cpp` 实锤。
  - **幂等性**：走 S4 前分支的由 **AC SHA1 哈希账本**保证（内容不变不重复执行）；走 `updates_include` 的同样进账本。二者都进 `updates` 表 → 校验层可见。
  - **注册文件用"重建"而非"追加"**：`zz_project_updates_include.sql` 每次运行覆盖重写；若某库本轮无任何要注册的目录，则**删除**上一轮可能留下的该文件。必须如此——追加模式下从 `modules.txt` 摘掉模组后，指向已不存在目录的注册行会残留，db-import 会对着空路径报目录不存在。（已实测三场景：正常生成 / 重跑幂等 / 摘除后自动清除。）
  - **已知坑**：`BY_DB` 的键必须用 `detect_db` 返回的**裸名**（`auth/characters/world/playerbots`），核心 base 目录为 `data/sql/base/db_<裸名>`；若误用 `acore_*` 全名取键会取到空、注册文件不生成（已实测踩到并修正）。
  - **副作用（校验层必须适配）**：经 `updates_include` 注册灌入的文件，在 `updates` 表里 state 为 **`CUSTOM`**（不是 `MODULE`）；playerbots 自管理库为 `RELEASED`。故 L2 校验的账本比对必须覆盖 **MODULE / CUSTOM / RELEASED 三种 state**，只查 `MODULE` 会漏判。
  - **L2 对 mod-playerbots 的处理（已闭合覆盖缺口）**：不整体排除，只排除两个不该进账本的目录——`base/`（由模组自身安装器应用，不进 `updates` 账本，不排除会满屏假缺失）与 `create/`（不在 `updates_include` 白名单内，且含 `drop_mysql.sql` 本就不该灌）；**保留** `updates/`、`custom/`、`archive/` 三个白名单目录参与 L2 比对。
    - 实测（2026-08-30）：`updates/` 31 文件、`custom/` 0、`archive/` 0；账本 31 条 `RELEASED` → **缺失 0**，无误报。
    - 意义：`custom/`、`archive/` 将来一旦有文件，L2 能立即抓到漏灌，不会静默。

## 4.5 冻库(方案B)与用户机部署
- **冻库方式 = 方案B(冷拷数据目录)**：部署门干净后,`docker compose stop ac-database` 优雅停库 → `docker cp` 拷出 `/var/lib/mysql` 整个目录 → `tar -I zstd` 压成 `ac-db-data.tar.zst` → 并进大包。
- **为什么选 B 而非 A**：大包已含 `mysql:8.4` 镜像,用户机 MySQL 版本与云上完全一致,B 的「版本绑定」副作用被消除;用户机 load 后直接挂上即可,**零重导**。
- **大包内容**：`ac-bundle-latest.tar.zst` = 5 个镜像(worldserver/authserver/db-import/tools/mysql,官方 tag) 的 `docker save` tar + `ac-db-data.tar.zst`(冻库);**不含任何配置 (etc)**;地图单独：`ac-maps-latest.tar.zst` = `data.tar.zst`(wowgaming/client-data 的 Data.zip 解压,非镜像)。
- **用户机部署步骤(极简,无 ghcr / 无 ac-maps / ac-extra-config 镜像 / 无 etc 包)**：① 解 `ac-bundle-latest.tar.zst` → `docker load images.tar.zst` + 解 `ac-db-data.tar.zst`→`./env/dist/mysql-data`；② 解 `ac-maps-latest.tar.zst`→`./env/dist/data`；③ `docker compose -f docker-compose.bundle.yml up -d`：官方 entrypoint 生成完整默认核心 conf、模组回退 C++ 默认 = 满状态。db-import 仍随 `up` 跑(官方流程),库已完整→幂等空转。**如需定制配置(如 SOAP),由用户机部署脚本追写(append 模式),不随包分发。**
- **偏离官方之处(用户明确要求)**：官方每次 `compose up` 都重跑 db-import 导数据;本流程改为「云上导一次、冻进包、用户机免导」。官方流程仍用于云上「构建+测试+验证」阶段(db-import 照跑、照抓错),只改了「交付物」形态。
- **体积预警**：大包(5主镜像+etc.tar.zst+冻库)可能 ~4–6GB;地图单独包 ac-maps ~3.24GB。两者分开传/下,地图可单独更新,属预期。

## 5. 首跑前置(必看,否则部署门直接挂)
- **配置/地图不再构建镜像**：`ac-extra-config` / `ac-maps` 镜像已废弃。地图 = 官方 `ac-client-data-init` 从 wowgaming 拉 (`target: client-data`),不 pull 外部镜像、不建自定义镜像。**配置：CI 测试阶段叠仓库模组 conf 进 `./env/dist/etc` 仅验能否起(核心 conf 走官方默认);打包阶段不进包,用户机解包即官方默认。**
- **云端测试不较真配置**:deploy-test 用占位值 `ci-test` 填 `.env` 的 `SOAP_LOGIN/PASSWORD`(只验部署链路);**打包不含任何配置**,用户机默认配置即官方基线,CI 无需配 SOAP secrets。如需定制由用户机侧处理。
- runner 磁盘:部署吃 18–21GB(含下载 ~3.24GB Data.zip + 编译 C++),建议加 `free_disk.sh` 腾空间;内存 worldserver ~8GiB + MySQL ~1GiB。
- 部署验证对"容器未起来 / worldserver 崩溃"也判 FAIL(避免假阴性漏报)。

## 6. 不要做的事(铁律)
- 不要改 `build-core.yml`(新建独立工作流)。
- 不要加 `do_publish` 之类的开关(打包应"全干净自动发生")。
- 不要替换官方 Dockerfile / compose / db-import(只在上面叠 grep 错误暴露)。**编译"暴漏全部错误"已由 `build-patches/core/keep_going.sh` 补丁实现:给官方 `cmake --build . --config "$CTYPE" -j N` 追加 `-- -k 0` 透传 ninja(官方用 Ninja 生成器，`-k` 必须带数字)遇错继续,暴露全部模组错误;不改官方 Dockerfile 本体,走项目侧 build-patch 机制。**
- 不要碰 ghcr(分发靠 tarball,不靠 registry)。
- repo 改动(item-affixes 补列、worldchat 补 SQL、playerbots 补库)仍走"改吧/推吧",不在本工作流里偷偷改。

## 7. 触发与产物
- `workflow_dispatch` 手动触发(默认);schedule 段留了每日/每周/每月模板,按需解注释。
- 产物:`ac-bundle-latest.tar.zst`(大包:5 主镜像 + etc.tar.zst + 冻库) + `ac-maps-latest.tar.zst`(地图 data.tar.zst) 均传外置储存,不进 ghcr。
