# acok.sh 菜单与流程契约（SPEC）

> 本文件是 `acok.sh` 的**权威接口契约**：所有菜单项、向导步骤、回退规则、提示语格式以本文为准。
> 改脚本前先改本文，二者必须一致；冲突以本文为真相源。
> 触发 `curl -fsSL <Worker>/acok.sh | bash` 进入安装向导；本地 `bash acok.sh` 进入主菜单。

---

## 0. 全局常量（默认值）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `WORK_DIR` | `/opt/azerothcore-ok` | 部署目录 |
| `REALM_ADDRESS` | `play.example.com` | 对外地址（部署时由用户填真实域名/IP） |
| `IMAGE_NS` | `ghcr.io/mrjg117` | 镜像命名空间（官方直连） |
| `GM_NAME` | `acok` | GM 游戏账号名 |
| `GM_PASS` | `$(hostname)$(date +%m%d)` | GM 登录密码（运行时算真值，如 `ubuntu0816`） |
| `SOAP_LOGIN` | 无默认，**必填** | SOAP 机器账号名（Worker↔worldserver 鉴权） |
| `SOAP_PASSWORD` | 无默认，**必填** | SOAP 密码 |
| `DB_PW` | `AcokDbRoot2026!` | 数据库 root 密码 |

---

## 1. 提示语铁律

- 格式**只允许** `标签 [默认值]: `；无默认值的必填项写 `标签: `。
- 括号里显示的是**默认常量**（第 0 节），**不是**从历史 `.env` 读到的「当前值」。
- 回车行为：保留当前已载入值（更新场景不冲掉已配置）；当前为空时落默认值。
- **禁止**在提示里写解释/说明/条件；**禁止**用 `<占位描述>` 代替算得出来的真值；**禁止**在向导里追加科普性警告。
- 密码输入不隐藏（`ask_tty` 不加 `-s`），明文回显。
- 同名冲突：`GM_NAME == SOAP_LOGIN` 时提示「不能与 GM 账号名相同，请换一个」并重新询问 SOAP 名，不阻断流程。

### 各提示落点（严格一致）

| 步骤 | 提示 | 括号显示 | 回车 |
|---|---|---|---|
| ② | `部署目录` | `/opt/azerothcore-ok` | 保留当前 |
| ② | `对外地址(域名或IP)` | `play.example.com` | 保留当前 |
| ② | `镜像命名空间` | `ghcr.io/mrjg117` | 保留当前 |
| ③ | `GM 账号名` | `acok` | 落 `acok` |
| ③ | `GM 登录密码` | `$(hostname)$(date +%m%d)` 真值 | 落真值 |
| ③ | `SOAP 账号名` | （无，必填） | 不可空 |
| ③ | `SOAP 密码` | （无，必填） | 不可空 |
| ③ | `数据库 root 密码` | `AcokDbRoot2026!` | 保留当前 |

---

## 2. 主菜单（menu_loop）

```
========== AzerothCore-OK 管理菜单 ==========
 1) 网络设置    2) 安装向导    3) 配置与维护
 4) 服务操作    5) 凭据管理    q) 退出
 部署目录: $WORK_DIR
```

| 输入 | 函数 |
|---|---|
| `1` | `net_menu` |
| `2` | `run_wizard` |
| `3` | `maintain_menu` |
| `4` | `svc_menu` |
| `5` | `creds_menu` |
| `q`/`Q`/`quit`/`exit` | 退出 |

---

## 3. ① 网络设置（net_menu，循环）

| 输入 | 函数 |
|---|---|
| `1` | 部署源设为 `ghcr` 直连（写 `DEPLOY_SRC=ghcr`，清空 `EXT_STORAGE_BASE`） |
| `2` | `ext_storage_menu` —— 输入外置储存前缀，写 `EXT_STORAGE_BASE`+`DEPLOY_SRC=external` |
| `q` | 返回主菜单 |

### 3.1 选择 ghcr 镜像源（select_mirror，循环）

```
当前镜像源: ${IMAGE_NS:-ghcr.io/mrjg117}
1) ghcr.io/mrjg117 (官方直连，默认)
2) 自定义镜像前缀
t) 测速当前源
q) 返回
```

| 输入 | 行为 |
|---|---|
| `1` | `set_ns ghcr.io/mrjg117` |
| `2` | 输入自定义前缀 → `set_ns <输入>` |
| `t`/`T` | `speed_test` |
| `q` | 返回 |

### 3.2 speed_test（测速当前源）

- 只测**当前 `IMAGE_NS`** 一个源（不写死官方源）。
- 实现：`timeout 10 docker pull "${IMAGE_NS}/ac-wotlk-worldserver:latest"`，走 docker 自身鉴权（与真实 `docker pull` 同一条能通的路）。
- 解析 docker 进度行 `X MB/Y MB` 算：**当前 MB/s / 平均 MB/s / 用时**。
- 10 秒到截断（截断不算失败）；下到字节即出平均速率，否则报「拉取失败」。

---

## 4. ② 安装向导（run_wizard）

步骤数组（**顺序即流程**）：
```
wz_history → wz_env → wz_creds → wz_plan → wz_deploy → wz_maps
```

### 回退规则（steps 循环）

```
wi=0; while [ $wi -lt $n ]; do
  if "${steps[$wi]}"; then wi=$((wi+1)); else wi=$((wi-1)); [ $wi -lt 0 ] && wi=0; fi
done
```

