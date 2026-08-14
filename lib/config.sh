#!/usr/bin/env bash
# dstctl 路径与全局配置
# 编码: UTF-8

dstctl_load_config() {
  DST_ROOT="${DST_ROOT:-$HOME/dst}"
  STEAMCMD_DIR="${STEAMCMD_DIR:-$DST_ROOT/steamcmd}"
  GAME_DIR="${GAME_DIR:-$DST_ROOT/server}"
  KLEI_ROOT="${KLEI_ROOT:-$HOME/.klei}"
  CONF_DIR="${CONF_DIR:-DoNotStarveTogether}"
  UGC_DIR="${UGC_DIR:-$GAME_DIR/ugc_mods}"
  BACKUP_DIR="${BACKUP_DIR:-$DST_ROOT/backups}"
  DSTCTL_HOME="${DSTCTL_HOME:-$HOME/.dstctl}"
  DSTCTL_RUN_DIR="${DSTCTL_RUN_DIR:-$DSTCTL_HOME/run}"
  DSTCTL_LOG_DIR="${DSTCTL_LOG_DIR:-$DSTCTL_HOME/logs}"
  SESSION_PREFIX="${SESSION_PREFIX:-dst}"
  PROCESS_MUX="${PROCESS_MUX:-auto}"
  BACKUP_ON_START="${BACKUP_ON_START:-true}"
  BACKUP_KEEP="${BACKUP_KEEP:-10}"
  MOD_UPDATE_ON_START="${MOD_UPDATE_ON_START:-true}"
  MOD_UPDATE_TIMEOUT="${MOD_UPDATE_TIMEOUT:-600}"
  STOP_GRACE_SECONDS="${STOP_GRACE_SECONDS:-45}"
  START_WAIT_SECONDS="${START_WAIT_SECONDS:-90}"
  ANNOUNCE_ON_STOP="${ANNOUNCE_ON_STOP:-true}"
  DEFAULT_MAX_PLAYERS="${DEFAULT_MAX_PLAYERS:-6}"
  DEFAULT_GAME_MODE="${DEFAULT_GAME_MODE:-survival}"
  DEFAULT_INTENTION="${DEFAULT_INTENTION:-cooperative}"
  DEFAULT_LANGUAGE="${DEFAULT_LANGUAGE:-zh}"
  DEFAULT_CAVES="${DEFAULT_CAVES:-true}"
  WEBHOOK_URL="${WEBHOOK_URL:-}"
  WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-20}"
  PREFER_X64="${PREFER_X64:-true}"

  local f
  for f in \
    "${DSTCTL_ROOT}/conf/dstctl.conf" \
    "${DSTCTL_HOME}/dstctl.conf" \
    "/etc/dstctl.conf"
  do
    if [[ -f "$f" ]]; then
      # shellcheck disable=SC1090
      source "$f"
    fi
  done

  CLUSTERS_DIR="${KLEI_ROOT}/${CONF_DIR}"
  chmod +x "${DSTCTL_ROOT}/dstctl" "${DSTCTL_ROOT}/lib/run-shard.sh" 2>/dev/null || true
  ensure_dir "$DST_ROOT"
  ensure_dir "$DSTCTL_HOME"
  ensure_dir "$DSTCTL_RUN_DIR"
  ensure_dir "$DSTCTL_LOG_DIR"
  ensure_dir "$BACKUP_DIR"
  ensure_dir "$CLUSTERS_DIR"
}

cluster_dir() { echo "${CLUSTERS_DIR}/${1}"; }
cluster_ini() { echo "$(cluster_dir "$1")/cluster.ini"; }
cluster_token_file() { echo "$(cluster_dir "$1")/cluster_token.txt"; }
shard_dir() { echo "$(cluster_dir "$1")/${2}"; }
shard_log() { echo "$(shard_dir "$1" "$2")/server_log.txt"; }
pid_file() { echo "${DSTCTL_RUN_DIR}/${1}.${2}.pid"; }
session_name() { echo "${SESSION_PREFIX}.${1}.${2}"; }

