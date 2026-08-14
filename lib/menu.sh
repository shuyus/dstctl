#!/usr/bin/env bash
# 交互式菜单
# 编码: UTF-8

_menu_header() {
  clear 2>/dev/null || true
  cat <<EOF
${C_CYAN}${C_BOLD}
    ╔══════════════════════════════════════════╗
    ║     饥荒联机版 Linux 开服管理器          ║
    ║              dstctl  ${DSTCTL_VERSION}                 ║
    ╚══════════════════════════════════════════╝
${C_RESET}
  服务端: $(game_version 2>/dev/null || echo 未安装)    mux: $(detect_mux)    $(now)
EOF
}

_ask_cluster() {
  local n="${1-}"
  if [[ -n "$n" ]]; then
    printf '%s' "$n"
    return
  fi
  pick_cluster
}

_ask_running() {
  local names n i=1
  mapfile -t names < <(running_clusters)
  if [[ ${#names[@]} -eq 0 ]]; then
    log_error "没有正在运行的存档"
    return 1
  fi
  if [[ ${#names[@]} -eq 1 ]]; then
    printf '%s' "${names[0]}"
    return 0
  fi
  echo "运行中的存档:" >&2
  for n in "${names[@]}"; do
    printf "  %2d) %s\n" "$i" "$n" >&2
    i=$((i + 1))
  done
  local sel
  read -r -p "编号: " sel || true
  [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#names[@]} )) || return 1
  printf '%s' "${names[sel-1]}"
}

_menu_install() {
  cat <<EOF
  1) 一键安装（依赖 + SteamCMD + 服务端）
  2) 仅更新服务端
  3) 环境自检 doctor
  4) 快速开服向导
  0) 返回
EOF
  local c
  read -r -p "选择: " c || true
  case "$c" in
    1) cmd_install; pause_enter ;;
    2) cmd_update; pause_enter ;;
    3) cmd_doctor; pause_enter ;;
    4) cmd_quickstart; pause_enter ;;
  esac
}

_menu_cluster() {
  cat <<EOF
  1) 创建存档
  2) 列出存档
  3) 存档详情
  4) 修改配置（房间名/人数/模式等）
  5) 设置 Token
  6) 模组管理
  7) 管理员 / 白名单 / 黑名单
  8) 克隆存档
  9) 重置存档（清进度，保留房间/世界/模组设置）
 10) 删除存档
  0) 返回
EOF
  local c name
  read -r -p "选择: " c || true
  case "$c" in
    1) cmd_cluster_create; pause_enter ;;
    2) cmd_cluster_list; pause_enter ;;
    3) name="$(_ask_cluster)" && cmd_cluster_info "$name"; pause_enter ;;
    4)
      name="$(_ask_cluster)" || return
      echo "示例: name 新房间名   players 8   password 123   mode endless"
      local rest
      read -r -p "输入 键 值: " rest || true
      # shellcheck disable=SC2086
      cmd_cluster_edit "$name" $rest
      pause_enter
      ;;
    5) name="$(_ask_cluster)" && cmd_token_set "$name"; pause_enter ;;
    6) _menu_mods ;;
    7) _menu_lists ;;
    8)
      name="$(_ask_cluster)" || return
      local dst
      dst="$(read_default "新存档名" "${name}_copy")"
      cmd_cluster_clone "$name" "$dst"
      pause_enter
      ;;
    9) name="$(_ask_cluster)" && cmd_cluster_reset "$name"; pause_enter ;;
    10) name="$(_ask_cluster)" && cmd_cluster_delete "$name"; pause_enter ;;
  esac
}

_menu_mods() {
  local name ids
  name="$(_ask_cluster)" || return
  echo "当前模组:"; list_show "$(cluster_mods_file "$name")"
  echo "  1) 添加工坊 ID   2) 移除   3) 按 mods.txt 覆盖 lua   4) 从 lua 写回 mods.txt   0) 返回"
  local c
  read -r -p "选择: " c || true
  case "$c" in
    1)
      ids="$(read_default "工坊 ID（空格分隔）" "")"
      # shellcheck disable=SC2086
      cmd_mods "$name" add $ids
      ;;
    2)
      ids="$(read_default "要移除的工坊 ID" "")"
      # shellcheck disable=SC2086
      cmd_mods "$name" remove $ids
      ;;
    3) cmd_mods "$name" sync ;;
    4) cmd_mods "$name" pull ;;
  esac
  pause_enter
}

_menu_lists() {
  local name which action id
  name="$(_ask_cluster)" || return
  echo "  1) 管理员  2) 白名单  3) 黑名单"
  read -r -p "选择名单: " which || true
  case "$which" in
    1) which=admin ;;
    2) which=whitelist ;;
    3) which=blacklist ;;
    *) return ;;
  esac
  _list_cmd "$which" "$name" list
  echo "  1) 添加  2) 移除  0) 返回"
  read -r -p "动作: " action || true
  case "$action" in
    1) id="$(read_default "KU_xxxxxxxx" "")"; _list_cmd "$which" "$name" add "$id" ;;
    2) id="$(read_default "KU_xxxxxxxx" "")"; _list_cmd "$which" "$name" remove "$id" ;;
  esac
  pause_enter
}

_menu_process() {
  cat <<EOF
  1) 启动存档
    2) 停止存档（可选正常关闭或 kill）
  3) 重启存档
  4) 运行中状态
  5) 附加到控制台（Ctrl+A D 退出 screen）
  6) 查看日志
  7) 跟踪日志
  0) 返回
