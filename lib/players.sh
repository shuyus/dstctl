#!/usr/bin/env bash
# 运行时玩家操作：列表、踢、封、传送、杀死、复活
# 编码: UTF-8

_lua_find_player() {
  local who="$1"
  printf 'local function DSTCTL_FIND(who) for _,p in ipairs(AllPlayers) do if p.userid==who or p.name==who or tostring(_)==who then return p end end return nil end local p=DSTCTL_FIND("%s")' \
    "$(lua_escape "$who")"
}

cmd_players() {
  local name="${1-}"
  [[ -n "$name" ]] || die "用法: dstctl players <存档>"
  require_cluster "$name"
  cluster_running "$name" || die "存档未运行"
  local ts logf
  ts="$(date +%s)"
  logf="$(shard_log "$name" Master)"
  [[ -f "$logf" ]] || logf="$(shard_log "$name" Caves)"
  send_lua "$name" "pcall(function() print(\"[DSTCTL] PLAYER_BEGIN ${ts}\") for i,v in ipairs(AllPlayers) do print(string.format(\"[DSTCTL] PLAYER\\t${ts}\\t%d\\t%s\\t%s\\t%s\\t%s\", i, v.userid, v.name, tostring(v.prefab), tostring(v:HasTag(\"playerghost\")))) end print(\"[DSTCTL] PLAYER_END ${ts}\") end)"
  local i=0
  while (( i < 8 )); do
    sleep 1
    if [[ -f "$logf" ]] && grep -q "\\[DSTCTL\\] PLAYER_END ${ts}" "$logf"; then
      break
    fi
    i=$((i + 1))
  done
  echo "${C_BOLD}在线玩家 ($name)${C_RESET}"
  printf "%-4s %-16s %-20s %-14s %s\n" "#" "KU" "名字" "角色" "状态"
  local any=0
  if [[ -f "$logf" ]]; then
    awk -v ts="$ts" '
      $0 ~ "\\[DSTCTL\\] PLAYER\t" ts "\t" {
        n=split($0, a, "\t")
        if (n>=7) {
          ghost=(a[7] ~ /true/) ? "幽灵" : "存活"
          printf "%-4s %-16s %-20s %-14s %s\n", a[3], a[4], a[5], a[6], ghost
          found=1
        }
      }
      END { if (!found) exit 1 }
    ' "$logf" && any=1 || true
  fi
  if (( any == 0 )); then
    echo "(控制台未返回列表，尝试从日志推断)"
    _players_from_log "$name"
  fi
}

_players_from_log() {
  local name="$1"
  local logf
  logf="$(shard_log "$name" Master)"
  [[ -f "$logf" ]] || return 0
  awk '
    /Client authenticated: \(/ {
      match($0, /\(KU_[A-Za-z0-9_]+\)/)
      id=substr($0, RSTART+1, RLENGTH-2)
      name=$0
      sub(/.*\)[[:space:]]*/, "", name)
      players[id]=name
    }
    /\[Join Announcement\]/ {
      lastjoin=$0
    }
    /\[Leave Announcement\]/ {
      n=$0
      sub(/.*\[Leave Announcement\][[:space:]]*/, "", n)
      for (id in players) if (players[id]==n) delete players[id]
    }
    END {
      i=1
      for (id in players) {
        printf "%-4s %-16s %-20s\n", i, id, players[id]
        i++
      }
      if (i==1) print "(当前可能没有玩家在线)"
    }
  ' "$logf"
}

count_online_players() {
  local name="$1"
  cluster_running "$name" || { echo 0; return 0; }
  local ts logf i
  ts="$(date +%s)"
  logf="$(shard_log "$name" Master)"
  send_lua "$name" "pcall(function() print(\"[DSTCTL] COUNT ${ts} \"..#AllPlayers) end)" 2>/dev/null || true
  i=0
  while (( i < 5 )); do
    sleep 1
    if [[ -f "$logf" ]]; then
      local c
      c="$(awk -v ts="$ts" '
        $0 ~ "\\[DSTCTL\\] COUNT " ts {
          n=$(NF); print n; exit
        }
      ' "$logf")"
      if [[ "$c" =~ ^[0-9]+$ ]]; then
        echo "$c"
        return 0
      fi
    fi
    i=$((i + 1))
  done
  echo "?"
}

cmd_kick() {
  local name="$1" who="$2"
  [[ -n "$name" && -n "$who" ]] || die "用法: dstctl kick <存档> <KU或玩家名>"
  send_lua "$name" "$(_lua_find_player "$who"); if p then TheNet:Kick(p.userid) print(\"[DSTCTL] kicked \"..p.userid) else print(\"[DSTCTL] player not found\") end"
  log_ok "已发送踢出: $who"
}

