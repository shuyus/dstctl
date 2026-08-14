#!/usr/bin/env bash
# 存档（cluster）创建、配置、名单、端口、令牌
# 编码: UTF-8

_render_template() {
  local src="$1" dest="$2"
  shift 2
  ensure_dir "$(dirname "$dest")"
  local content
  content="$(cat "$src")"
  local k v
  while [[ $# -gt 0 ]]; do
    k="$1"; v="$2"; shift 2
    content="${content//\{\{$k\}\}/$v}"
  done
  printf '%s\n' "$content" >"$dest"
}

_used_ports() {
  local f
  find "$CLUSTERS_DIR" -name 'server.ini' -o -name 'cluster.ini' 2>/dev/null \
    | while read -r f; do
        awk -F '=' '
          {
            sub(/\r/, "")
            k=$1; v=$2
            gsub(/[[:space:]]/, "", k)
            gsub(/[[:space:]]/, "", v)
            if (k=="server_port" || k=="authentication_port" || k=="master_server_port" || k=="master_port")
              print v
          }' "$f" 2>/dev/null
      done
}

_port_taken() {
  local p="$1"
  printf '%s\n' "${USED_PORTS:-}" | grep -qx "$p" && return 0
  port_in_use "$p"
}

_next_free() {
  local p="$1"
  while _port_taken "$p"; do
    p=$((p + 1))
    (( p < 65535 )) || die "无法分配端口"
  done
  echo "$p"
  USED_PORTS="${USED_PORTS}"$'\n'"$p"
}

allocate_ports() {
  USED_PORTS="$(_used_ports | sort -u)"
  PORT_MASTER_GAME="$(_next_free 10999)"
  PORT_CAVES_GAME="$(_next_free $((PORT_MASTER_GAME + 1)))"
  PORT_MASTER_STEAM="$(_next_free 27016)"
  PORT_CAVES_STEAM="$(_next_free $((PORT_MASTER_STEAM + 1)))"
  PORT_MASTER_AUTH="$(_next_free 8766)"
  PORT_CAVES_AUTH="$(_next_free $((PORT_MASTER_AUTH + 1)))"
  PORT_SHARD="$(_next_free 10888)"
}

_rand_key() {
  if have_cmd openssl; then
    openssl rand -hex 12
  else
    date +%s%N | sha256sum | cut -c1-24
  fi
}

cmd_cluster_create() {
  local name="${1-}"
  shift || true
  local display="" desc="" password="" players="$DEFAULT_MAX_PLAYERS"
  local mode="$DEFAULT_GAME_MODE" intention="$DEFAULT_INTENTION"
  local language="$DEFAULT_LANGUAGE" pvp="false" caves="$DEFAULT_CAVES"
  local token="" preset="SURVIVAL_TOGETHER" interactive=0

  if [[ -z "$name" || "$name" == "--interactive" ]]; then
    interactive=1
    echo "${C_BOLD}创建新存档${C_RESET}"
    [[ "$name" == "--interactive" ]] && name=""
    name="$(read_default "存档目录名（英文、数字、_、-）" "${name:-Cluster_1}")"
    display="$(read_default "房间显示名称" "$name")"
    desc="$(read_default "房间简介" "dstctl 托管的饥荒联机服务器")"
    password="$(read_default "房间密码（空=无密码）" "")"
    players="$(read_default "最大人数" "$players")"
    echo "模式: survival / endless / wilderness"
    mode="$(read_default "游戏模式" "$mode")"
    echo "意向: cooperative / social / competitive / madness"
    intention="$(read_default "服务器意向" "$intention")"
    pvp="$(read_default "开启 PVP (true/false)" "false")"
    caves="$(read_default "开启洞穴（地上+地下同机）(true/false)" "$caves")"
    language="$(read_default "语言" "$language")"
    token="$(read_default "cluster token（可留空稍后设置）" "")"
  else
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name|--display) display="$2"; shift 2 ;;
        --desc|--description) desc="$2"; shift 2 ;;
        --password) password="$2"; shift 2 ;;
        --players) players="$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        --intention) intention="$2"; shift 2 ;;
        --language) language="$2"; shift 2 ;;
        --pvp) pvp="$2"; shift 2 ;;
        --caves) caves=true; shift ;;
        --no-caves) caves=false; shift ;;
        --token) token="$2"; shift 2 ;;
        --preset) preset="$2"; shift 2 ;;
        *) die "未知参数: $1" ;;
      esac
    done
  fi

  valid_cluster_name "$name" || die "非法存档名: $name"
  cluster_exists "$name" && die "存档已存在: $name"
  [[ -n "$display" ]] || display="$name"
  [[ -n "$desc" ]] || desc="dstctl managed DST server"
  [[ "$mode" =~ ^(survival|endless|wilderness|lavaarena|quagmire)$ ]] || die "不支持的模式: $mode"
  [[ "$players" =~ ^[0-9]+$ ]] && (( players >= 1 && players <= 64 )) || die "人数需为 1-64"

  allocate_ports
  local key shard_enabled
  key="$(_rand_key)"
  if is_true "$caves"; then shard_enabled=true; else shard_enabled=false; fi

  local dir
  dir="$(cluster_dir "$name")"
  ensure_dir "$dir/Master"
  is_true "$caves" && ensure_dir "$dir/Caves"

  _render_template "${DSTCTL_ROOT}/templates/cluster.ini" "$dir/cluster.ini" \
    GAME_MODE "$mode" \
    MAX_PLAYERS "$players" \
    PVP "$pvp" \
    DISPLAY_NAME "$display" \
    DESCRIPTION "$desc" \
    PASSWORD "$password" \
    INTENTION "$intention" \
    LANGUAGE "$language" \
    SHARD_ENABLED "$shard_enabled" \
    MASTER_PORT "$PORT_SHARD" \
    CLUSTER_KEY "$key"

  _render_template "${DSTCTL_ROOT}/templates/server_master.ini" "$dir/Master/server.ini" \
    SERVER_PORT "$PORT_MASTER_GAME" \
    AUTH_PORT "$PORT_MASTER_AUTH" \
    STEAM_PORT "$PORT_MASTER_STEAM"

  cp -f "${DSTCTL_ROOT}/templates/worldgen_forest.lua" "$dir/Master/worldgenoverride.lua"
  if [[ "$preset" != "SURVIVAL_TOGETHER" ]]; then
    sed -i "s/SURVIVAL_TOGETHER/${preset}/" "$dir/Master/worldgenoverride.lua"
  fi

  if is_true "$caves"; then
    _render_template "${DSTCTL_ROOT}/templates/server_caves.ini" "$dir/Caves/server.ini" \
      SERVER_PORT "$PORT_CAVES_GAME" \
      AUTH_PORT "$PORT_CAVES_AUTH" \
      STEAM_PORT "$PORT_CAVES_STEAM"
    cp -f "${DSTCTL_ROOT}/templates/worldgen_caves.lua" "$dir/Caves/worldgenoverride.lua"
  fi

  : >"$dir/adminlist.txt"
  : >"$dir/whitelist.txt"
  : >"$dir/blocklist.txt"
  printf '# 每行一个 Steam 创意工坊模组 ID\n' >"$dir/mods.txt"
  printf 'return {\n}\n' >"$dir/Master/modoverrides.lua"
  is_true "$caves" && printf 'return {\n}\n' >"$dir/Caves/modoverrides.lua"

  chmod 600 "$dir/cluster.ini" 2>/dev/null || true
  meta_set "$name" caves "$(is_true "$caves" && echo true || echo false)"
  meta_set "$name" auto_restart false
  meta_set "$name" auto_backup true
  meta_set "$name" created "$(now)"
  meta_set "$name" motd ""
  meta_set "$name" webhook ""
  meta_set "$name" master_port "$PORT_MASTER_GAME"

  if [[ -n "$token" ]]; then
    printf '%s\n' "$(trim "$token")" >"$(cluster_token_file "$name")"
    chmod 600 "$(cluster_token_file "$name")"
  else
    : >"$(cluster_token_file "$name")"
    chmod 600 "$(cluster_token_file "$name")"
    log_warn "尚未设置 cluster token，联机开服前请执行: dstctl token set $name"
  fi

  log_ok "存档已创建: $name"
  echo "  目录:     $dir"
  echo "  显示名:   $display"
  echo "  模式:     $mode    人数: $players    洞穴: $caves"
  echo "  地上端口: $PORT_MASTER_GAME"
  is_true "$caves" && echo "  洞穴端口: $PORT_CAVES_GAME"
  echo "  分片端口: $PORT_SHARD (仅本机)"
}

