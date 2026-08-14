#!/usr/bin/env bash
# 命令行入口与帮助
# 编码: UTF-8

dstctl_usage() {
  cat <<EOF
${C_BOLD}dstctl${C_RESET}  v${DSTCTL_VERSION}  —  饥荒联机版 Linux 开服管理器

用法:
  dstctl                     进入交互菜单
  dstctl help                显示本帮助
  dstctl <命令> [参数]

${C_BOLD}安装与环境${C_RESET}
  install                    安装依赖、SteamCMD、饥荒服务端
  update                     更新服务端（建议先停服）
  doctor                     环境自检
  quickstart                 安装 + 建档 + 填 Token + 开服 向导

${C_BOLD}存档管理${C_RESET}
  cluster create [名]        初始化存档（可交互，可带参数）
  cluster list               列出全部存档
  cluster info <名>          查看存档详情
  cluster edit <名> k v...   修改房间名/人数/模式等
  cluster delete <名>        删除存档
  cluster reset <名>         清档：删 save/聊天/日志，保留房间、世界、模组设置
                             可选 --yes  --no-backup
  cluster clone <源> <新>    克隆存档并重新分配端口
  token set <名> [token]     写入 cluster token
  token show <名>

  cluster create 常用参数:
    --name 房间名  --desc 简介  --password 密码  --players 6
    --mode survival|endless|wilderness  --caves / --no-caves
    --pvp false  --intention cooperative  --token TOKEN

${C_BOLD}模组${C_RESET}
  mods <名> list|add|remove|sync|pull  [工坊ID...]
  mods <名> pull                     从 modoverrides.lua 写回 mods.txt
  mods <名> sync                     用 mods.txt 覆盖生成 modoverrides.lua
  mods sync                          按各档 mods.txt 重写全部 lua 与下载清单
  启动时会自动从已有的 modoverrides.lua 收集 ID 到 mods.txt，并保留 lua 里的模组配置
  启动存档时默认自动更新模组（可用 --skip-mods 跳过）

${C_BOLD}开服 / 停服${C_RESET}
  start <名> [--skip-mods] [--skip-backup]
  stop <名> [--graceful|--kill]  停服；交互时会询问正常关闭或 kill
  restart <名> [--kill]
  start-all / stop-all
  attach <名> [Master|Caves]     进入该世界控制台
  systemd <名>                   生成 systemd 用户服务

${C_BOLD}运行中操作${C_RESET}
  players <名>                   列出在线玩家
  kick <名> <KU或名字>
  ban <名> <KU或名字> [秒]
  unban <名> <KU>
  tp <名> <玩家> --to <玩家>
  tp <名> <玩家> --pos x,z
  kill <名> <玩家>               杀死
  resurrect <名> <玩家>          复活
  despawn <名> <玩家>            退回选人
  god <名> <玩家>                切换上帝模式
  announce <名> <消息>           广播
  announce-all <消息>
  cmd <名> <lua...>              直接执行控制台命令
  save <名>                      立即保存
  rollback <名> [快照数]
  regenerate <名>                运行中重置世界（控制台 c_regenerateworld）
  season <名> autumn|winter|spring|summer
  skip <名> [day|phase]

${C_BOLD}名单${C_RESET}
  admin|whitelist|blacklist <名> [list|add|remove] [KU_xxx]

${C_BOLD}状态 / 日志 / 备份${C_RESET}
  status [名]                    总览或单档状态（天数、季节、资源）
  logs <名> [Master|Caves] [行数]
  tail <名> [Master|Caves]
  history <名>                   玩家进出记录
  backup create <名> [标签]
  backup list [名]
  backup restore <名> <文件>
  backup all
  export <名> [文件.tar.gz]
  import <文件.tar.gz>

${C_BOLD}看门狗${C_RESET}
  watchdog run|once|systemd|cron
  cluster edit <名> auto-restart true   允许崩溃后自动拉起

配置文件: ~/.dstctl/dstctl.conf  （示例: conf/dstctl.conf.example）
EOF
}

dstctl_main() {
  dstctl_load_config
  local cmd="${1-}"
  if [[ -z "$cmd" ]]; then
    cmd_menu
    return
  fi
  shift || true
  case "$cmd" in
    -h|--help|help) dstctl_usage ;;
    -v|--version|version) echo "dstctl ${DSTCTL_VERSION}" ;;
    install) cmd_install ;;
    update) cmd_update ;;
    doctor) cmd_doctor ;;
    quickstart) cmd_quickstart ;;
    menu) cmd_menu ;;
    cluster)
      local sub="${1-}"; shift || true
      case "$sub" in
        create|new) cmd_cluster_create "$@" ;;
        list|ls) cmd_cluster_list ;;
        info|show) cmd_cluster_info "$@" ;;
        edit|set) cmd_cluster_edit "$@" ;;
        delete|rm|remove) cmd_cluster_delete "$@" ;;
        reset|wipe) cmd_cluster_reset "$@" ;;
        clone) cmd_cluster_clone "$@" ;;
        *) die "cluster 子命令: create list info edit delete reset clone" ;;
      esac
      ;;
    token)
      local sub="${1-}"; shift || true
      case "$sub" in
        set) cmd_token_set "$@" ;;
        show) cmd_token_show "$@" ;;
        *) die "token 子命令: set show" ;;
      esac
      ;;
    mods|mod) cmd_mods "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    start-all) cmd_start_all "$@" ;;
    stop-all) cmd_stop_all "$@" ;;
    attach|console) cmd_attach "$@" ;;
    systemd) cmd_systemd_unit "$@" ;;
    players|list-players) cmd_players "$@" ;;
    kick) cmd_kick "$@" ;;
    ban) cmd_ban "$@" ;;
    unban) cmd_unban "$@" ;;
    tp|teleport) cmd_tp "$@" ;;
    kill) cmd_kill_player "$@" ;;
    resurrect|revive) cmd_resurrect "$@" ;;
    despawn) cmd_despawn "$@" ;;
    god) cmd_god "$@" ;;
    announce|say|broadcast) cmd_announce "$@" ;;
    announce-all|broadcast-all) cmd_announce_all "$@" ;;
    cmd|eval|exec) cmd_cmd "$@" ;;
    save) cmd_save "$@" ;;
    rollback) cmd_rollback "$@" ;;
    reset) cmd_cluster_reset "$@" ;;
    regenerate|reset-world) cmd_regenerate "$@" ;;
    season) cmd_season "$@" ;;
    skip) cmd_skip "$@" ;;
    admin) cmd_admin "$@" ;;
    whitelist) cmd_whitelist "$@" ;;
    blacklist|blocklist) cmd_blacklist "$@" ;;
    status|ps|top) cmd_status "$@" ;;
    logs|log) cmd_logs "$@" ;;
    tail) cmd_tail "$@" ;;
    history) cmd_history "$@" ;;
    backup)
      local sub="${1-}"; shift || true
      case "$sub" in
        create|new|"") [[ -n "${1-}" ]] && cmd_backup_create "$@" || cmd_backup_list ;;
        list|ls) cmd_backup_list "$@" ;;
        restore) cmd_backup_restore "$@" ;;
        all) cmd_backup_all "$@" ;;
        *) die "backup 子命令: create list restore all" ;;
      esac
      ;;
    export) cmd_export "$@" ;;
    import) cmd_import "$@" ;;
    watchdog) cmd_watchdog "$@" ;;
    *)
      log_error "未知命令: $cmd"
      echo
      dstctl_usage
      exit 1
      ;;
  esac
}
