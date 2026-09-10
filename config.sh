#!/usr/bin/env bash
# Session management: status / stop
#
# Usage:
#   ./config.sh              # interactive
#   ./config.sh --list       # status
#   ./config.sh --all        # stop all sessions
#   ./config.sh codex-g4     # stop one session
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
    --zh)   UI_LANG=zh ;;
    --en)   UI_LANG=en ;;
    -*)     t bad_opt "$a"; exit 1 ;;
    *)      ACTION=one; TARGET="$a" ;;
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
  read -rp "> " n
  case "$n" in
    1) ACTION=list ;;
    2) ACTION=pick ;;
    3) ACTION=all ;;
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
    INFO="$(ssh "${SSH_OPTS[@]}" root@colab '
      cat /root/.codex/runtime_stats 2>/dev/null
      if pgrep -x cloudflared >/dev/null 2>&1; then
        U=$(grep -oE "https://[a-z0-9-]+[.]trycloudflare[.]com" /var/log/cloudflared.log 2>/dev/null | head -1)
        [ -n "$U" ] && echo "url=$U" && echo "token=$(cat /root/.codex/api_token 2>/dev/null)"
      fi
    ' 2>/dev/null || true)"
    field() { echo "$INFO" | sed -n "s|^$1=||p"; }
    [ -n "$(field backend)" ] && t box_backend "$(field backend)" "$(field agent)"
    [ -n "$(field model)" ]   && t box_model "$(field model)"
    [ -n "$(field alias)" ]   && t box_served "$(field alias)"
    [ -n "$(field ctx)" ]     && t box_ctx "$(field ctx)" "$(field maxout)" "$(field parallel)"
    [ -n "$(field mem)" ]     && t box_mem "$(field mem)"
    [ -n "$(field url)" ]     && t box_api "$(field url)"
    [ -n "$(field token)" ]   && t box_token "$(field token)"
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
  # Close the local ControlMaster
  if [ -S "$HOME/.ssh/cm/$s" ]; then
    ssh -o "ControlPath=$HOME/.ssh/cm/$s" -O exit root@colab >/dev/null 2>&1 || true
    rm -f "$HOME/.ssh/cm/$s"
  fi
  "$COLAB_BIN" stop -s "$s" >/dev/null 2>&1 && t stopped "$s" || t stop_fail "$s"
done
