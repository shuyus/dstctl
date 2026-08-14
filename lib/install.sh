#!/usr/bin/env bash
# 依赖 / SteamCMD / 饥荒服务端安装与自检
# 编码: UTF-8

dstctl_install_deps() {
  require_linux
  log_info "安装系统依赖..."
  if have_cmd apt-get; then
    sudo_run dpkg --add-architecture i386 || true
    sudo_run apt-get update -y
    local pkgs=(
      ca-certificates wget curl tar gzip unzip screen tmux procps iproute2
      lib32gcc-s1 lib32stdc++6 libcurl4 libsdl2-2.0-0
      libcurl3-gnutls:i386 libcurl4-gnutls-dev:i386 libsdl2-2.0-0:i386
    )
    local p
    for p in "${pkgs[@]}"; do
      sudo_run apt-get install -y "$p" >/dev/null 2>&1 && log_ok "已安装 $p" || log_debug "跳过 $p"
    done
  elif have_cmd dnf; then
    sudo_run dnf install -y glibc.i686 libstdc++.i686 libcurl.i686 libcurl screen tmux wget tar gzip unzip procps-ng iproute || \
      sudo_run dnf install -y glibc.i686 libstdc++ libcurl screen tmux wget tar
  elif have_cmd yum; then
    sudo_run yum install -y glibc.i686 libstdc++.i686 libcurl.i686 screen tmux wget tar gzip unzip
  elif have_cmd pacman; then
    sudo_run pacman -Sy --noconfirm --needed lib32-gcc-libs lib32-libcurl-gnutls screen tmux wget tar gzip unzip
  else
    log_warn "未能识别包管理器，请手动安装: wget curl tar screen lib32gcc / libcurl"
  fi
  log_ok "依赖安装步骤完成"
}

dstctl_install_steamcmd() {
  require_linux
  ensure_dir "$STEAMCMD_DIR"
  if [[ -x "${STEAMCMD_DIR}/steamcmd.sh" ]]; then
    log_info "SteamCMD 已存在: $STEAMCMD_DIR"
  else
    log_info "下载 SteamCMD..."
    local tgz="${STEAMCMD_DIR}/steamcmd_linux.tar.gz"
    wget -q -O "$tgz" "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
      || curl -fsSL -o "$tgz" "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
      || die "下载 SteamCMD 失败"
    tar -xzf "$tgz" -C "$STEAMCMD_DIR"
    rm -f "$tgz"
  fi
  chmod +x "${STEAMCMD_DIR}/steamcmd.sh"
  log_info "初始化 SteamCMD（首次会自我更新）..."
  "${STEAMCMD_DIR}/steamcmd.sh" +quit || true
  log_ok "SteamCMD 就绪"
}

dstctl_fix_steamclient() {
  local src32 src64 dst32 dst64
  src32="${STEAMCMD_DIR}/linux32/steamclient.so"
  src64="${STEAMCMD_DIR}/linux64/steamclient.so"
  [[ -f "$src32" ]] || src32="${HOME}/.steam/steamcmd/linux32/steamclient.so"
  [[ -f "$src64" ]] || src64="${HOME}/.steam/steamcmd/linux64/steamclient.so"
  dst32="${GAME_DIR}/bin/lib32/steamclient.so"
  dst64="${GAME_DIR}/bin64/lib64/steamclient.so"
  if [[ -f "$src32" && -d "$(dirname "$dst32")" ]]; then
    cp -f "$src32" "$dst32"
    log_ok "已修复 bin/lib32/steamclient.so"
  fi
  if [[ -f "$src64" ]]; then
    ensure_dir "$(dirname "$dst64")"
    cp -f "$src64" "$dst64"
    log_ok "已修复 bin64/lib64/steamclient.so"
  fi
}

dstctl_install_game() {
  require_linux
  [[ -x "${STEAMCMD_DIR}/steamcmd.sh" ]] || die "请先安装 SteamCMD"
  ensure_dir "$GAME_DIR"
  log_info "安装/更新饥荒联机版服务端 (AppID 343050) 到 $GAME_DIR"
  log_warn "可能需要数分钟，请保持网络畅通"
  with_lock steamcmd \
    "${STEAMCMD_DIR}/steamcmd.sh" \
      +force_install_dir "$GAME_DIR" \
      +login anonymous \
      +app_update 343050 validate \
      +quit
  dstctl_fix_steamclient
  ensure_dir "$UGC_DIR"
  ensure_dir "${GAME_DIR}/mods"
  if [[ ! -f "${GAME_DIR}/mods/dedicated_server_mods_setup.lua" ]]; then
    printf '-- dstctl 自动维护，请勿手改（或改完后用 dstctl mods sync）\n' \
      >"${GAME_DIR}/mods/dedicated_server_mods_setup.lua"
  fi
  dst_bin_info || die "服务端安装完成但未找到可执行文件"
  log_ok "服务端已就绪 ($DST_ARCH)  版本: $(game_version)"
}

cmd_install() {
  require_linux
  dstctl_install_deps
  dstctl_install_steamcmd
  dstctl_install_game
  log_ok "安装完成。下一步: dstctl cluster create <存档名>  或运行 dstctl 进入菜单"
}