cmd_cluster_list() {
  local name caves mode players disp st online port
    printf "%-18s %-22s %-10s %4s %4s %-12s %4s %6s\n" \
    "存档" "房间名" "模式" "人数" "洞穴" "状态" "运行" "端口"
  printf '%s\n' "--------------------------------------------------------------------------------"
  local any=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    any=1
    disp="$(ini_get "$(cluster_ini "$name")" NETWORK cluster_name "$name")"
    mode="$(ini_get "$(cluster_ini "$name")" GAMEPLAY game_mode "?")"
    players="$(ini_get "$(cluster_ini "$name")" GAMEPLAY max_players "?")"
    if cluster_has_caves "$name"; then caves="是"; else caves="否"; fi
    port="$(ini_get "$(shard_dir "$name" Master)/server.ini" NETWORK server_port "-")"
    if cluster_running "$name"; then
      st="运行中"
      online="yes"
    else
      st="已停止"
      online="-"
    fi
    printf "%-18s %-22s %-10s %4s %4s %-12s %4s %6s\n" \
      "$name" "$disp" "$mode" "$players" "$caves" "$st" "$online" "$port"
  done < <(list_cluster_names)
  (( any == 1 )) || echo "(还没有存档，使用 dstctl cluster create 创建)"
}

cmd_cluster_info() {
  local name="$1"
  require_cluster "$name"
  local dir ini
  dir="$(cluster_dir "$name")"
  ini="$(cluster_ini "$name")"
  echo "${C_BOLD}存档: $name${C_RESET}"
  echo "目录: $dir"
  echo "房间: $(ini_get "$ini" NETWORK cluster_name)"
  echo "简介: $(ini_get "$ini" NETWORK cluster_description)"
  echo "模式: $(ini_get "$ini" GAMEPLAY game_mode)   PVP: $(ini_get "$ini" GAMEPLAY pvp)"
  echo "人数: $(ini_get "$ini" GAMEPLAY max_players)   意向: $(ini_get "$ini" NETWORK cluster_intention)"
  echo "密码: $( [[ -n "$(ini_get "$ini" NETWORK cluster_password)" ]] && echo 已设置 || echo 无 )"
  echo "洞穴: $(cluster_has_caves "$name" && echo 开启 || echo 关闭)"
  echo "语言: $(ini_get "$ini" NETWORK cluster_language)"
  echo "Token: $( [[ -s "$(cluster_token_file "$name")" ]] && echo 已设置 || echo 未设置 )"
  echo "自动重启: $(meta_get "$name" auto_restart false)   启动备份: $(meta_get "$name" auto_backup true)"
  echo "创建时间: $(meta_get "$name" created -)"
  echo
  echo "端口:"
  echo "  Master 游戏=$(ini_get "$dir/Master/server.ini" NETWORK server_port)  Steam=$(ini_get "$dir/Master/server.ini" STEAM master_server_port)  Auth=$(ini_get "$dir/Master/server.ini" STEAM authentication_port)"
  if cluster_has_caves "$name"; then
    echo "  Caves  游戏=$(ini_get "$dir/Caves/server.ini" NETWORK server_port)  Steam=$(ini_get "$dir/Caves/server.ini" STEAM master_server_port)  Auth=$(ini_get "$dir/Caves/server.ini" STEAM authentication_port)"
    echo "  分片通信 master_port=$(ini_get "$ini" SHARD master_port)"
  fi
  echo
  echo "模组:"
  list_show "$dir/mods.txt"
  echo
  echo "管理员:"
  list_show "$dir/adminlist.txt"
}

