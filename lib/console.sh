#!/usr/bin/env bash
# 向运行中的分片发送控制台命令
# 编码: UTF-8

send_lua() {
  local name="$1" lua="$2" shard="${3:-Master}"
  require_cluster "$name"
  shard_running "$name" "$shard" || {
    if [[ "$shard" == "Master" ]] && shard_running "$name" Caves; then
      shard="Caves"
    else
      die "存档 $name 的 $shard 未运行，无法发送命令"
    fi
  }
  mux_send "$(session_name "$name" "$shard")" "$lua" \
    || die "发送命令失败（会话不存在）"
  log_debug ">> [$name/$shard] $lua"
}

send_lua_all_shards() {
  local name="$1" lua="$2"
  shard_running "$name" Master && mux_send "$(session_name "$name" Master)" "$lua" || true
  shard_running "$name" Caves && mux_send "$(session_name "$name" Caves)" "$lua" || true
}

cmd_cmd() {
  local name="${1-}"
  shift || true
  [[ -n "$name" && $# -gt 0 ]] || die "用法: dstctl cmd <存档> <lua命令...>"
  local lua="$*"
  send_lua "$name" "$lua"
  log_ok "已发送: $lua"
}

cmd_announce() {
  local name="${1-}"
  shift || true
  [[ -n "$name" && $# -gt 0 ]] || die "用法: dstctl announce <存档> <消息>"
  local msg="$*"
  send_lua_all_shards "$name" "c_announce(\"$(lua_escape "$msg")\")"
  log_ok "已广播: $msg"
}

cmd_announce_all() {
  local msg="$*"
  [[ -n "$msg" ]] || die "用法: dstctl announce-all <消息>"
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    send_lua_all_shards "$n" "c_announce(\"$(lua_escape "$msg")\")"
    log_info "已向 $n 广播"
  done < <(running_clusters)
}

cmd_save() {
  local name="$1"
  require_cluster "$name"
  cluster_running "$name" || die "未运行"
  send_lua "$name" "c_save()"
  log_ok "已请求保存世界"
}

cmd_rollback() {
  local name="$1" n="${2:-1}"
  require_cluster "$name"
  cluster_running "$name" || die "未运行"
  [[ "$n" =~ ^[0-9]+$ ]] || die "回档快照数必须是数字"
  confirm "将回档 $n 个快照，在线玩家会重载世界。继续?" "n" || die "已取消"
  send_lua "$name" "c_rollback(${n})"
  log_ok "已请求回档 ${n} 个快照"
}

cmd_regenerate() {
  local name="$1"
  require_cluster "$name"
  cluster_running "$name" || die "运行中重置请先开服；停服清档请用: dstctl cluster reset $name"
  confirm "这将重置整个世界（不可恢复当前进度）！确认?" "n" || die "已取消"
  confirm "再次确认重置存档 $name ?" "n" || die "已取消"
  send_lua "$name" "c_regenerateworld()"
  log_ok "已请求重置世界"
}

cmd_season() {
  local name="$1" season="${2-}"
  require_cluster "$name"
  cluster_running "$name" || die "未运行"
  [[ "$season" =~ ^(autumn|winter|spring|summer)$ ]] || die "季节: autumn winter spring summer"
  send_lua "$name" "TheWorld:PushEvent(\"ms_setseason\", \"${season}\")"
  log_ok "已请求切换季节: $season"
}

cmd_skip() {
  local name="$1" what="${2:-day}"
  require_cluster "$name"
  cluster_running "$name" || die "未运行"
  case "$what" in
    day) send_lua "$name" "TheWorld:PushEvent(\"ms_nextcycle\")" ;;
    phase) send_lua "$name" "TheWorld:PushEvent(\"ms_nextphase\")" ;;
    *) die "用法: dstctl skip <存档> [day|phase]" ;;
  esac
  log_ok "已发送跳过: $what"
}
