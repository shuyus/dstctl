#!/usr/bin/env bash
# 进程管理：screen/tmux/fifo 启动、停止、重启
# 编码: UTF-8

cluster_running() {
  local name="$1"
  shard_running "$name" Master && return 0
  shard_running "$name" Caves && return 0
  return 1
}

shard_running() {
  local name="$1" shard="$2"
  local pf pid
  pf="$(pid_file "$name" "$shard")"
  if [[ -f "$pf" ]]; then
    pid="$(tr -d '[:space:]' <"$pf")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      if [[ -r "/proc/${pid}/cmdline" ]] && tr '\0' ' ' <"/proc/${pid}/cmdline" | grep -q -- "-cluster ${name}"; then
        return 0
      fi
      if kill -0 "$pid" 2>/dev/null && pgrep -f "dontstarve.*-cluster ${name}.*-shard ${shard}" >/dev/null 2>&1; then
        return 0
      fi
    fi
  fi
  pgrep -f "dontstarve.*-cluster ${name} .* -shard ${shard}" >/dev/null 2>&1
}

shard_pid() {
  local name="$1" shard="$2"
  local pf pid
  pf="$(pid_file "$name" "$shard")"
  if [[ -f "$pf" ]]; then
    pid="$(tr -d '[:space:]' <"$pf")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi
  pgrep -f "dontstarve.*-cluster ${name} .* -shard ${shard}" | head -n 1
}

running_clusters() {
  local name
  while IFS= read -r name; do
    cluster_running "$name" && printf '%s\n' "$name"
  done < <(list_cluster_names)
}

_fifo_dir() { echo "${DSTCTL_RUN_DIR}/fifo"; }

mux_session_exists() {
  local sess="$1" mux="${2:-$(detect_mux)}"
  case "$mux" in
    screen) screen -ls 2>/dev/null | grep -qE "[0-9]+\.${sess}[[:space:]]" ;;
    tmux) tmux has-session -t "$sess" 2>/dev/null ;;
    fifo)
      local name shard
      name="${sess#${SESSION_PREFIX}.}"
      shard="${name##*.}"
      name="${name%.*}"
      shard_running "$name" "$shard"
      ;;
  esac
}

_start_in_mux() {
  local sess="$1"
  shift
  local mux
  mux="$(detect_mux)"
  case "$mux" in
    screen)
      have_cmd screen || die "未安装 screen"
      screen -dmS "$sess" "$@"
      ;;
    tmux)
      have_cmd tmux || die "未安装 tmux"
      local q=""
      printf -v q '%q ' "$@"
      tmux new-session -d -s "$sess" "exec ${q}"
      ;;
    fifo)
      local fifo="${DSTCTL_RUN_DIR}/fifo/${sess}.in"
      ensure_dir "$(dirname "$fifo")"
      [[ -p "$fifo" ]] || mkfifo -m 600 "$fifo"
      tail -f "$fifo" | "$@" &
      printf '\n' >"$fifo" &
      ;;
  esac
}

mux_send() {
  local sess="$1" text="$2"
  local mux
  mux="$(detect_mux)"
  case "$mux" in
    screen)
      mux_session_exists "$sess" screen || return 1
      screen -S "$sess" -p 0 -X stuff "${text}"$'\r'
      ;;
    tmux)
      mux_session_exists "$sess" tmux || return 1
      tmux send-keys -t "$sess" "$text" Enter
      ;;
    fifo)
      local fifo="${DSTCTL_RUN_DIR}/fifo/${sess}.in"
      [[ -p "$fifo" ]] || return 1
      printf '%s\n' "$text" >"$fifo"
      ;;
  esac
}

mux_attach() {
  local sess="$1"
  local mux
  mux="$(detect_mux)"
  case "$mux" in
    screen)
      echo "附加到 screen 会话 $sess （退出请按 Ctrl+A 再按 D）"
      screen -d -r "$sess" || screen -r "$sess"
      ;;
    tmux)
      echo "附加到 tmux 会话 $sess （退出请按 Ctrl+B 再按 D）"
      tmux attach -t "$sess"
      ;;
    fifo)
      die "fifo 模式不支持交互附加，请用 dstctl logs / dstctl cmd"
      ;;
  esac
}

_shard_argv() {
  local name="$1" shard="$2"
  SHARD_ARGV=(
    bash
    "${DSTCTL_ROOT}/lib/run-shard.sh"
    "$(pid_file "$name" "$shard")"
    "$DST_BIN_DIR"
    "${DST_BIN_DIR}/${DST_BIN#./}"
    -console
    -persistent_storage_root "$KLEI_ROOT"
    -conf_dir "$CONF_DIR"
    -cluster "$name"
    -shard "$shard"
    -ugc_directory "$UGC_DIR"
    -skip_update_server_mods
    -backup_logs
  )
}

