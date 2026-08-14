# dstctl — 饥荒联机版 Linux 开服管理器

面向 Linux 的 Don't Starve Together 专用服务器管理脚本：一套命令行 + 交互菜单，覆盖安装、多开存档、地上/洞穴同机、模组更新、玩家管理、广播、备份和崩溃拉起。

## 功能一览

| 类别 | 能力 |
| --- | --- |
| 安装 | 系统依赖、SteamCMD、饥荒服务端（AppID 343050）、`steamclient.so` 修复、环境自检 |
| 存档 | 初始化档、可配置房间信息、多档并存、克隆（自动换端口）、导入导出 |
| 开服 | 单世界（仅地上）或地上+地下同服务器双进程；端口自动分配，避免多开冲突 |
| 模组 | 按存档维护工坊 ID；启动时汇总下载并写入 `modoverrides.lua` |
| 运行时 | 管理员/白名单/黑名单；踢人、Ban/解 Ban、传送、杀死、复活、选人、上帝模式；直接执行控制台 Lua |
| 状态 | 进程 CPU/内存/时长、世界天数/季节、在线人数、进出记录 |
| 广播 | 单档广播、全部运行档广播、停服前公告、开服 MOTD |
| 额外 | 启动前备份与轮转、回档、重置世界、看门狗、Webhook 通知、systemd / crontab 示例 |

## 环境要求