cmd_cluster_edit() {
  local name="$1"
  require_cluster "$name"
  shift || true
  local ini
  ini="$(cluster_ini "$name")"
  if [[ $# -eq 0 ]]; then
    echo "可改项: name desc password players mode pvp intention language pause vote caves-toggle"
    echo "示例: dstctl cluster edit $name name \"新房间名\" players 8"
    return 0
  fi
  cluster_running "$name" && log_warn "存档正在运行，部分修改需重启后生效"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      name|display) ini_set "$ini" NETWORK cluster_name "$2"; shift 2 ;;
      desc|description) ini_set "$ini" NETWORK cluster_description "$2"; shift 2 ;;
      password) ini_set "$ini" NETWORK cluster_password "$2"; shift 2 ;;
      players) ini_set "$ini" GAMEPLAY max_players "$2"; shift 2 ;;
      mode) ini_set "$ini" GAMEPLAY game_mode "$2"; shift 2 ;;
      pvp) ini_set "$ini" GAMEPLAY pvp "$2"; shift 2 ;;
      intention) ini_set "$ini" NETWORK cluster_intention "$2"; shift 2 ;;
      language) ini_set "$ini" NETWORK cluster_language "$2"; shift 2 ;;
      pause) ini_set "$ini" GAMEPLAY pause_when_empty "$2"; shift 2 ;;
      vote) ini_set "$ini" GAMEPLAY vote_enabled "$2"; shift 2 ;;
      auto-restart) meta_set "$name" auto_restart "$2"; shift 2 ;;
      motd) meta_set "$name" motd "$2"; shift 2 ;;
      webhook) meta_set "$name" webhook "$2"; shift 2 ;;
      *) die "未知配置项: $1" ;;
    esac
  done
  log_ok "已更新存档配置: $name"
}

