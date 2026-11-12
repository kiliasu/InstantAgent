#!/usr/bin/env bash
# Session management: status / stop
#
# Usage:
#   ./config.sh              # interactive
#   ./config.sh --list       # status
#   ./config.sh --all        # stop all sessions
#   ./config.sh codex-g4     # stop one session
#   ./config.sh --keepalive [codex-g4]   # (re)start the keep-alive loop
#   ./config.sh --zh         # Chinese UI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"

resolve_colab

ACTION=""
TARGET=""
for a in ${1+"$@"}; do
  case "$a" in
    --list) ACTION=list ;;
    --all)  ACTION=all ;;
    --keepalive) ACTION=keepalive ;;
    --zh)   UI_LANG=zh; save_lang ;;
    --en)   UI_LANG=en; save_lang ;;
    -*)     t bad_opt "$a"; exit 1 ;;
    *)      TARGET="$a"; [ "$ACTION" = keepalive ] || ACTION=one ;;
  esac
done

ACTIVE="$(list_sessions)" || exit 1

if [ -z "$ACTIVE" ]; then
  t no_sessions
  rm -f "$HOME"/.ssh/cm/* 2>/dev/null || true
  exit 0
fi

# ---- Action ----
if [ -z "$ACTION" ]; then
  t action
  echo "  1) $(t a_status)"
  echo "  2) $(t a_stop)"
  echo "  3) $(t a_stop_all)"
  echo "  4) $(t a_keepalive)"
  read -rp "> " n
  case "$n" in
    1) ACTION=list ;;
    2) ACTION=pick ;;
    3) ACTION=all ;;
    4) ACTION=keepalive ;;
    *) t invalid; exit 1 ;;
  esac
fi

# ---- Status ----
if [ "$ACTION" = list ]; then
  for s in $ACTIVE; do
    echo
    "$COLAB_BIN" status -s "$s" 2>&1 | sed 's/^/ /'
    ensure_ssh_key
    build_ssh_opts "$s" ""
    # Live values first so they win over the deploy-time ones in runtime_stats
    INFO="$(ssh "${SSH_OPTS[@]}" root@colab '
      if curl -sf http://127.0.0.1:11434/v1/models >/dev/null 2>&1; then echo health=ok; else echo health=down; fi
      P=$(pgrep -f "vllm serve|ollama serve" | head -1)
      [ -n "$P" ] && echo "up_secs=$(ps -o etimes= -p "$P" | tr -d " ")"
      echo "mem=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d " " | tr "," "/")"
      cat /root/.codex/runtime_stats 2>/dev/null
      if [ -f /root/.codex/status ]; then echo "status_age=$(( $(date +%s) - $(stat -c %Y /root/.codex/status) ))"; cat /root/.codex/status; fi
      if pgrep -x cloudflared >/dev/null 2>&1; then
        U=$(grep -oE "https://[a-z0-9-]+[.]trycloudflare[.]com" /var/log/cloudflared.log 2>/dev/null | head -1)
        [ -n "$U" ] && echo "url=$U" && echo "token=$(cat /root/.codex/api_token 2>/dev/null)"
      fi
      true
    ' 2>/dev/null || true)"
    INFO="$INFO
keepalive=$(ka_status "$s")"
    if [ -n "$(inf backend)" ]; then
      print_info_rows
      if [ -n "$(inf url)" ]; then print_curl "$(inf url)" "$(inf token)" "$(inf alias local-model)"; fi
    else
      t box_ka "$(inf keepalive)"
    fi
  done
  exit 0
fi

# ---- Keep-alive ----
if [ "$ACTION" = keepalive ]; then
  for s in ${TARGET:-$ACTIVE}; do
    echo "$ACTIVE" | grep -qx "$s" || { t no_session "$s"; exit 1; }
    if ka_pid "$s" >/dev/null; then t box_ka "$(ka_status "$s")"; else ka_start "$s"; fi
  done
  exit 0
fi

# ---- Pick a session to stop ----
if [ "$ACTION" = pick ]; then
  COUNT="$(echo "$ACTIVE" | wc -l | tr -d ' ')"
  if [ "$COUNT" = 1 ]; then
    TARGETS="$ACTIVE"
  else
    echo
    t session
    i=1
    for s in $ACTIVE; do echo "  $i) $s"; i=$((i + 1)); done
    read -rp "> " n
    case "$n" in ''|0|*[!0-9]*) t invalid; exit 1 ;; esac
    TARGETS="$(echo "$ACTIVE" | sed -n "${n}p")"
    [ -z "$TARGETS" ] && { t invalid; exit 1; }
  fi
else
  case "$ACTION" in
    one) TARGETS="$TARGET" ;;
    all) TARGETS="$ACTIVE" ;;
  esac
fi

# ---- Stop ----
for s in $TARGETS; do
  ka_stop "$s"
  # Close the local ControlMaster
  if [ -S "$HOME/.ssh/cm/$s" ]; then
    ssh -o "ControlPath=$HOME/.ssh/cm/$s" -O exit root@colab >/dev/null 2>&1 || true
    rm -f "$HOME/.ssh/cm/$s"
  fi
  "$COLAB_BIN" stop -s "$s" >/dev/null 2>&1 && t stopped "$s" || t stop_fail "$s"
done