EOF
  local c name shard
  read -r -p "选择: " c || true
  case "$c" in
    1) name="$(_ask_cluster)" && cmd_start "$name"; pause_enter ;;
    2) name="$(_ask_running)" && cmd_stop "$name"; pause_enter ;;
    3) name="$(_ask_cluster)" && cmd_restart "$name"; pause_enter ;;
    4) cmd_dashboard; pause_enter ;;
    5)
      name="$(_ask_running)" || return
      shard="$(read_default "Shard (Master/Caves)" "Master")"
      cmd_attach "$name" "$shard"
      ;;
    6)
      name="$(_ask_cluster)" || return
      shard="$(read_default "Shard (Master/Caves)" "Master")"
      cmd_logs "$name" "$shard" 80
      pause_enter
      ;;
    7)
      name="$(_ask_cluster)" || return
      shard="$(read_default "Shard (Master/Caves)" "Master")"
      cmd_tail "$name" "$shard"
      ;;
  esac
}

_menu_runtime() {
  local name who
  name="$(_ask_running)" || return
  cat <<EOF
存档: $name
  1) 玩家列表
  2) 踢出玩家
  3) Ban / 临时 Ban
  4) 解 Ban
  5) 传送玩家
  6) 杀死玩家
  7) 复活玩家
  8) 广播
  9) 执行控制台命令
 10) 立即保存
 11) 回档
 12) 切换季节
  0) 返回
EOF
  local c msg pos to sec
  read -r -p "选择: " c || true
  case "$c" in
    1) cmd_players "$name"; pause_enter ;;
    2) cmd_players "$name"; who="$(read_default "KU 或玩家名" "")"; cmd_kick "$name" "$who"; pause_enter ;;
    3)
      cmd_players "$name"
      who="$(read_default "KU 或玩家名" "")"
      sec="$(read_default "封禁秒数（空=永久）" "")"
      cmd_ban "$name" "$who" "$sec"
      pause_enter
      ;;
    4) who="$(read_default "KU" "")"; cmd_unban "$name" "$who"; pause_enter ;;
    5)
      cmd_players "$name"
      who="$(read_default "要传送的玩家" "")"
      echo "1) 传到另一名玩家   2) 传到坐标 x,z"
      read -r -p "方式: " to || true
      if [[ "$to" == "1" ]]; then
        to="$(read_default "目标玩家" "")"
        cmd_tp "$name" "$who" --to "$to"
      else
        pos="$(read_default "x,z" "0,0")"
        cmd_tp "$name" "$who" --pos "$pos"
      fi
      pause_enter
      ;;
    6) cmd_players "$name"; who="$(read_default "KU 或玩家名" "")"; cmd_kill_player "$name" "$who"; pause_enter ;;
    7) cmd_players "$name"; who="$(read_default "KU 或玩家名" "")"; cmd_resurrect "$name" "$who"; pause_enter ;;
    8) msg="$(read_default "广播内容" "")"; cmd_announce "$name" "$msg"; pause_enter ;;
    9) msg="$(read_default "Lua 命令" "c_listallplayers()")"; cmd_cmd "$name" "$msg"; pause_enter ;;
    10) cmd_save "$name"; pause_enter ;;
    11) sec="$(read_default "回档快照数" "1")"; cmd_rollback "$name" "$sec"; pause_enter ;;
    12)
      echo "autumn / winter / spring / summer"
      msg="$(read_default "季节" "autumn")"
      cmd_season "$name" "$msg"
      pause_enter
      ;;
  esac
}

_menu_backup() {
  cat <<EOF
  1) 备份指定存档
  2) 备份全部
  3) 列出备份
  4) 恢复备份
  5) 导出存档 tar.gz
  6) 导入 tar.gz
  0) 返回
EOF
  local c name f
  read -r -p "选择: " c || true
  case "$c" in
    1) name="$(_ask_cluster)" && cmd_backup_create "$name"; pause_enter ;;
    2) cmd_backup_all; pause_enter ;;
    3) name="$(_ask_cluster)" && cmd_backup_list "$name"; pause_enter ;;
    4) name="$(_ask_cluster)" && cmd_backup_restore "$name"; pause_enter ;;
    5) name="$(_ask_cluster)" && cmd_export "$name"; pause_enter ;;
    6) f="$(read_default "tar.gz 路径" "")"; cmd_import "$f"; pause_enter ;;
  esac
}

cmd_menu() {
  while true; do
    _menu_header
    echo "  ${C_BOLD}1)${C_RESET} 安装与环境          ${C_BOLD}5)${C_RESET} 运行时操作（踢/Ban/传送/广播/控制台）"
    echo "  ${C_BOLD}2)${C_RESET} 存档 / Token / 模组  ${C_BOLD}6)${C_RESET} 状态总览"
    echo "  ${C_BOLD}3)${C_RESET} 启动 / 停止 / 日志   ${C_BOLD}7)${C_RESET} 备份 / 导入导出"
    echo "  ${C_BOLD}4)${C_RESET} 列出存档             ${C_BOLD}8)${C_RESET} 看门狗与 crontab 示例"
    echo
    echo "  ${C_BOLD}0)${C_RESET} 退出                 ${C_DIM}提示: 所有功能也可用 dstctl 命令行调用${C_RESET}"
    echo
    local c
    read -r -p "请选择: " c || exit 0
    case "$c" in
      1) _menu_install ;;
      2) _menu_cluster ;;
      3) _menu_process ;;
      4) cmd_cluster_list; pause_enter ;;
      5) _menu_runtime ;;
      6) cmd_dashboard; pause_enter ;;
      7) _menu_backup ;;
      8) cmd_watchdog cron; echo; echo "为存档打开自动重启: dstctl cluster edit <名> auto-restart true"; pause_enter ;;
      0|q|Q) echo "再见。"; exit 0 ;;
    esac
  done
}