cmd_ban() {
  local name="$1" who="$2" seconds="${3-}"
  [[ -n "$name" && -n "$who" ]] || die "用法: dstctl ban <存档> <KU或玩家名> [秒数]"
  if [[ -n "$seconds" ]]; then
    send_lua "$name" "$(_lua_find_player "$who"); if p then TheNet:BanForTime(p.userid, ${seconds}) else TheNet:BanForTime(\"$(lua_escape "$who")\", ${seconds}) end"
  else
    send_lua "$name" "$(_lua_find_player "$who"); if p then TheNet:Ban(p.userid) else TheNet:Ban(\"$(lua_escape "$who")\") end"
    if [[ "$who" == KU_* ]]; then
      list_add "$(cluster_dir "$name")/blocklist.txt" "$who"
    fi
  fi
  log_ok "已发送封禁: $who ${seconds:+(${seconds}s)}"
}

cmd_unban() {
  local name="$1" who="$2"
  [[ -n "$name" && -n "$who" ]] || die "用法: dstctl unban <存档> <KU>"
  list_remove "$(cluster_dir "$name")/blocklist.txt" "$who"
  send_lua "$name" "TheNet:Unban(\"${who}\")" 2>/dev/null || log_warn "已从 blocklist 移除；若 TheNet:Unban 不可用，玩家将在重启后解禁"
  log_ok "已解禁: $who"
}

cmd_kill_player() {
  local name="$1" who="$2"
  [[ -n "$name" && -n "$who" ]] || die "用法: dstctl kill <存档> <KU或玩家名>"
  send_lua "$name" "$(_lua_find_player "$who"); if p then p:PushEvent(\"death\") print(\"[DSTCTL] killed \"..p.name) else print(\"[DSTCTL] player not found\") end"
  log_ok "已发送杀死: $who"
}

cmd_resurrect() {
  local name="$1" who="$2"
  [[ -n "$name" && -n "$who" ]] || die "用法: dstctl resurrect <存档> <KU或玩家名>"
  send_lua "$name" "$(_lua_find_player "$who"); if p then p:PushEvent(\"respawnfromghost\") print(\"[DSTCTL] resurrect \"..p.name) else print(\"[DSTCTL] player not found\") end"
  log_ok "已发送复活: $who"
}

cmd_despawn() {
  local name="$1" who="$2"
  [[ -n "$name" && -n "$who" ]] || die "用法: dstctl despawn <存档> <KU或玩家名>"
  send_lua "$name" "$(_lua_find_player "$who"); if p then c_despawn(p) else print(\"[DSTCTL] player not found\") end"
  log_ok "已发送退回人物选择: $who"
}

cmd_tp() {
  local name="$1" who="$2"
  shift 2 || true
  [[ -n "$name" && -n "$who" ]] || die "用法: dstctl tp <存档> <玩家> --to <玩家> | --pos x,z"
  local to="" pos=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to) to="$2"; shift 2 ;;
      --pos) pos="$2"; shift 2 ;;
      *)
        if [[ "$1" == to ]]; then to="$2"; shift 2
        elif [[ "$1" =~ ^-?[0-9.]+,-?[0-9.]+$ ]]; then pos="$1"; shift
        else die "未知参数: $1"
        fi
        ;;
    esac
  done
  if [[ -n "$to" ]]; then
    send_lua "$name" "local function F(who) for _,p in ipairs(AllPlayers) do if p.userid==who or p.name==who then return p end end return nil end local a=F(\"$(lua_escape "$who")\") local b=F(\"$(lua_escape "$to")\") if a and b then local x,y,z=b.Transform:GetWorldPosition(); a.Transform:SetPosition(x,y,z) print(\"[DSTCTL] tp ok\") else print(\"[DSTCTL] player not found\") end"
  elif [[ -n "$pos" ]]; then
    local x z
    x="${pos%%,*}"
    z="${pos##*,}"
    send_lua "$name" "$(_lua_find_player "$who"); if p then p.Transform:SetPosition(${x}, 0, ${z}) print(\"[DSTCTL] tp ok\") else print(\"[DSTCTL] player not found\") end"
  else
    die "请指定 --to <玩家> 或 --pos x,z"
  fi
  log_ok "已发送传送"
}

cmd_god() {
  local name="$1" who="$2"
  [[ -n "$name" && -n "$who" ]] || die "用法: dstctl god <存档> <KU或玩家名>"
  send_lua "$name" "$(_lua_find_player "$who"); if p then c_select(p); c_godmode() else print(\"[DSTCTL] player not found\") end"
  log_ok "已切换上帝模式: $who"
}
