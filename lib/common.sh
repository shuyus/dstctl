#!/usr/bin/env bash
# dstctl 公共函数：日志、确认、锁、INI、名单文件
# 编码: UTF-8

DSTCTL_VERSION="${DSTCTL_VERSION:-1.2.0}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
  C_MAGENTA=$'\033[35m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_MAGENTA=""
fi

log_info()  { printf '%s[%s]%s %s\n' "${C_CYAN}" "信息" "${C_RESET}" "$*"; }
log_ok()    { printf '%s[%s]%s %s\n' "${C_GREEN}" "成功" "${C_RESET}" "$*"; }
log_warn()  { printf '%s[%s]%s %s\n' "${C_YELLOW}" "警告" "${C_RESET}" "$*"; }
log_error() { printf '%s[%s]%s %s\n' "${C_RED}" "错误" "${C_RESET}" "$*" >&2; }
log_debug() { [[ "${DSTCTL_DEBUG:-0}" == "1" ]] && printf '%s[%s]%s %s\n' "${C_DIM}" "调试" "${C_RESET}" "$*"; }

die() { log_error "$*"; exit 1; }

now() { date '+%Y-%m-%d %H:%M:%S'; }
now_id() { date '+%Y%m%d-%H%M%S'; }

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_dir() { mkdir -p "$1"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
  done
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_linux() { [[ "$(uname -s 2>/dev/null)" == "Linux" ]]; }

require_linux() {
  is_linux || die "当前操作需要在 Linux 上运行（检测到: $(uname -s 2>/dev/null || echo unknown)）"
}

confirm() {
  local prompt="${1:-确认继续?}" default="${2:-n}" ans
  if [[ ! -t 0 ]]; then
    is_true "$default"
    return
  fi
  if [[ "$default" == "y" ]]; then
    read -r -p "${prompt} [Y/n] " ans || true
    [[ -z "$ans" || "$ans" == "y" || "$ans" == "Y" ]]
  else
    read -r -p "${prompt} [y/N] " ans || true
    [[ "$ans" == "y" || "$ans" == "Y" ]]
  fi
}

read_default() {
  local prompt="$1" default="${2-}" var
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " var || true
  else
    read -r -p "${prompt}: " var || true
  fi
  printf '%s' "${var:-$default}"
}

lua_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

valid_cluster_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

port_in_use() {
  local port="$1"
  if have_cmd ss; then
    ss -uln 2>/dev/null | grep -qE ":${port}[[:space:]]"
    return
  fi
  if have_cmd netstat; then
    netstat -uln 2>/dev/null | grep -qE ":${port}[[:space:]]"
    return
  fi
  return 1
}

sudo_run() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif have_cmd sudo; then
    sudo "$@"
  else
    die "需要 root 权限或 sudo 才能执行: $*"
  fi
}

lock_file_path() {
  echo "${DSTCTL_RUN_DIR}/locks/${1}.lock"
}

with_lock() {
  local name="$1"
  shift
  ensure_dir "${DSTCTL_RUN_DIR}/locks"
  local lf
  lf="$(lock_file_path "$name")"
  if have_cmd flock; then
    exec 9>"$lf"
    if ! flock -n 9; then
      die "操作进行中，请稍后再试（锁: $name）"
    fi
    "$@"
    flock -u 9
    exec 9>&-
  else
    if [[ -f "$lf" ]]; then
      local oldpid
      oldpid="$(cat "$lf" 2>/dev/null || true)"
      if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
        die "操作进行中，请稍后再试（锁: $name, pid=$oldpid）"
      fi
    fi
    echo $$ >"$lf"
    "$@"
    rm -f "$lf"
  fi
}

