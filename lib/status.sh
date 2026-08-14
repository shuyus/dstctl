#!/usr/bin/env bash
# 状态、统计、日志
# 编码: UTF-8

_proc_rss() {
  local pid="$1"
  [[ -r "/proc/${pid}/status" ]] || { echo 0; return; }
  awk '/VmRSS:/{print $2*1024}' "/proc/${pid}/status"
}

_proc_cpu() {
  local pid="$1"
  ps -p "$pid" -o pcpu= 2>/dev/null | tr -d ' '
}

_proc_etime() {
  local pid="$1"
  ps -p "$pid" -o etime= 2>/dev/null | tr -d ' '
}

_shard_status_line() {
  local name="$1" shard="$2"
  if ! shard_running "$name" "$shard"; then
    printf "  %-8s %s未运行%s\n" "$shard" "$C_DIM" "$C_RESET"
    return
  fi
  local pid rss cpu et port
  pid="$(shard_pid "$name" "$shard")"
  rss="$(_proc_rss "$pid")"
  cpu="$(_proc_cpu "$pid")"
  et="$(_proc_etime "$pid")"
  port="$(ini_get "$(shard_dir "$name" "$shard")/server.ini" NETWORK server_port)"
  printf "  %-8s %s运行中%s  pid=%s  CPU=%s%%  内存=%s  时长=%s  端口=%s\n" \
    "$shard" "$C_GREEN" "$C_RESET" "$pid" "${cpu:-?}" "$(bytes_human "${rss:-0}")" "$et" "$port"
}

cmd_status() {
  local name="${1-}"
  if [[ -z "$name" || "$name" == "--all" ]]; then
    cmd_dashboard
    return
  fi
  require_cluster "$name"
  local ini disp
  ini="$(cluster_ini "$name")"
  disp="$(ini_get "$ini" NETWORK cluster_name "$name")"
  echo "${C_BOLD}== $name / $disp ==${C_RESET}"
  echo "模式=$(ini_get "$ini" GAMEPLAY game_mode)  人数上限=$(ini_get "$ini" GAMEPLAY max_players)  洞穴=$(cluster_has_caves "$name" && echo 是 || echo 否)"
  _shard_status_line "$name" Master
  cluster_has_caves "$name" && _shard_status_line "$name" Caves
  if cluster_running "$name"; then
    _dump_world_stat "$name"
  fi
}

_dump_world_stat() {
  local name="$1"
  local ts logf i
  ts="$(date +%s)"
  logf="$(shard_log "$name" Master)"
  send_lua "$name" "pcall(function() print(string.format(\"[DSTCTL] STAT\t${ts}\t%d\t%s\t%s\t%s\t%d\t%s\", TheWorld.state.cycles, tostring(TheWorld.state.season), tostring(TheWorld.state.remainingdaysinseason), tostring(TheWorld.state.phase), #AllPlayers, tostring(TheNet:IsServerPaused()))) end)" 2>/dev/null || true
  i=0
  while (( i < 6 )); do
    sleep 1
    if [[ -f "$logf" ]] && grep -q "\\[DSTCTL\\] STAT	${ts}	" "$logf"; then
      awk -v ts="$ts" -F '\t' '
        $0 ~ "\\[DSTCTL\\] STAT\t" ts "\t" {
          printf "世界: 第 %s 天  季节=%s  本季剩余=%s 天  时段=%s  在线=%s  暂停=%s\n", $3, $4, $5, $6, $7, $8
        }
      ' "$logf"
      return 0
    fi
    i=$((i + 1))
  done
  echo "世界信息: （暂未从控制台取到，世界可能仍在加载）"
}

cmd_dashboard() {
  echo "${C_BOLD}饥荒联机版 服务器总览${C_RESET}   $(now)"
  echo "dstctl ${DSTCTL_VERSION}    服务端 $(game_version 2>/dev/null || echo 未安装)"
  echo "----------------------------------------"
  if [[ -r /proc/loadavg ]]; then
    local mem_total mem_avail
    mem_total="$(awk '/MemTotal/{print $2*1024}' /proc/meminfo 2>/dev/null)"
    mem_avail="$(awk '/MemAvailable/{print $2*1024}' /proc/meminfo 2>/dev/null)"
    printf "负载: %s    内存可用: %s / %s\n" \
      "$(cut -d' ' -f1-3 /proc/loadavg)" \
      "$(bytes_human "${mem_avail:-0}")" \
      "$(bytes_human "${mem_total:-0}")"
    printf "磁盘(%s): " "$DST_ROOT"
    df -h "$DST_ROOT" 2>/dev/null | awk 'NR==2{printf "可用 %s / %s (%s 已用)\n",$4,$2,$5}'
  fi
  echo "----------------------------------------"
  cmd_cluster_list
  echo "----------------------------------------"
  local n r
  n="$(list_cluster_names | wc -l | tr -d ' ')"
  r="$(running_clusters | wc -l | tr -d ' ')"
  printf "存档 %s 个，其中 %s 个正在运行。  mux=%s\n" "$n" "$r" "$(detect_mux)"
}

cmd_logs() {
  local name="${1-}" shard="${2:-Master}" lines="${3:-80}"
  require_cluster "$name"
  local f
  f="$(shard_log "$name" "$shard")"
  [[ -f "$f" ]] || die "日志不存在: $f"
  echo "== $f (最后 ${lines} 行) =="
  tail -n "$lines" "$f"
}

cmd_tail() {
  local name="${1-}" shard="${2:-Master}"
  require_cluster "$name"
  local f
  f="$(shard_log "$name" "$shard")"
  [[ -f "$f" ]] || die "日志不存在: $f"
  echo "跟踪日志 Ctrl+C 退出: $f"
  tail -f "$f"
}

cmd_history() {
  local name="${1-}"
  require_cluster "$name"
  local f
  f="$(shard_log "$name" Master)"
  [[ -f "$f" ]] || die "没有 Master 日志"
  echo "${C_BOLD}玩家进出记录 ($name)${C_RESET}"
  grep -E '\[Join Announcement\]|\[Leave Announcement\]|Client authenticated:' "$f" | tail -n 50
}