- Linux x86_64（Debian / Ubuntu / RHEL / Arch 等）
- Bash 4+
- 建议安装 `screen`（也可自动回退到 `tmux` 或 FIFO）
- 联机开服需要 [Klei 账户](https://accounts.klei.com/account/game/servers?game=DontStarveTogether) 生成的 **cluster token**（需拥有饥荒联机版）

把本目录拷到服务器后：

```bash
chmod +x dstctl
./dstctl doctor          # 环境自检
./dstctl                 # 进入菜单
# 或把目录加入 PATH
sudo ln -s "$(pwd)/dstctl" /usr/local/bin/dstctl
```

Bash 补全（可选）：

```bash
source completions/dstctl.bash
```

## 最快开服

```bash
./dstctl quickstart
```

向导会依次：安装依赖与服务端 → 创建存档 → 填写 Token → 启动。

也可以分步：

```bash
./dstctl install
./dstctl cluster create MyWorld --name "我的世界" --players 8 --caves
./dstctl token set MyWorld
./dstctl mods MyWorld add 378160973  # 示例：工坊 ID
./dstctl start MyWorld
./dstctl status MyWorld
```

Token 获取方式：

1. 打开 https://accounts.klei.com/account/game/servers?game=DontStarveTogether
2. 添加服务器后复制 token，执行 `dstctl token set <存档名>`
3. 或在游戏客户端控制台执行 `TheNet:GenerateClusterToken()`，再把生成的 `cluster_token.txt` 拷过来

## 目录约定

默认路径（均可在 `~/.dstctl/dstctl.conf` 覆盖，参见 `conf/dstctl.conf.example`）：

| 路径 | 用途 |
| --- | --- |
| `~/dst/steamcmd` | SteamCMD |
| `~/dst/server` | 饥荒专用服务器 |
| `~/dst/server/ugc_mods` | 创意工坊 V2 模组（各世界共享，避免重复下载） |
| `~/.klei/DoNotStarveTogether/<存档名>` | 存档与配置 |
| `~/dst/backups` | 备份 |
| `~/.dstctl` | 运行 pid、锁、看门狗日志 |

每个存档目录大致为：

```
MyWorld/
  cluster.ini
  cluster_token.txt
  adminlist.txt / whitelist.txt / blocklist.txt
  mods.txt                 # dstctl 用：每行一个工坊 ID
  .dstctl.conf             # 洞穴开关、自动重启、MOTD、Webhook
  Master/                  # 地上
  Caves/                   # 地下（可选）
```

## 常用命令

```bash
# 存档
dstctl cluster list
dstctl cluster info MyWorld
dstctl cluster edit MyWorld name "新房间名" players 10 password 123
dstctl cluster clone MyWorld MyWorld2
dstctl cluster create ForestOnly --no-caves --mode endless

# 开停（可同时开多个不同存档）
dstctl start MyWorld
dstctl start MyWorld2
dstctl stop MyWorld
dstctl restart MyWorld --skip-mods
dstctl attach MyWorld Master          # screen: Ctrl+A D 退出

# 模组（启动时默认会更新）
dstctl mods MyWorld add 351325790 378160973
dstctl mods MyWorld list
dstctl mods sync

# 玩家与控制台
dstctl players MyWorld
dstctl kick MyWorld KU_xxxxxxxx
dstctl ban MyWorld 捣蛋鬼 3600        # 封 1 小时；省略秒数则永久
dstctl tp MyWorld 威尔逊 --to 薇洛
dstctl tp MyWorld 威尔逊 --pos 100,-40
dstctl kill MyWorld 威尔逊
dstctl resurrect MyWorld 威尔逊
dstctl announce MyWorld "10 分钟后重启"
dstctl cmd MyWorld 'c_listallplayers()'
dstctl save MyWorld
dstctl rollback MyWorld 1

# 名单（KU_ 开头的 Klei ID）
dstctl admin MyWorld add KU_xxxxxxxx
dstctl whitelist MyWorld add KU_xxxxxxxx
dstctl blacklist MyWorld add KU_xxxxxxxx

# 状态 / 备份
dstctl status
dstctl logs MyWorld Master 120
dstctl history MyWorld
dstctl backup create MyWorld
dstctl backup restore MyWorld MyWorld-20260814-210000-manual.tar.gz
```

创建存档时的常用参数：

```text
--name 房间显示名
--desc 简介
--password 密码
--players 6
--mode survival|endless|wilderness
--caves / --no-caves
--pvp false
--intention cooperative|social|competitive|madness
--token TOKEN
```

## 多开与洞穴

- **多个存档**：每个存档独立目录、独立端口、独立 screen/tmux 会话，可以同时 `start`。
- **仅地上**：`cluster create ... --no-caves`，只跑 Master 进程。
- **地上+地下同机**：默认开启洞穴。Master 与 Caves 两个进程，通过 `cluster.ini` 的 `cluster_key` + `master_port`（仅监听 127.0.0.1）互通。
- 克隆存档会重新分配端口和 `cluster_key`，避免冲突。

防火墙需要放行 **UDP**（以实际 `server.ini` 为准，创建时会打印）：

- 地上/洞穴 `server_port`（默认从 10999 起）
- Steam `master_server_port`、`authentication_port`

分片通信端口只绑定本机，一般不用对公网开放。

## 模组工作方式

1. 把工坊 ID 写入该存档的 `mods.txt`（`dstctl mods add`）。
2. 启动前把 **所有存档** 的模组合并进 `server/mods/dedicated_server_mods_setup.lua`（多开时互不漏下）。
3. 只在当前存档的 `Master/modoverrides.lua` 与 `Caves/modoverrides.lua` 里启用本档模组。
4. 先跑一遍 `-only_update_server_mods`，再以 `-skip_update_server_mods` 拉起各世界，避免双进程同时抢下载。
5. 紧急重启可加 `--skip-mods`。

## 看门狗、定时任务、开机启动

给需要自动拉起的存档打开开关：

```bash
dstctl cluster edit MyWorld auto-restart true
dstctl watchdog systemd          # 生成用户 systemd 服务
# 或 crontab: dstctl watchdog cron
```

```bash
dstctl systemd MyWorld           # 为单个存档生成 systemd 用户单元
```

Webhook（Discord 等兼容 `{"content":"..."}` 的地址）可写在配置文件 `WEBHOOK_URL`，或：

```bash
dstctl cluster edit MyWorld webhook "https://..."
dstctl cluster edit MyWorld motd "欢迎来到服务器"
```

## 配置文件

优先级：环境变量 / `conf/dstctl.conf` / `~/.dstctl/dstctl.conf` / `/etc/dstctl.conf`。

常见项：`DST_ROOT`、`BACKUP_KEEP`、`MOD_UPDATE_ON_START`、`PROCESS_MUX=screen|tmux|fifo`、`WEBHOOK_URL`。

## 常见问题

**房间列表里看不到服务器**

- Token 是否写入且无多余空格/空行（`E_EXPIRED_TOKEN` 常见于 token 损坏）
- `offline_cluster` 必须为 `false`
- 放行 UDP 游戏端口；同机用游戏搜服务器时打开 LAN 过滤

**洞穴进不去 / 一直 Connecting to shard**

- 两个进程都要在跑：`dstctl status <存档>`
- `shard_enabled = true`，Master `is_master = true`，Caves 为 false
- 地上与洞穴的 `server_port` / Steam 端口不能冲突

**模组不下载**

- 执行 `dstctl update` 以复制正确的 `steamclient.so`
- 看 `~/.dstctl/logs/modupdate-*.log` 是否有 Workshop 错误

**附加控制台后怎样出来**

- screen：`Ctrl+A` 然后 `D`
- tmux：`Ctrl+B` 然后 `D`

**动态库缺失（libcurl-gnutls 等）**

```bash
./dstctl install      # 会按发行版安装常见 32/64 位库
./dstctl doctor
```

## 许可与说明

脚本用于自建 Linux 专用服管理，不修改游戏资源。开服请遵守 Klei 服务条款。创意工坊模组版权归原作者。