# --- INI ---
ini_get() {
  local file="$1" section="$2" key="$3" default="${4-}"
  [[ -f "$file" ]] || { printf '%s' "$default"; return 0; }
  local val
  val="$(awk -F '=' -v sec="$section" -v key="$key" '
    BEGIN { s="" }
    {
      line=$0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*[;#]/) next
      if (line ~ /^[[:space:]]*\[/) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        s=line
        next
      }
      n=index(line, "=")
      if (n==0) next
      k=substr(line, 1, n-1)
      v=substr(line, n+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (s == "[" sec "]" && k == key) {
        print v
        exit
      }
    }
  ' "$file")"
  printf '%s' "${val:-$default}"
}

ini_set() {
  local file="$1" section="$2" key="$3" value="$4"
  ensure_dir "$(dirname "$file")"
  [[ -f "$file" ]] || printf '\n' >"$file"
  local tmp
  tmp="${file}.tmp.$$"
  awk -v sec="$section" -v key="$key" -v value="$value" '
    BEGIN { found_sec=0; found_key=0; in_sec=0 }
    {
      line=$0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*\[/) {
        if (in_sec && !found_key) {
          print key " = " value
          found_key=1
        }
        in_sec=0
        hdr=line
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", hdr)
        if (hdr == "[" sec "]") { in_sec=1; found_sec=1 }
        print line
        next
      }
      if (in_sec) {
        n=index(line, "=")
        if (n>0) {
          k=substr(line, 1, n-1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
          if (k == key) {
            print key " = " value
            found_key=1
            next
          }
        }
      }
      print line
    }
    END {
      if (!found_sec) {
        print ""
        print "[" sec "]"
        print key " = " value
      } else if (!found_key) {
        print key " = " value
      }
    }
  ' "$file" >"$tmp"
  mv -f "$tmp" "$file"
}

# --- KEY=VALUE meta ---
meta_file() { echo "$(cluster_dir "$1")/.dstctl.conf"; }

meta_get() {
  local cluster="$1" key="$2" default="${3-}"
  local f
  f="$(meta_file "$cluster")"
  [[ -f "$f" ]] || { printf '%s' "$default"; return 0; }
  local val
  val="$(awk -F '=' -v key="$key" '
    {
      sub(/\r$/, "", $0)
      if ($0 ~ /^[[:space:]]*#/) next
      if ($1 == key) {
        v=substr($0, index($0, "=")+1)
        print v
        exit
      }
    }
  ' "$f")"
  printf '%s' "${val:-$default}"
}

meta_set() {
  local cluster="$1" key="$2" value="$3"
  local f tmp
  f="$(meta_file "$cluster")"
  ensure_dir "$(dirname "$f")"
  [[ -f "$f" ]] || printf '# dstctl 存档元数据\n' >"$f"
  tmp="${f}.tmp.$$"
  awk -v key="$key" -v value="$value" '
    BEGIN { found=0 }
    {
      sub(/\r$/, "", $0)
      n=index($0, "=")
      if (n>0) {
        k=substr($0, 1, n-1)
        if (k == key) {
          print key "=" value
          found=1
          next
        }
      }
      print
    }
    END { if (!found) print key "=" value }
  ' "$f" >"$tmp"
  mv -f "$tmp" "$f"
}

# --- 一行一个 ID 的名单 ---
list_add() {
  local file="$1" id="$2"
  ensure_dir "$(dirname "$file")"
  [[ -f "$file" ]] || : >"$file"
  grep -qxF "$id" "$file" 2>/dev/null && return 0
  printf '%s\n' "$id" >>"$file"
}

list_remove() {
  local file="$1" id="$2"
  [[ -f "$file" ]] || return 0
  local tmp="${file}.tmp.$$"
  grep -vxF "$id" "$file" >"$tmp" || true
  mv -f "$tmp" "$file"
}

list_has() {
  local file="$1" id="$2"
  [[ -f "$file" ]] && grep -qxF "$id" "$file"
}

list_show() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    echo "(空)"
    return 0
  fi
  grep -vE '^[[:space:]]*(#|$)' "$file" || echo "(空)"
}

bytes_human() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB", u, " ")
    i=1
    while (b>=1024 && i<5) { b=b/1024; i++ }
    printf(i==1?"%d %s":"%.1f %s", b, u[i])
  }'
}

pause_enter() {
  [[ -t 0 ]] || return 0
  read -r -p "按回车继续..." _ || true
}

# 丢掉终端里积压的回车，避免前台进程误读或后续菜单被跳过
drain_stdin() {
  [[ -t 0 ]] || return 0
  local _junk
  while read -r -t 0.1 -n 10000 _junk; do
    :
  done 2>/dev/null || true
}