- 任意步骤 `return 1`（用户按 `b`）→ `wi-1` 回上一步。
- **`wz_deploy` 拉取失败 `return 1` → 回 `wz_plan`（确认层），绝不回 `wz_creds`**（已填凭据不被覆盖）。
- `wz_history` 是首步，`wi` 不会小于 0。

---

### ④-1 wz_history（检测历史 + 选方案）

- `find_history` 定位历史安装目录（候选路径 + 运行中容器 label）。
- 有历史：`load_creds` 载入 SOAP/DB/REALM/IMAGE_NS；立即弹方案选择：
  - `1` 原地更新（默认）/ `2` 清理重装（需输入 `YES` 确认）。
- 无历史：全新安装。
- **检测完立即给方案选择，不藏到后面步骤。**

### ④-2 wz_env（部署目录 / 外网地址 / 镜像源）

- 默认值从发布的 `.env.example` 取（避免显示空默认）。
- 三个提示显示**默认常量**（见第 1 节表），回车保留当前。

### ④-3 wz_creds（GM / SOAP / 数据库凭据）

- 见第 1 节提示落点；SOAP 名/密码必填，GM 与 SOAP 同名拦截。

### ④-4 wz_plan（部署确认层）★新增回退锚点

摘要显示全部已填值 + 部署方案，提供修改入口；**默认 `y` 直接部署**。

```
--- ④ 部署确认（输入 b 返回上一步，y 直接部署）---
当前配置：
  部署目录 / 对外地址 / 镜像命名空间 / GM 账号 / SOAP 账号 / DB root 密码 / 部署方案
选项：
  1) 修改 部署目录/外网地址/镜像源  → wz_env
  2) 修改 GM/SOAP/数据库凭据        → wz_creds
  3) 修改 部署方案(原地更新/清理重装) → wz_history
  y) 确认并部署（默认）
  b) 返回上一步
```

- `b` → `return 1` → 回 `wz_creds`。
- `1/2/3` → 重收集后回到本层重新显示摘要。
- `y`/`Y`/回车 → `return 0` → 进 `wz_deploy`。

### ④-5 wz_deploy（拉取并启动）

1. 下载部署文件（`docker-compose.yml` / `override.yml` / `.env.example`→`.env` / `conf/dist/env.ac`）。
2. 写 `.env`（REALM_ADDRESS / IMAGE_NS / SOAP / DB_PW）+ `save_creds`。
3. 清理重装：备份凭据 → `docker compose down -v`。
4. `fix_env_perms`（chown 1000:1000 `env/dist/etc|logs`）。
5. `pull_with_eta` —— **失败 `return 1` → 回 `wz_plan`**。
6. `docker compose up -d` 核心栈；等 worldserver 起来建 GM/SOAP 账号（gmlevel 3）；写 realm 地址。
7. 询问是否导入配置（3.2）。

### ④-6 wz_maps（地图数据）

- 卷 `ac-client-data` 存在即略过；否则询问补拉 `import_maps`。

---

## 5. ③ 配置与维护（maintain_menu，循环）

| 输入 | 函数 |
|---|---|
| `1` | `import_maps` —— 拉地图（ac-client-data-init，约 1.2GiB） |
| `2` | `import_config` —— 备份 `./env/dist/etc` + 重跑 ac-extra-config |
| `3` | `rerun_db_import` |
| `4` | `full_redeploy` —— 拉最新 + 重建（保留数据卷） |
| `q` | 返回 |

---

## 6. ④ 服务操作（svc_menu，循环）

| 输入 | 函数 |
|---|---|
| `1` | `svc_reload` —— 热重载 `.reload config` |
| `2` | `svc_restart_world` —— 智能重启/启动 worldserver |
| `3` | `svc_stop` —— 停止全部（数据保留） |
| `4` | `svc_status` |
| `5` | `svc_logs` —— 最近 200 行 |
| `q` | 返回 |

---

## 7. ⑤ 凭据管理（creds_menu，循环）

| 输入 | 函数 |
|---|---|
| `1` | `change_soap_login` |
| `2` | `change_soap_pass` |
| `3` | `change_db_pass` |
| `4` | `find_history_menu` |
| `5` | `account_mgmt` —— a 新建普通 / b 新建 GM带等级 / c 改GM等级 |
| `q` | 返回 |

---

## 8. 拉取公共逻辑（pull_with_eta）

- 只拉核心栈 + 地图：`docker compose pull ac-worldserver ac-authserver ac-database ac-db-import ac-client-data-init`。
- 失败打印「核心镜像拉取失败」并 `return 1`（由 steps 循环回退到 `wz_plan`）。

---

## 9. 与部署机脚本的交互契约

- 配置最终真值来源：敏感/基础配置存部署机 `.env` / `.soap_creds` / `.db_creds`（chmod 600），重拉配置时由配置镜像注入同一真值，不冲、不进公开镜像。
- `SOAP_LOGIN`/`SOAP_PASSWORD` 与 CF Worker 后台须一致；`SOAP.Port` 固定 7878（内部管道，不做变量）。
- 数据库走 `DB_IMAGE`（默认 `ghcr.io/mrjg117/ac-wotlk-mysql:8.4`，已在 `docker-compose.override.yml` 接 `${DB_IMAGE:-...}`），替换官方 `mysql:8.4`。
