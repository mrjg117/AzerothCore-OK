# 模组完整配置清单（全注释 · 中文注解 · 可逐项启用）

本目录收录 AzerothCore-OK 全部 **40 个模组** 的服务端配置，全部以「注释掉 + 中文注解 + 功能分组」形式呈现。

- **总计约 2265 条设置项**，已按模组归类、分区、加中文说明（作用 + 默认值 + 单位）。
- **所有设置默认都是关闭/未启用的**（行首带 `#`）。要启用某项，**只需删掉该行行首的 `# `**，worldserver 即读取该值；不改则沿用模组内置默认。
- 这是一份「清单/菜单」，方便你按需开启，而非直接生效的配置。

## 核心配置（worldserver / authserver）— 见 `../core/`

路径：`config/core/worldserver.conf`、`config/core/authserver.conf`，由上游 `mod-playerbots/azerothcore-wotlk` 的 `Playerbot` 分支原始 `src/server/apps/{worldserver,authserver}/<name>.conf.dist` 生成。

- **worldserver.conf**：核心服务器配置，约 **589 条设置、65 个中文分区**（数据库与连接 / 网络 / 性能 / 可见性与距离 / 经验·声望·荣誉·货币·掉落倍率 / 角色 / GM / 死亡 / 耐久 / 战场·竞技场 / 公会 / 集群 …）。
- **authserver.conf**：登录认证服务器配置，约 **36 条设置**。
- **格式说明（重要）**：核心配置体积巨大（worldserver 约 5400 行），采用「注释掉 + **中文分区标题** + **常用键中文注解** + **保留上游英文原说明**」方式生成。即每条设置上方有 `# [默认值: X]`；常用键（数据库连接串、各项倍率、端口、可见性距离、性能、网格/地图、死亡/耐久、GM、反作弊、集群等约 40+ 条）另附中文注解行说明作用与默认值；其余设置保留英文原说明作为准确文档（上游英文原说明本身就是权威文档）。
- 启用方式同模组：删掉目标行行首 `# ` 即得 `Key = Value`，合并进部署用 conf 重启生效。
- **重新生成**：直接取上游原始 `*.conf.dist`（本次生成用的临时脚本与本地抓取缓存已清理，不要再找）：
  - `https://raw.githubusercontent.com/mod-playerbots/azerothcore-wotlk/Playerbot/src/server/apps/worldserver/worldserver.conf.dist`
  - `https://raw.githubusercontent.com/mod-playerbots/azerothcore-wotlk/Playerbot/src/server/apps/authserver/authserver.conf.dist`

## 使用方式

1. 找到对应模组文件（如 `mod-playerbots.conf`）。
2. 在文件里按中文分区定位设置，例如：
   ```
   # 反应速度：bot 做完一个动作后等待多久再决策(毫秒)，越小反应越快、越吃 CPU - 默认 100
   # AiPlayerbot.ReactDelay = 100
   ```
3. 要启用 → 删掉 `# AiPlayerbot.ReactDelay = 100` 行首的 `# ` 变成 `AiPlayerbot.ReactDelay = 20`。
4. 把这些启用项（或整个文件）合并进部署用的 `worldserver.conf`（或对应模组 conf），重启 worldserver 生效。
   - 99 真机运行时读取路径：`/root/acok/env/dist/etc/`（rw 卷），改这里、别改 `ref/etc/*.dist`（构建模板）。

## 分类索引

### 一、引擎 / 框架（必须最先生效）
| 模组 | 文件 | 设置数 | 分区 |
|---|---|---|---|
| mod-ale（Lua 引擎） | [mod-ale.conf](mod-ale.conf) | 12 | 7 |
| mod-playerbots（机器人核心） | [mod-playerbots.conf](mod-playerbots.conf) | 887 | 14 |

### 二、绑定 mod-ale 的服务端 Lua 脚本（纯 Lua，无服务端 conf，运行时在游戏内/Lua 内配置）
| 模组 | 文件 | 说明 |
|---|---|---|
| azerothcore-eluna-accountwide | [azerothcore-eluna-accountwide.conf](azerothcore-eluna-accountwide.conf) | 占位说明（无 Key=Value 配置） |
| Loot-Arbiter | [Loot-Arbiter.conf](Loot-Arbiter.conf) | 占位说明（无 Key=Value 配置） |
| Random-Item-Enchants | [Random-Item-Enchants.conf](Random-Item-Enchants.conf) | 占位说明（依赖 mod-ale + 7-11 槽补丁） |

