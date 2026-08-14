#!/usr/bin/env bash
# 崩溃自动拉起、定时重启辅助
# 编码: UTF-8

cmd_watchdog() {
  local action="${1:-run}"
  case "$action" in
    run|start) _watchdog_loop ;;
    once) _watchdog_tick ;;
    systemd) _watchdog_install_systemd ;;
    cron) _watchdog_print_cron ;;
    *) die "用法: dstctl watchdog [run|once|systemd|cron]" ;;
  esac
}

_watchdog_targets() {
  local name flag
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    flag="$(meta_get "$name" auto_restart false)"
    is_true "$flag" && printf '%s\n' "$name"
  done < <(list_cluster_names)
}

_watchdog_tick() {
  local name pid logf
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if cluster_running "$name"; then
      if cluster_has_caves "$name" && shard_running "$name" Master && ! shard_running "$name" Caves; then
        log_warn "看门狗: $name 洞穴进程消失，尝试补拉 Caves"
        webhook_notify "[DST] ${name} 洞穴崩溃，正在拉起" "$(meta_get "$name" webhook "$WEBHOOK_URL")"
        local sess
        require_game
        sess="$(session_name "$name" Caves)"
        _shard_argv "$name" Caves
        _start_in_mux "$sess" "${SHARD_ARGV[@]}" || true
      fi
      continue
    fi
    log_warn "看门狗: 存档 $name 已停止，自动重启"
    webhook_notify "[DST] ${name} 异常停止，正在自动重启" "$(meta_get "$name" webhook "$WEBHOOK_URL")"
    cmd_start "$name" --skip-backup || log_error "看门狗重启 $name 失败"
  done < <(_watchdog_targets)
}

_watchdog_loop() {
  require_linux
  log_info "看门狗启动，间隔 ${WATCHDOG_INTERVAL}s ，目标: $(_watchdog_targets | tr '\n' ' ' || echo 无)"
  echo $$ >"${DSTCTL_RUN_DIR}/watchdog.pid"
  trap 'rm -f "${DSTCTL_RUN_DIR}/watchdog.pid"; exit 0' INT TERM
  while true; do
    _watchdog_tick || true
    sleep "$WATCHDOG_INTERVAL"
  done
}

_watchdog_install_systemd() {
  local unit="${HOME}/.config/systemd/user/dstctl-watchdog.service"
  ensure_dir "$(dirname "$unit")"
  cat >"$unit" <<EOF
[Unit]
Description=dstctl Don't Starve Together watchdog
After=network-online.target

[Service]
Type=simple
ExecStart=${DSTCTL_ROOT}/dstctl watchdog run
Restart=always
RestartSec=10
Environment=LANG=en_US.UTF-8

[Install]
WantedBy=default.target
EOF
  log_ok "已写入 $unit"
  echo "启用: systemctl --user daemon-reload && systemctl --user enable --now dstctl-watchdog"
}

_watchdog_print_cron() {
  cat <<EOF
# 每 2 分钟检查一次自动重启存档
*/2 * * * * ${DSTCTL_ROOT}/dstctl watchdog once >>${DSTCTL_LOG_DIR}/watchdog.log 2>&1

# 每天 04:30 备份全部存档
30 4 * * * ${DSTCTL_ROOT}/dstctl backup all daily >>${DSTCTL_LOG_DIR}/backup.log 2>&1

# 每天 05:00 滚动重启（需自行改存档名，或使用 dstctl restart）
# 0 5 * * * ${DSTCTL_ROOT}/dstctl restart 存档名 >>${DSTCTL_LOG_DIR}/restart.log 2>&1
EOF
}

cmd_systemd_unit() {
  local name="${1-}"
  require_cluster "$name"
  local unit="${HOME}/.config/systemd/user/dst-${name}.service"
  ensure_dir "$(dirname "$unit")"
  cat >"$unit" <<EOF
[Unit]
Description=Don't Starve Together cluster ${name}
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${DSTCTL_ROOT}/dstctl start ${name}
ExecStop=${DSTCTL_ROOT}/dstctl stop ${name}
TimeoutStartSec=300
TimeoutStopSec=90
Environment=LANG=en_US.UTF-8

[Install]
WantedBy=default.target
EOF
  log_ok "已生成 $unit"
  echo "启动: systemctl --user daemon-reload && systemctl --user enable --now dst-${name}"
}