cmd_cluster_delete() {
  local name="$1"
  require_cluster "$name"
  cluster_running "$name" && die "请先停止存档: dstctl stop $name"
  confirm "确定删除存档 $name ? 此操作不可恢复（建议先 backup）" "n" || die "已取消"
  rm -rf "$(cluster_dir "$name")"
  log_ok "已删除存档 $name"
}

# 清档：删除世界进度 / 聊天 / 日志，保留房间、世界生成、模组与名单
cmd_cluster_reset() {
  local name="${1-}" skip_backup=0 yes=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-backup) skip_backup=1; shift ;;
      --yes|-y) yes=1; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done
  [[ -n "$name" ]] || die "用法: dstctl cluster reset <存档> [--yes] [--no-backup]"
  require_cluster "$name"
  cluster_running "$name" && die "请先停止存档: dstctl stop $name"
  if (( yes == 0 )); then
    echo "将删除 Master/Caves 下的 save、聊天记录和日志。"
    echo "保留: cluster.ini、server.ini、worldgenoverride.lua、leveldataoverride.lua、modoverrides.lua、mods.txt、Token 与名单。"
    confirm "确认重置存档 ${name} ?" "n" || die "已取消"
  fi
  if (( skip_backup == 0 )); then
    log_info "重置前自动备份..."
    cmd_backup_create "$name" "pre-reset" >/dev/null || log_warn "备份失败，继续重置"
  fi

  local dir shard d f
  dir="$(cluster_dir "$name")"
  for shard in Master Caves; do
    d="$(shard_dir "$name" "$shard")"
    [[ -d "$d" ]] || continue
    if [[ -d "${d}/save" ]]; then
      rm -rf "${d}/save"
      log_info "已删除 ${shard}/save"
    fi
    if [[ -d "${d}/backup" ]]; then
      rm -rf "${d}/backup"
      log_info "已删除 ${shard}/backup"
    fi
    find "$d" -maxdepth 1 -type f \( \
      -name 'server_log.txt' -o -name 'server_log_*.txt' -o \
      -name 'server_chat_log.txt' -o -name 'server_chat_log_*.txt' -o \
      -name 'chat_log.txt' \
    \) -print | while IFS= read -r f; do
      rm -f "$f"
      log_info "已删除 ${shard}/$(basename "$f")"
    done
  done
  find "$dir" -maxdepth 1 -type f \( \
    -name 'server_log.txt' -o -name 'server_log_*.txt' -o \
    -name 'server_chat_log.txt' -o -name 'server_chat_log_*.txt' \
  \) -delete 2>/dev/null || true

  log_ok "存档 ${name} 已重置。下次启动将按现有世界设置重新生成地图。"
}

cmd_cluster_clone() {
  local src="$1" dst="$2"
  require_cluster "$src"
  [[ -n "$dst" ]] || die "用法: dstctl cluster clone <源> <新存档名>"
  valid_cluster_name "$dst" || die "非法存档名: $dst"
  cluster_exists "$dst" && die "目标已存在: $dst"
  cluster_running "$src" && log_warn "源存档正在运行，克隆的是磁盘上的当前文件"
  cp -a "$(cluster_dir "$src")" "$(cluster_dir "$dst")"
  allocate_ports
  ini_set "$(cluster_ini "$dst")" SHARD master_port "$PORT_SHARD"
  ini_set "$(cluster_ini "$dst")" SHARD cluster_key "$(_rand_key)"
  ini_set "$(shard_dir "$dst" Master)/server.ini" NETWORK server_port "$PORT_MASTER_GAME"
  ini_set "$(shard_dir "$dst" Master)/server.ini" STEAM master_server_port "$PORT_MASTER_STEAM"
  ini_set "$(shard_dir "$dst" Master)/server.ini" STEAM authentication_port "$PORT_MASTER_AUTH"
  if [[ -f "$(shard_dir "$dst" Caves)/server.ini" ]]; then
    ini_set "$(shard_dir "$dst" Caves)/server.ini" NETWORK server_port "$PORT_CAVES_GAME"
    ini_set "$(shard_dir "$dst" Caves)/server.ini" STEAM master_server_port "$PORT_CAVES_STEAM"
    ini_set "$(shard_dir "$dst" Caves)/server.ini" STEAM authentication_port "$PORT_CAVES_AUTH"
  fi
  ini_set "$(cluster_ini "$dst")" NETWORK cluster_name "$(ini_get "$(cluster_ini "$dst")" NETWORK cluster_name) (clone)"
  meta_set "$dst" created "$(now)"
  meta_set "$dst" master_port "$PORT_MASTER_GAME"
  log_ok "已克隆 $src -> $dst（已重新分配端口与 cluster_key）"
}