### 三、硬依赖 mod-playerbots
| 模组 | 文件 | 设置数 | 分区 |
|---|---|---|---|
| mod-dungeon-clear | [mod-dungeon-clear.conf](mod-dungeon-clear.conf) | 94 | 9 |
| mod-optimal-bot-raid | [mod-optimal-bot-raid.conf](mod-optimal-bot-raid.conf) | 62 | 4 |
| mod-player-bot-level-brackets | [mod-player-bot-level-brackets.conf](mod-player-bot-level-brackets.conf) | 69 | 6 |
| mod-playerbots-artisans | [mod-playerbots-artisans.conf](mod-playerbots-artisans.conf) | 13 | 4 |
| mod-playerbots-auto-guild | [mod-playerbots-auto-guild.conf](mod-playerbots-auto-guild.conf) | 6 | 3 |
| mod-playerbots-world-pvp | [mod-playerbots-world-pvp.conf](mod-playerbots-world-pvp.conf) | 41 | 9 |
| mod-rndbot-buffs | [mod-rndbot-buffs.conf](mod-rndbot-buffs.conf) | 12 | 4 |

### 四、软兼容 mod-playerbots（不装 pb 也能独立跑）
| 模组 | 文件 | 设置数 | 分区 |
|---|---|---|---|
| mod-ah-bot-plus（拍卖行机器人） | [mod-ah-bot-plus.conf](mod-ah-bot-plus.conf) | 448 | 15 |
| mod-guild-wars | [mod-guild-wars.conf](mod-guild-wars.conf) | 10 | 3 |
| mod-token-turnin | [mod-token-turnin.conf](mod-token-turnin.conf) | 3 | 2 |
| mod-xpcatchup | [mod-xpcatchup.conf](mod-xpcatchup.conf) | 6 | 2 |

### 五、其余纯 C++ / 客户端 Addon（无引擎依赖）
| 模组 | 文件 | 设置数 | 分区 |
|---|---|---|---|
| mod-all-flightpaths | [mod-all-flightpaths.conf](mod-all-flightpaths.conf) | 2 | - |
| mod-aoe-loot | [mod-aoe-loot.conf](mod-aoe-loot.conf) | 4 | - |
| mod-assistant | [mod-assistant.conf](mod-assistant.conf) | 38 | 5 |
| mod-auto-gather-tracking | [mod-auto-gather-tracking.conf](mod-auto-gather-tracking.conf) | 1 | - |
| mod-autobalance | [mod-autobalance.conf](mod-autobalance.conf) | 254 | 13 |
| mod-autolearn-skills | [mod-autolearn-skills.conf](mod-autolearn-skills.conf) | 13 | 3 |
| mod-challenge-modes | [mod-challenge-modes.conf](mod-challenge-modes.conf) | 65 | 9 |
| mod-classic-warrior-additions | [mod-classic-warrior-additions.conf](mod-classic-warrior-additions.conf) | 13 | 4 |
| mod-dynamic-gathering-speed | [mod-dynamic-gathering-speed.conf](mod-dynamic-gathering-speed.conf) | 20 | 4 |
| mod-enhanced-worldchat | [mod-enhanced-worldchat.conf](mod-enhanced-worldchat.conf) | 21 | - |
| mod-guild-levels | [mod-guild-levels.conf](mod-guild-levels.conf) | 15 | 4 |
| mod-instant-swing | [mod-instant-swing.conf](mod-instant-swing.conf) | 1 | - |
| mod-item-affixes（当前在 modules.txt 注释停用，配置保留） | [mod-item-affixes.conf](mod-item-affixes.conf) | 101 | 7 |
| mod-junk-to-gold-plus | [mod-junk-to-gold-plus.conf](mod-junk-to-gold-plus.conf) | 2 | - |
| mod-living-bomb | [mod-living-bomb.conf](mod-living-bomb.conf) | 5 | - |
| mod-low-level-rbg | [mod-low-level-rbg.conf](mod-low-level-rbg.conf) | 2 | - |
| mod-mythic-plus | [mod-mythic-plus.conf](mod-mythic-plus.conf) | 4 | 2 |
| mod-no-hearthstone-cooldown | [mod-no-hearthstone-cooldown.conf](mod-no-hearthstone-cooldown.conf) | 2 | - |
| mod-prayer-of-mending | [mod-prayer-of-mending.conf](mod-prayer-of-mending.conf) | 2 | - |
| mod-profession-experience | [mod-profession-experience.conf](mod-profession-experience.conf) | 28 | 4 |
| mod-quest-catchup | [mod-quest-catchup.conf](mod-quest-catchup.conf) | 3 | 2 |
| mod-quest-loot-party | [mod-quest-loot-party.conf](mod-quest-loot-party.conf) | 2 | - |
| mod-quick-respawn | [mod-quick-respawn.conf](mod-quick-respawn.conf) | 1 | - |
| mod-rdf-expansion | [mod-rdf-expansion.conf](mod-rdf-expansion.conf) | 1 | - |

## 备注

- 配置来源：各模组上游仓库的 `conf/*.conf.dist`（抓取于 2026-08-31，遵循项目「rebuild = 拉最新」不锁 commit 的决策，后续上游更新需重新抓取）。
- 原始 `.conf.dist` 未被修改，仅作读取源；本目录为派生的工作清单。
- 大模组（playerbots / ah-bot-plus / autobalance / dungeon-clear / item-affixes 等）已按功能充分分区，便于按需定位。
