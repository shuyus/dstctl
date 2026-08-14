# dstctl bash 补全
# 安装: source completions/dstctl.bash
# 或: cp completions/dstctl.bash /etc/bash_completion.d/

_dstctl() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  local cmds="install update doctor quickstart help version cluster token mods start stop restart start-all stop-all attach systemd players kick ban unban tp kill resurrect despawn god announce announce-all cmd save rollback reset regenerate season skip admin whitelist blacklist status logs tail history backup export import watchdog menu"
  local clusters=""
  if [[ -d "${HOME}/.klei/DoNotStarveTogether" ]]; then
    clusters="$(find "${HOME}/.klei/DoNotStarveTogether" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
  fi
  case "${COMP_WORDS[1]}" in
    cluster)
      case "$prev" in
        cluster) COMPREPLY=( $(compgen -W "create list info edit delete reset clone" -- "$cur") ) ;;
        info|edit|delete|reset|clone) COMPREPLY=( $(compgen -W "$clusters" -- "$cur") ) ;;
      esac
      ;;
    stop)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "--graceful --kill --force --no-save --no-announce" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "$clusters" -- "$cur") )
      fi
      ;;
    start|restart|attach|players|kick|ban|unban|tp|kill|resurrect|despawn|god|announce|cmd|save|rollback|reset|regenerate|season|skip|admin|whitelist|blacklist|status|logs|tail|history|export|systemd|token|mods)
      COMPREPLY=( $(compgen -W "$clusters" -- "$cur") )
      ;;
    backup)
      case "$prev" in
        backup) COMPREPLY=( $(compgen -W "create list restore all" -- "$cur") ) ;;
        create|list|restore) COMPREPLY=( $(compgen -W "$clusters" -- "$cur") ) ;;
      esac
      ;;
    watchdog)
      COMPREPLY=( $(compgen -W "run once systemd cron" -- "$cur") )
      ;;
    *)
      COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
      ;;
  esac
}
complete -F _dstctl dstctl