cmd_token_set() {
  local name="$1" token="${2-}"
  require_cluster "$name"
  if [[ -z "$token" ]]; then
    echo "获取 Token: https://accounts.klei.com/account/game/servers?game=DontStarveTogether"
    token="$(read_default "粘贴 token" "")"
  fi
  [[ -n "$token" ]] || die "token 为空"
  token="$(trim "$token")"
  printf '%s\n' "$token" >"$(cluster_token_file "$name")"
  chmod 600 "$(cluster_token_file "$name")"
  log_ok "已写入 cluster_token.txt"
}

cmd_token_show() {
  local name="$1"
  require_cluster "$name"
  if [[ -s "$(cluster_token_file "$name")" ]]; then
    echo "已设置（出于安全不回显完整 token，长度=$(wc -c <"$(cluster_token_file "$name")" | tr -d ' ')）"
  else
    echo "未设置"
  fi
}

_list_cmd() {
  local which="$1" name="$2" action="${3-}" id="${4-}"
  require_cluster "$name"
  local file
  case "$which" in
    admin) file="$(cluster_dir "$name")/adminlist.txt" ;;
    whitelist) file="$(cluster_dir "$name")/whitelist.txt" ;;
    blacklist|block) file="$(cluster_dir "$name")/blocklist.txt" ;;
    *) die "未知名单: $which" ;;
  esac
  case "$action" in
    ""|list) echo "${which} ($name):"; list_show "$file" ;;
    add)
      [[ -n "$id" ]] || die "请提供 KU_xxxxxxxx"
      list_add "$file" "$id"
      if [[ "$which" == "whitelist" ]]; then
        local n
        n="$(grep -cE '^[^#[:space:]]' "$file" 2>/dev/null || echo 0)"
        ini_set "$(cluster_ini "$name")" NETWORK whitelist_slots "$n"
      fi
      log_ok "已添加到 ${which}: $id"
      cluster_running "$name" && log_warn "部分名单在运行时修改后，建议重启或配合 kick/ban 命令立即生效"
      ;;
    remove|del|rm)
      [[ -n "$id" ]] || die "请提供 KU_xxxxxxxx"
      list_remove "$file" "$id"
      if [[ "$which" == "whitelist" ]]; then
        local n
        n="$(grep -cE '^[^#[:space:]]' "$file" 2>/dev/null || echo 0)"
        ini_set "$(cluster_ini "$name")" NETWORK whitelist_slots "$n"
      fi
      log_ok "已从 ${which} 移除: $id"
      ;;
    *) die "用法: dstctl $which <存档> [list|add|remove] [KU_xxx]" ;;
  esac
}

cmd_admin() { _list_cmd admin "$@"; }
cmd_whitelist() { _list_cmd whitelist "$@"; }
cmd_blacklist() { _list_cmd blacklist "$@"; }

pick_cluster() {
  local names name i=1
  mapfile -t names < <(list_cluster_names)
  if [[ ${#names[@]} -eq 0 ]]; then
    die "还没有存档"
  fi
  if [[ ${#names[@]} -eq 1 ]]; then
    printf '%s' "${names[0]}"
    return 0
  fi
  echo "选择存档:" >&2
  for name in "${names[@]}"; do
    local mark=""
    cluster_running "$name" && mark=" [运行中]"
    printf "  %2d) %s%s\n" "$i" "$name" "$mark" >&2
    i=$((i + 1))
  done
  local sel
  read -r -p "编号: " sel || true
  [[ "$sel" =~ ^[0-9]+$ ]] || die "无效选择"
  (( sel >= 1 && sel <= ${#names[@]} )) || die "无效选择"
  printf '%s' "${names[sel-1]}"
}