_wait_shard_ready() {
  local name="$1" shard="$2" timeout="${3:-$START_WAIT_SECONDS}"
  local logf t=0
  logf="$(shard_log "$name" "$shard")"
  while (( t < timeout )); do
    if [[ -f "$logf" ]]; then
      if grep -qE 'Account Failed|Failed to authenticate|E_EXPIRED_TOKEN' "$logf"; then
        log_error "$shard 令牌无效或认证失败，请检查 cluster_token.txt"
        return 1
      fi
      if grep -qE 'Sim paused|World already exists|Shard registered|Registering master server|Success! Loaded' "$logf"; then
        return 0
      fi
    fi
    shard_running "$name" "$shard" || { sleep 1; t=$((t + 1)); continue; }
    sleep 1
    t=$((t + 1))
  done
  log_warn "$shard 在 ${timeout}s 内未检测到就绪日志，进程可能仍在生成世界"
  return 0
}

preflight_cluster() {
  local name="$1"
  require_cluster "$name"
  require_game
  [[ -s "$(cluster_token_file "$name")" ]] || die "缺少 cluster token，无法联机开服。dstctl token set $name"
  local ini port
  ini="$(shard_dir "$name" Master)/server.ini"
  port="$(ini_get "$ini" NETWORK server_port)"
  if ! shard_running "$name" Master && port_in_use "$port"; then
    die "端口 $port 已被占用"
  fi
  if cluster_has_caves "$name"; then
    port="$(ini_get "$(shard_dir "$name" Caves)/server.ini" NETWORK server_port)"
    if ! shard_running "$name" Caves && port_in_use "$port"; then
      die "洞穴端口 $port 已被占用"
    fi
  fi
  local disk
  disk="$(df -PB1 "$(cluster_dir "$name")" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "$disk" ]] && (( disk < 500000000 )); then
    log_warn "磁盘可用空间较低: $(bytes_human "$disk")"
  fi
  prepare_world_overrides "$name"
}

cmd_start() {
  local name="${1-}" skip_mods=0 skip_backup=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-mods|--no-update-mods) skip_mods=1; shift ;;
      --skip-backup) skip_backup=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ -n "$name" ]] || die "用法: dstctl start <存档>"
  require_linux
  preflight_cluster "$name"
  cluster_running "$name" && die "存档已在运行: $name"

  if (( skip_backup == 0 )) && is_true "$(meta_get "$name" auto_backup "$BACKUP_ON_START")"; then
    log_info "启动前自动备份..."
    cmd_backup_create "$name" "prestart" || log_warn "备份失败，继续开服"
  fi

  if (( skip_mods == 0 )) && is_true "$MOD_UPDATE_ON_START"; then
    update_server_mods "$name" || {
      confirm "模组更新失败，仍要开服?" "y" || die "已取消"
    }
  else
    prepare_cluster_mods "$name"
  fi

  local sess
  sess="$(session_name "$name" Master)"
  _shard_argv "$name" Master
  log_info "启动地上世界 Master ..."
  _start_in_mux "$sess" "${SHARD_ARGV[@]}"
  sleep 2
  shard_running "$name" Master || die "Master 进程启动失败，请查看 $(shard_log "$name" Master)"
  _wait_shard_ready "$name" Master

  if cluster_has_caves "$name"; then
    sess="$(session_name "$name" Caves)"
    _shard_argv "$name" Caves
    log_info "启动洞穴世界 Caves ..."
    _start_in_mux "$sess" "${SHARD_ARGV[@]}"
    sleep 2
    shard_running "$name" Caves || log_warn "Caves 进程可能未起来，请检查日志"
    _wait_shard_ready "$name" Caves
  fi

  local motd
  motd="$(meta_get "$name" motd "")"
  if [[ -n "$motd" ]]; then
    sleep 2
    send_lua "$name" "c_announce(\"$(lua_escape "$motd")\")" || true
  fi
  webhook_notify "[DST] 存档 ${name} 已启动" "$(meta_get "$name" webhook "$WEBHOOK_URL")"
  log_ok "存档 $name 已启动"
  cmd_status "$name" || true
}

_shutdown_shard() {
  local name="$1" shard="$2" save="${3:-true}"
  local sess pid
  sess="$(session_name "$name" "$shard")"
  if shard_running "$name" "$shard"; then
    mux_send "$sess" "c_shutdown(${save})" || true
  fi
  local t=0 grace="$STOP_GRACE_SECONDS"
  while shard_running "$name" "$shard" && (( t < grace )); do
    sleep 1
    t=$((t + 1))
  done
  if shard_running "$name" "$shard"; then
    pid="$(shard_pid "$name" "$shard")"
    log_warn "$shard 未在 ${grace}s 内退出，发送 SIGTERM ($pid)"
    [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    sleep 5
  fi
  if shard_running "$name" "$shard"; then
    pid="$(shard_pid "$name" "$shard")"
    log_warn "$shard 仍在运行，发送 SIGKILL"
    [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$(pid_file "$name" "$shard")"
  local mux
  mux="$(detect_mux)"
  case "$mux" in
    screen) screen -S "$sess" -X quit >/dev/null 2>&1 || true ;;
    tmux) tmux kill-session -t "$sess" >/dev/null 2>&1 || true ;;
  esac
}

