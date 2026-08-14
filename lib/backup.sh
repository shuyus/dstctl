#!/usr/bin/env bash
# 备份、恢复、导出
# 编码: UTF-8

cmd_backup_create() {
  local name="${1-}" tag="${2:-manual}"
  require_cluster "$name"
  ensure_dir "${BACKUP_DIR}/${name}"
  local dest
  dest="${BACKUP_DIR}/${name}/${name}-$(now_id)-${tag}.tar.gz"
  log_info "备份 $name -> $dest"
  tar -C "$CLUSTERS_DIR" -czf "$dest" "$name"
  log_ok "备份完成 ($(bytes_human "$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest")"))"
  _backup_rotate "$name"
  echo "$dest"
}

_backup_rotate() {
  local name="$1"
  local keep="${BACKUP_KEEP:-10}"
  local dir="${BACKUP_DIR}/${name}"
  [[ -d "$dir" ]] || return 0
  local n
  n="$(find "$dir" -maxdepth 1 -name '*.tar.gz' | wc -l | tr -d ' ')"
  if (( n > keep )); then
    find "$dir" -maxdepth 1 -name '*.tar.gz' -printf '%T@ %p\n' \
      | sort -n \
      | head -n $((n - keep)) \
      | awk '{print $2}' \
      | while read -r old; do
          rm -f "$old"
          log_info "轮转删除旧备份: $(basename "$old")"
        done
  fi
}

cmd_backup_list() {
  local name="${1-}"
  if [[ -z "$name" ]]; then
    find "$BACKUP_DIR" -name '*.tar.gz' -printf '%P %s %TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort || \
      find "$BACKUP_DIR" -name '*.tar.gz' | sort
    return 0
  fi
  require_cluster "$name" 2>/dev/null || true
  local dir="${BACKUP_DIR}/${name}"
  [[ -d "$dir" ]] || { echo "(无备份)"; return 0; }
  find "$dir" -maxdepth 1 -name '*.tar.gz' -printf '%f\t%s\t%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort | \
    awk -F '\t' '{ printf "%-56s %10.1f MB  %s\n", $1, $2/1024/1024, $3 }'
}

cmd_backup_restore() {
  local name="$1" file="${2-}"
  [[ -n "$name" ]] || die "用法: dstctl backup restore <存档> <备份文件>"
  cluster_running "$name" && die "请先停服再恢复"
  if [[ -z "$file" ]]; then
    cmd_backup_list "$name"
    file="$(read_default "输入备份文件名" "")"
  fi
  [[ -n "$file" ]] || die "未指定备份"
  [[ -f "$file" ]] || file="${BACKUP_DIR}/${name}/${file}"
  [[ -f "$file" ]] || die "找不到备份: $file"
  confirm "将用备份覆盖存档 $name ，确认?" "n" || die "已取消"
  cmd_backup_create "$name" "pre-restore" >/dev/null || true
  rm -rf "$(cluster_dir "$name")"
  tar -C "$CLUSTERS_DIR" -xzf "$file"
  log_ok "已从备份恢复: $file"
}

cmd_backup_all() {
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    cmd_backup_create "$n" "${1:-cron}" >/dev/null
  done < <(list_cluster_names)
  log_ok "全部存档备份完成"
}

cmd_export() {
  local name="$1" dest="${2-}"
  require_cluster "$name"
  [[ -n "$dest" ]] || dest="./${name}-$(now_id).tar.gz"
  tar -C "$CLUSTERS_DIR" -czf "$dest" "$name"
  log_ok "已导出到 $dest"
}

cmd_import() {
  local file="$1"
  [[ -f "$file" ]] || die "找不到文件: $file"
  tar -tzf "$file" >/dev/null || die "不是有效的 tar.gz"
  tar -C "$CLUSTERS_DIR" -xzf "$file"
  log_ok "已导入到 $CLUSTERS_DIR"
  log_info "如与现有存档端口冲突，请编辑 server.ini 或重新 clone 分配端口"
}