# 客户端拷来的 leveldataoverride.lua 与建档时的 worldgenoverride.lua 不能共存：
# 专用服后加载 worldgenoverride，且 preset 会整份覆盖，导致你的世界设置变回默认。
prepare_world_overrides() {
  local name="$1"
  local shard d wgo ldo bak
  for shard in Master Caves; do
    d="$(shard_dir "$name" "$shard")"
    [[ -d "$d" ]] || continue
    wgo="${d}/worldgenoverride.lua"
    ldo="${d}/leveldataoverride.lua"
    bak="${d}/worldgenoverride.lua.dstctl.bak"
    if [[ -f "$ldo" && -f "$wgo" ]]; then
      mv -f "$wgo" "$bak"
      log_warn "${shard}: 已有 leveldataoverride.lua，已把 worldgenoverride.lua 改名为 .dstctl.bak，避免覆盖客户端世界设置"
    elif [[ ! -f "$ldo" && -f "$bak" && ! -f "$wgo" ]]; then
      mv -f "$bak" "$wgo"
      log_info "${shard}: 未找到 leveldataoverride.lua，已恢复 worldgenoverride.lua"
    fi
  done
}

cluster_exists() { [[ -f "$(cluster_ini "$1")" ]]; }

require_cluster() {
  local name="${1-}"
  [[ -n "$name" ]] || die "请指定存档名"
  valid_cluster_name "$name" || die "存档名只能包含字母、数字、下划线和短横线: $name"
  cluster_exists "$name" || die "存档不存在: $name"
}

list_cluster_names() {
  local d
  [[ -d "$CLUSTERS_DIR" ]] || return 0
  find "$CLUSTERS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | sort \
    | while read -r d; do
        [[ -f "${CLUSTERS_DIR}/${d}/cluster.ini" ]] && printf '%s\n' "$d"
      done
}

cluster_has_caves() {
  local name="$1"
  local m
  m="$(meta_get "$name" "caves" "")"
  if [[ -n "$m" ]]; then
    is_true "$m"
    return
  fi
  [[ -f "$(shard_dir "$name" "Caves")/server.ini" ]]
}

dst_bin_info() {
  if is_true "$PREFER_X64" && [[ -x "${GAME_DIR}/bin64/dontstarve_dedicated_server_nullrenderer_x64" ]]; then
    DST_BIN_DIR="${GAME_DIR}/bin64"
    DST_BIN="./dontstarve_dedicated_server_nullrenderer_x64"
    DST_ARCH="x64"
    return 0
  fi
  if [[ -x "${GAME_DIR}/bin/dontstarve_dedicated_server_nullrenderer" ]]; then
    DST_BIN_DIR="${GAME_DIR}/bin"
    DST_BIN="./dontstarve_dedicated_server_nullrenderer"
    DST_ARCH="x86"
    return 0
  fi
  return 1
}

require_game() {
  dst_bin_info || die "未找到饥荒服务端，请先执行: dstctl install"
}

game_version() {
  local vf="${GAME_DIR}/version.txt"
  if [[ -f "$vf" ]]; then
    tr -d '\r' <"$vf" | head -n 1
  else
    echo "未知"
  fi
}

detect_mux() {
  case "$PROCESS_MUX" in
    screen|tmux|fifo) echo "$PROCESS_MUX"; return ;;
  esac
  if have_cmd screen; then
    echo screen
  elif have_cmd tmux; then
    echo tmux
  else
    echo fifo
  fi
}

webhook_notify() {
  local text="$1"
  local url="${2:-$WEBHOOK_URL}"
  [[ -n "$url" ]] || return 0
  have_cmd curl || return 0
  local payload
  payload="$(printf '{"content":"%s"}' "$(lua_escape "$text")")"
  curl -sS -m 8 -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null 2>&1 || true
}