_kill_shard() {
  local name="$1" shard="$2"
  local sess pid p
  sess="$(session_name "$name" "$shard")"
  pid="$(shard_pid "$name" "$shard")"
  if [[ -n "$pid" ]]; then
    log_info "kill $shard pid=$pid"
    kill -KILL "$pid" 2>/dev/null || true
  fi
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    kill -KILL "$p" 2>/dev/null || true
  done < <(pgrep -f "dontstarve.*-cluster ${name} .* -shard ${shard}" 2>/dev/null || true)
  rm -f "$(pid_file "$name" "$shard")"
  local mux
  mux="$(detect_mux)"
  case "$mux" in
    screen) screen -S "$sess" -X quit >/dev/null 2>&1 || true ;;
    tmux) tmux kill-session -t "$sess" >/dev/null 2>&1 || true ;;
  esac
}

_ask_stop_mode() {
  echo "关闭方式:" >&2
  echo "  1) 正常关闭（保存世界，通知玩家）" >&2
  echo "  2) 直接 kill 进程（立即结束，不保证保存）" >&2
  local sel
  read -r -p "选择 [1]: " sel || true
  case "${sel:-1}" in
    2|k|K|kill|KILL) printf '%s' kill ;;
    *) printf '%s' graceful ;;
  esac
}

cmd_stop() {
  local name="${1-}" save=true announce=1 mode="" no_prompt=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kill|-k|--force|-f) mode=kill; shift ;;
      --graceful|--normal) mode=graceful; shift ;;
      --no-save) save=false; shift ;;
      --no-announce) announce=0; shift ;;
      --no-prompt) no_prompt=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ -n "$name" ]] || die "用法: dstctl stop <存档> [--graceful|--kill]"
  require_cluster "$name"
  cluster_running "$name" || { log_warn "存档未在运行: $name"; return 0; }

  if [[ -z "$mode" ]]; then
    if [[ -t 0 && "$no_prompt" -eq 0 ]]; then
      mode="$(_ask_stop_mode)"
    else
      mode=graceful
    fi
  fi

  if [[ "$mode" == "kill" ]]; then
    log_warn "正在强制结束进程（不走保存流程）..."
    cluster_has_caves "$name" && _kill_shard "$name" Caves
    _kill_shard "$name" Master
    webhook_notify "[DST] 存档 ${name} 已强制停止" "$(meta_get "$name" webhook "$WEBHOOK_URL")"
    log_ok "存档 $name 已 kill"
    return 0
  fi

  if (( announce == 1 )) && is_true "$ANNOUNCE_ON_STOP"; then
    send_lua "$name" "c_announce(\"服务器即将关闭，正在保存世界...\")" || true
    sleep 3
  fi
  send_lua "$name" "c_save()" || true
  sleep 2
  log_info "停止洞穴..."
  cluster_has_caves "$name" && _shutdown_shard "$name" Caves "$save"
  log_info "停止地上..."
  _shutdown_shard "$name" Master "$save"
  webhook_notify "[DST] 存档 ${name} 已停止" "$(meta_get "$name" webhook "$WEBHOOK_URL")"
  log_ok "存档 $name 已停止"
}

cmd_stop_all() {
  local extra=("$@")
  local has_mode=0
  local a
  for a in "${extra[@]}"; do
    case "$a" in
      --kill|-k|--force|-f|--graceful|--normal) has_mode=1 ;;
    esac
  done
  extra+=(--no-prompt)
  if (( has_mode == 0 )) && [[ -t 0 ]]; then
    extra+=(--"$(_ask_stop_mode)")
  fi
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    cmd_stop "$n" "${extra[@]}"
  done < <(running_clusters)
}

cmd_restart() {
  local name="${1-}"
  shift || true
  [[ -n "$name" ]] || die "用法: dstctl restart <存档> [--kill|--graceful]"
  local stop_args=(--no-announce --no-prompt) start_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kill|-k|--force|-f) stop_args+=(--kill); shift ;;
      --graceful|--normal) stop_args+=(--graceful); shift ;;
      *) start_args+=("$1"); shift ;;
    esac
  done
  if cluster_running "$name"; then
    if [[ "${stop_args[*]}" != *"--kill"* ]]; then
      send_lua "$name" "c_announce(\"服务器即将重启，请稍候...\")" || true
      sleep 3
      stop_args+=(--graceful)
    fi
    cmd_stop "$name" "${stop_args[@]}"
  fi
  cmd_start "$name" "${start_args[@]}"
}

cmd_attach() {
  local name="${1-}" shard="${2:-Master}"
  require_cluster "$name"
  [[ "$shard" == "Master" || "$shard" == "Caves" ]] || die "shard 只能是 Master 或 Caves"
  shard_running "$name" "$shard" || die "$shard 未运行"
  mux_attach "$(session_name "$name" "$shard")"
}

cmd_start_all() {
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    cluster_running "$n" && continue
    log_info "启动 $n"
    cmd_start "$n" "$@" || log_error "启动 $n 失败"
  done < <(list_cluster_names)
}