cmd_update() {
  require_linux
  require_cmd wget || true
  [[ -x "${STEAMCMD_DIR}/steamcmd.sh" ]] || die "未安装 SteamCMD，请先 dstctl install"
  local running
  running="$(running_clusters || true)"
  if [[ -n "$running" ]]; then
    log_warn "以下存档正在运行，更新服务端前建议全部停服:"
    printf '%s\n' "$running"
    confirm "仍要继续更新?" "n" || die "已取消"
  fi
  dstctl_install_game
}

cmd_doctor() {
  echo "${C_BOLD}dstctl 环境自检${C_RESET}  v${DSTCTL_VERSION}"
  echo "----------------------------------------"
  printf "系统:        %s\n" "$(uname -srm 2>/dev/null || echo unknown)"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf "发行版:      %s\n" "${PRETTY_NAME:-$ID}"
  fi
  printf "用户:        %s (uid=%s)\n" "$(id -un)" "$(id -u)"
  printf "Locale:      %s\n" "${LANG:-未设置}"
  printf "Bash:        %s\n" "${BASH_VERSION}"
  echo
  local ok=0 warn=0 err=0
  _chk() {
    local title="$1" st="$2" detail="$3"
    case "$st" in
      ok)   printf " %sOK%s    %-18s %s\n" "$C_GREEN" "$C_RESET" "$title" "$detail"; ok=$((ok+1)) ;;
      warn) printf " %sWARN%s  %-18s %s\n" "$C_YELLOW" "$C_RESET" "$title" "$detail"; warn=$((warn+1)) ;;
      err)  printf " %sFAIL%s  %-18s %s\n" "$C_RED" "$C_RESET" "$title" "$detail"; err=$((err+1)) ;;
    esac
  }
  is_linux && _chk "Linux" ok "$(uname -s)" || _chk "Linux" err "$(uname -s)"
  if have_cmd wget || have_cmd curl; then _chk "下载工具" ok "wget/curl"; else _chk "下载工具" err "需要 wget 或 curl"; fi
  have_cmd screen && _chk "screen" ok "$(screen --version 2>/dev/null | head -n1)" || _chk "screen" warn "未安装，将尝试 tmux/fifo"
  have_cmd tmux && _chk "tmux" ok "$(tmux -V 2>/dev/null)" || _chk "tmux" warn "未安装"
  have_cmd flock && _chk "flock" ok "可用" || _chk "flock" warn "无 flock，将使用 pid 锁"
  [[ -x "${STEAMCMD_DIR}/steamcmd.sh" ]] && _chk "SteamCMD" ok "$STEAMCMD_DIR" || _chk "SteamCMD" err "未安装"
  if dst_bin_info; then
    _chk "服务端" ok "$DST_ARCH $(game_version)  $DST_BIN_DIR"
    if [[ -f "${DST_BIN_DIR}/${DST_BIN#./}" ]] || [[ -x "${DST_BIN_DIR}/${DST_BIN#./}" ]]; then
      :
    fi
    if have_cmd ldd; then
      local missing
      missing="$(ldd "${DST_BIN_DIR}/${DST_BIN#./}" 2>/dev/null | grep 'not found' || true)"
      if [[ -n "$missing" ]]; then
        _chk "动态库" err "$missing"
      else
        _chk "动态库" ok "ldd 通过"
      fi
    fi
  else
    _chk "服务端" err "未安装"
  fi
  [[ -f "${GAME_DIR}/bin64/lib64/steamclient.so" || -f "${GAME_DIR}/bin/lib32/steamclient.so" ]] \
    && _chk "steamclient.so" ok "已部署" \
    || _chk "steamclient.so" warn "缺失可能导致模组无法下载，执行 dstctl update 可尝试修复"
  [[ -d "$CLUSTERS_DIR" ]] && _chk "存档目录" ok "$CLUSTERS_DIR" || _chk "存档目录" warn "尚未创建"
  local disk
  disk="$(df -PB1 "$DST_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "$disk" ]]; then
    if (( disk < 3000000000 )); then
      _chk "磁盘空间" warn "$(bytes_human "$disk") 可用（建议至少 3GB）"
    else
      _chk "磁盘空间" ok "$(bytes_human "$disk") 可用"
    fi
  fi
  echo
  local n=0 r=0
  n="$(list_cluster_names | wc -l | tr -d ' ')"
  r="$(running_clusters | wc -l | tr -d ' ')"
  printf "存档数: %s    运行中: %s\n" "$n" "$r"
  echo "----------------------------------------"
  printf "结果: %s通过 %s  %s警告 %s  %s失败 %s\n" "$C_GREEN" "$ok" "$C_YELLOW" "$warn" "$C_RED" "$err"
  (( err == 0 ))
}

cmd_quickstart() {
  require_linux
  echo "${C_BOLD}饥荒联机版 快速开服向导${C_RESET}"
  echo "将依次: 安装环境 -> 创建存档 -> 填写 Token -> 启动"
  confirm "开始?" "y" || return 0
  cmd_install
  local name
  name="$(read_default "存档目录名（英文）" "Cluster_1")"
  cmd_cluster_create "$name"
  echo
  echo "请到 Klei 账户后台生成服务器令牌:"
  echo "  https://accounts.klei.com/account/game/servers?game=DontStarveTogether"
  echo "或在游戏控制台执行: TheNet:GenerateClusterToken()"
  local token
  token="$(read_default "粘贴 cluster token（可稍后 dstctl token set）" "")"
  if [[ -n "$token" ]]; then
    cmd_token_set "$name" "$token"
  fi
  if confirm "现在启动存档 ${name}?" "y"; then
    cmd_start "$name"
  fi
}
