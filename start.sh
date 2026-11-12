#!/usr/bin/env bash
# Local entry point: connect to a Colab session, deploy on the VM, attach to the agent or print the API address
#
# Usage:
#   ./start.sh                        # interactive
#   ./start.sh --resume               # reattach; with other flags, redeploy the session with those changes first
#   ./start.sh a100hm                 # skip the GPU question (gpu: h100|g4|a100hm|a100)
#   ./start.sh a100hm --model=obliterated-q4  # model: obliterated (default) | obliterated-q8|q6|q4 | hemmingway | HF repo id / Ollama ref
#   ./start.sh a100hm --setup-only    # deploy only, don't attach
#   ./start.sh a100hm --expose        # also expose a public API
#   ./start.sh a100hm --omo           # opencode + oh-my-openagent (default)
#   ./start.sh a100hm --omp           # oh my pi
#   ./start.sh a100hm --codex         # codex
#   ./start.sh a100hm --opencode      # plain opencode
#   ./start.sh a100hm --ollama        # ollama backend (default vllm)
#   ./start.sh a100hm --no-herdr      # run the agent without herdr
#   ./start.sh --zh                   # Chinese UI
#
# Env: MODEL / CONTEXT / MAX_OUTPUT
#      TEMPERATURE / TOP_P / TOP_K / REPETITION_PENALTY (default per model)
#      THINKING / REASONING / SPEC_TOKENS / MAX_SEQS (vllm only)
#      KV_TYPE / PARALLEL (ollama only)
#
# Interactive: language, GPU, backend, model, mode, agent, then an options preset
# (default / fast writing / no thinking / custom: thinking, effort, MTP, context).
# Each question is skipped when a flag or env var already answers it.
#
# Fallback: H100 → G4 → A100 High-RAM; G4 → A100 High-RAM
# Keep-alive: a detached local loop runs a no-op in the session kernel every
#   KA_INTERVAL seconds (default 300), because Colab prunes idle sessions after
#   about an hour and ssh traffic does not count. ./config.sh stops it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${UI_LANG:-}" ]; then LANG_SET=1; else LANG_SET=0; fi
. "$SCRIPT_DIR/_common.sh"

CTX="${CONTEXT:-262144}"

ENTER=1
EXPOSE=0
MODE_SET=0
ASKED=0
CHANGED=0
if [ -n "${BACKEND:-}" ]; then BACKEND_SET=1; else BACKEND_SET=0; fi
if [ -n "${AGENT:-}" ]; then AGENT_SET=1; else AGENT_SET=0; fi
if [ -n "${HERDR:-}" ]; then HERDR_SET=1; else HERDR_SET=0; fi
BACKEND="${BACKEND:-vllm}"
AGENT="${AGENT:-opencode}"
HERDR="${HERDR:-1}"
RESUME=""
OMO="${OMO:-1}"
GPU_CHOICE=""
MODEL="${MODEL:-}"

# resolve_model: MODEL -> MODEL_REF and QUANT for $BACKEND, or exit
resolve_model() {
  if ! MODEL_REF="$(model_ref "$MODEL" "$BACKEND")"; then
    case " $MODELS " in
      *" $MODEL "*) t no_build "$MODEL" "$BACKEND" ;;
      *)            t bad_model "$MODEL" "$(echo "$MODELS" | tr ' ' '|')" ;;
    esac
    exit 1
  fi
  QUANT="$(model_quant "$MODEL" "$BACKEND")"
}

while [ $# -gt 0 ]; do
  a="$1"; shift
  # Any flag but these asks to change the deployment, which matters for --resume
  case "$a" in --resume|--zh|--en|[!-]*) ;; *) CHANGED=1 ;; esac
  case "$a" in
    --model)      [ $# -gt 0 ] || { t need_val "$a"; exit 1; }
                  MODEL="$1"; shift ;;
    --model=*)    MODEL="${a#--model=}" ;;
    --setup-only) ENTER=0; MODE_SET=1 ;;
    --expose)     EXPOSE=1; MODE_SET=1 ;;
    --ollama)     BACKEND=ollama; BACKEND_SET=1 ;;
    --vllm)       BACKEND=vllm; BACKEND_SET=1 ;;
    --codex)      AGENT=codex; AGENT_SET=1 ;;
    --opencode)   AGENT=opencode; OMO=0; AGENT_SET=1 ;;
    --omo)        AGENT=opencode; OMO=1; AGENT_SET=1 ;;
    --omp)        AGENT=omp; AGENT_SET=1 ;;
    --no-herdr)   HERDR=0; HERDR_SET=1 ;;
    --resume)     RESUME=auto ;;
    --zh)         UI_LANG=zh; LANG_SET=1; save_lang ;;
    --en)         UI_LANG=en; LANG_SET=1; save_lang ;;
    -*)           t bad_opt "$a"; exit 1 ;;
    *) if [ -z "$GPU_CHOICE" ]; then GPU_CHOICE="$a"
       else t bad_opt "$a"; exit 1
       fi ;;
  esac
done

# Reject a bad --model / MODEL before asking anything; on resume the backend may still change
[ -z "$MODEL" ] || [ -n "$RESUME" ] || resolve_model
case "${REASONING:-}" in
  ""|low|medium|xhigh) ;;
  *) t bad_reasoning "$REASONING"; exit 1 ;;
esac

resolve_colab
require_colab_ssh
ensure_ssh_key

ask_lang() {
  [ "$LANG_SET" = 1 ] && return 0
  LANG_SET=1
  echo "Language:"
  echo "  1) English"
  echo "  2) 中文"
  read -rp "> " n
  case "$n" in
    1) UI_LANG=en ;;
    2) UI_LANG=zh ;;
    *) t invalid; exit 1 ;;
  esac
  save_lang
  LANG_ASKED=1
}

# ---- GPU / resume ----
if [ -z "$GPU_CHOICE" ] && [ -z "$RESUME" ]; then
  ASKED=1
  ask_lang
  [ "${LANG_ASKED:-0}" = 1 ] && echo
  RESUMABLE="$(list_sessions | grep '^codex-' | head -1)" || RESUMABLE=""
  t gpu
  [ -n "$RESUMABLE" ] && echo "  0) $(t resume "$RESUMABLE")"
  echo "  1) H100            80 GB"
  echo "  2) G4              96 GB  RTX PRO 6000"
  echo "  3) A100 High-RAM   80 GB"
  echo "  4) A100            40 GB"
  read -rp "> " n
  case "$n" in
    0) [ -n "$RESUMABLE" ] || { t invalid; exit 1; }; RESUME="$RESUMABLE" ;;
    1) GPU_CHOICE=h100 ;;
    2) GPU_CHOICE=g4 ;;
    3) GPU_CHOICE=a100hm ;;
    4) GPU_CHOICE=a100 ;;
    *) t invalid; exit 1 ;;
  esac
fi

# ---- Resume ----
# Reattach as is when no flag asks for a change. Otherwise redeploy the session,
# keeping what it runs wherever flags and env vars don't say otherwise.
if [ -n "$RESUME" ]; then
  [ "$RESUME" = auto ] && { RESUME="$(list_sessions | grep '^codex-' | head -1)" || RESUME=""; }
  [ -n "$RESUME" ] || { t no_resume; exit 1; }
  SESSION="$RESUME"
  build_ssh_opts "$SESSION" ""
  ka_start "$SESSION"
  if [ "$CHANGED" = 0 ] && ssh "${SSH_OPTS[@]}" root@colab \
       'export PATH="$HOME/.local/bin:$PATH"; herdr status server 2>/dev/null | grep -q "^status: running"' \
       2>/dev/null; then
    exec ssh -t "${SSH_OPTS[@]}" root@colab \
      'cd /content && export PATH="$HOME/.local/bin:$PATH" && exec herdr'
  fi
  [ "$CHANGED" = 1 ] || echo "!! $(t no_herdr "$SESSION")"
  PREV="$(ssh "${SSH_OPTS[@]}" root@colab 'cat /root/.codex/runtime_stats' 2>/dev/null || true)"
  if [ -n "$PREV" ]; then
    # prev <field> [default]
    prev() { local v; v="$(echo "$PREV" | sed -n "s|^$1=||p")"; echo "${v:-${2:-}}"; }
    if [ -z "$MODEL" ]; then
      MODEL="$(model_preset "$(prev model)" "$(prev backend)" "$(prev quant)")"
      TEMPERATURE="${TEMPERATURE:-$(prev temp)}"
      TOP_P="${TOP_P:-$(prev top_p)}"
      TOP_K="${TOP_K:-$(prev top_k)}"
      REPETITION_PENALTY="${REPETITION_PENALTY:-$(prev rep)}"
    fi
    THINKING="${THINKING:-$(prev think)}"
    REASONING="${REASONING:-$(prev reasoning)}"
    SPEC_TOKENS="${SPEC_TOKENS:-$(prev spec)}"
    OPTS_SET=1
    [ "$BACKEND_SET" = 1 ] || { BACKEND="$(prev backend "$BACKEND")"; BACKEND_SET=1; }
    [ "$AGENT_SET" = 1 ] || { AGENT="$(prev agent "$AGENT")"; OMO="$(prev omo "$OMO")"; AGENT_SET=1; }
    [ "$HERDR_SET" = 1 ] || HERDR="$(prev herdr "$HERDR")"
    [ -n "${CONTEXT:-}" ] || CTX="$(prev ctx "$CTX")"
    MODE_SET=1
  fi
  GPU_CHOICE="${SESSION#codex-}"
  RESUME=""
fi
GPU_CHOICE="$(echo "$GPU_CHOICE" | tr '[:upper:]' '[:lower:]')"
CHAIN="$(tier_chain "$GPU_CHOICE")" || { t bad_gpu "$GPU_CHOICE"; exit 1; }

# ---- Model ----
# Asked whenever anything else is, so fully flagged runs stay non-interactive
[ "$MODE_SET" = 1 ] || ASKED=1
[ "$ENTER" = 0 ] || [ "$AGENT_SET" = 1 ] || ASKED=1

# ---- Backend ----
if [ "$BACKEND_SET" = 0 ] && [ "$ASKED" = 1 ]; then
  ask_lang
  echo
  t backend
  echo "  1) $(t b_vllm)"
  echo "  2) $(t b_ollama)"
  read -rp "> " n
  case "$n" in
    1) BACKEND=vllm ;;
    2) BACKEND=ollama ;;
    *) t invalid; exit 1 ;;
  esac
  BACKEND_SET=1
fi

if [ -z "$MODEL" ] && [ "$ASKED" = 1 ]; then
  ask_lang
  echo
  t model
  i=0; SHOWN=""; SEEN="|"
  for m in $MODELS; do
    ref="$(model_ref "$m" "$BACKEND")" || continue    # no build for this backend
    q="$(model_quant "$m" "$BACKEND")"
    desc="$ref${q:+, $q}"
    case "$SEEN" in *"|$desc|"*) continue ;; esac     # same build as an earlier entry
    SEEN="$SEEN$desc|"; SHOWN="$SHOWN $m"; i=$((i + 1))
    printf "  %s) %-13s %-6s %s\n" "$i" "$(model_name "$m")" "$(model_size "$m" "$BACKEND")" "$(model_desc "$m" "$BACKEND")"
  done
  read -rp "> " n
  case "$n" in ''|0|*[!0-9]*) t invalid; exit 1 ;; esac
  MODEL="$(echo "${SHOWN# }" | tr ' ' '\n' | sed -n "${n}p")"
  [ -n "$MODEL" ] || { t invalid; exit 1; }
fi
MODEL="${MODEL:-${MODELS%% *}}"
resolve_model

# Sampling: per-model defaults, env vars override
read -r s_temp s_top_p s_top_k s_rep <<< "$(model_sampling "$MODEL")"
TEMPERATURE="${TEMPERATURE:-$s_temp}"
TOP_P="${TOP_P:-$s_top_p}"
TOP_K="${TOP_K:-$s_top_k}"
REPETITION_PENALTY="${REPETITION_PENALTY:-$s_rep}"

# ---- Mode ----
if [ "$MODE_SET" = 0 ]; then
  ask_lang
  echo
  t mode
  echo "  1) $(t m_agent)"
  echo "  2) $(t m_api)"
  echo "  3) $(t m_both)"
  read -rp "> " n
  case "$n" in
    1) ENTER=1; EXPOSE=0 ;;
    2) ENTER=0; EXPOSE=1 ;;
    3) ENTER=1; EXPOSE=1 ;;
    *) t invalid; exit 1 ;;
  esac
fi

# ---- Agent ----
if [ "$ENTER" = 1 ] && [ "$AGENT_SET" = 0 ]; then
  ask_lang
  echo
  t agent
  echo "  1) omo   (opencode + oh-my-openagent)"
  echo "  2) omp   (oh my pi)"
  echo "  3) codex"
  read -rp "> " n
  case "$n" in
    1) AGENT=opencode; OMO=1 ;;
    2) AGENT=omp ;;
    3) AGENT=codex ;;
    *) t invalid; exit 1 ;;
  esac
fi

# ---- Options ----
# Presets for the template switches and context. Asked on an interactive run unless an
# env var already decided one of them, or the values were restored by --resume.
OPTS_SET="${OPTS_SET:-0}"
[ -n "${THINKING:-}${REASONING:-}${SPEC_TOKENS:-}${CONTEXT:-}" ] && OPTS_SET=1
THINKING="${THINKING:-}"
REASONING="${REASONING:-}"
SPEC_TOKENS="${SPEC_TOKENS:-}"

ask_custom() {
  if [ "$BACKEND" = vllm ]; then
    echo
    t q_think
    echo "  1) $(t on)"
    echo "  2) $(t off)"
    read -rp "> " n
    case "$n" in
      1) THINKING=1 ;;
      2) THINKING=0 ;;
      *) t invalid; exit 1 ;;
    esac
    if [ "$THINKING" = 1 ]; then
      echo
      t q_effort
      echo "  1) xhigh   ($(t default))"
      echo "  2) medium"
      echo "  3) low"
      read -rp "> " n
      case "$n" in
        1) REASONING="" ;;
        2) REASONING=medium ;;
        3) REASONING=low ;;
        *) t invalid; exit 1 ;;
      esac
    fi
    echo
    t q_spec
    echo "  1) $(t off)"
    echo "  2) MTP x2   $(t spec_hint)"
    echo "  3) MTP x3   $(t spec_hint3)"
    read -rp "> " n
    case "$n" in
      1) SPEC_TOKENS=0 ;;
      2) SPEC_TOKENS=2 ;;
      3) SPEC_TOKENS=3 ;;
      *) t invalid; exit 1 ;;
    esac
  fi
  echo
  t q_ctx
  echo "  1) 262144   ($(t default))"
  echo "  2) 131072"
  echo "  3) 65536"
  echo "  4) 32768"
  read -rp "> " n
  case "$n" in
    1) CTX=262144 ;;
    2) CTX=131072 ;;
    3) CTX=65536 ;;
    4) CTX=32768 ;;
    *) t invalid; exit 1 ;;
  esac
}

if [ "$ASKED" = 1 ] && [ "$OPTS_SET" = 0 ]; then
  ask_lang
  echo
  t options
  if [ "$BACKEND" = vllm ]; then
    REC=""; [ "$MODEL" = hemmingway ] && REC="$(t recommended)"
    echo "  1) $(t o_default)"
    echo "  2) $(t o_fast)$REC"
    echo "  3) $(t o_nothink)"
    echo "  4) $(t o_custom)"
    read -rp "> " n
    case "$n" in
      1) ;;
      2) REASONING=low; SPEC_TOKENS=2 ;;
      3) THINKING=0; SPEC_TOKENS=2 ;;
      4) ask_custom ;;
      *) t invalid; exit 1 ;;
    esac
  else
    echo "  1) $(t o_ollama)"
    echo "  2) $(t o_custom)"
    read -rp "> " n
    case "$n" in
      1) ;;
      2) ask_custom ;;
      *) t invalid; exit 1 ;;
    esac
  fi
fi

# ---- Connect ----
ACTUAL=""
PROBE_LOG="$(mktemp)"
trap 'rm -f "$PROBE_LOG"' EXIT
for tier in $CHAIN; do
  SESSION="codex-$tier"
  build_ssh_opts "$SESSION" "$(tier_flags "$tier")"

  if ssh "${SSH_OPTS[@]}" -O check root@colab 2>/dev/null; then
    echo "==> $(t reuse)"
    ACTUAL="$tier"; break
  fi

  echo "==> $(t connecting "$(tier_label "$tier")")"
  : > "$PROBE_LOG"
  if echo | "$COLAB_BIN" ssh --proxy-mode -s "$SESSION" -i "$SSH_KEY" \
       $(tier_flags "$tier") 2>"$PROBE_LOG" | grep -q '^SSH-'; then
    ACTUAL="$tier"; break
  fi
  echo "!! $(t unavail "$(tier_label "$tier")")"
done

if [ -z "$ACTUAL" ]; then
  echo
  echo "!! $(t all_unavail)"
  grep -v '^[[:space:]]*$' "$PROBE_LOG" | tail -3 | sed 's/^/   /'
  exit 1
fi

if [ "$ACTUAL" != "$GPU_CHOICE" ]; then
  echo
  echo "*** $(t fellback "$(tier_label "$GPU_CHOICE")" "$(tier_label "$ACTUAL")") ***"
fi

OTHERS="$(list_sessions | grep -v "^$SESSION$" || true)"
if [ -n "$OTHERS" ]; then
  echo "!! $(t others "$(echo "$OTHERS" | tr '\n' ' ')")"
fi
ka_start "$SESSION"

# ---- Deploy ----
# Timestamped local copy of the deploy output, for post-mortems; the last 20 are kept
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/instantagent"
mkdir -p "$LOG_DIR"
DEPLOY_LOG="$LOG_DIR/$SESSION-$(date +%Y%m%d-%H%M%S).log"
ls -t "$LOG_DIR"/*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
echo "# $(date '+%Y-%m-%d %H:%M:%S') session=$SESSION gpu=$ACTUAL backend=$BACKEND model=$MODEL_REF quant=${QUANT:-none} ctx=$CTX agent=$AGENT expose=$EXPOSE" > "$DEPLOY_LOG"
log_lines() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    printf '%s %s\n' "$(date +%H:%M:%S)" "$line" >> "$DEPLOY_LOG"
  done
}

echo "==> $(t deploying)"
if ! cat "$SCRIPT_DIR/_remote_setup.sh" "$SCRIPT_DIR/_expose.sh" \
  | ssh "${SSH_OPTS[@]}" root@colab \
      "MODEL_REF='$MODEL_REF' QUANT='$QUANT' CONTEXT='$CTX' EXPOSE='${EXPOSE:-0}' \
       BACKEND='$BACKEND' AGENT='$AGENT' OMO='$OMO' \
       HERDR='${HERDR:-1}' UI_LANG='$UI_LANG' \
       PARALLEL='${PARALLEL:-1}' MAX_OUTPUT='${MAX_OUTPUT:-16384}' \
       MAX_SEQS='${MAX_SEQS:-}' THINKING='$THINKING' \
       REASONING='$REASONING' SPEC_TOKENS='$SPEC_TOKENS' \
       TEMPERATURE='$TEMPERATURE' TOP_P='$TOP_P' TOP_K='$TOP_K' \
       REPETITION_PENALTY='$REPETITION_PENALTY' bash -s" 2>&1 | log_lines; then
  echo "!! $(t deploy_fail "$DEPLOY_LOG")"
  exit 1
fi

# ---- Runtime info ----
if [ "$EXPOSE" = 1 ]; then TRIES=30; else TRIES=1; fi
TUNNEL_INFO="$(ssh "${SSH_OPTS[@]}" root@colab "
    for _ in \$(seq 1 $TRIES); do
      U=\$(grep -oE 'https://[a-z0-9-]+[.]trycloudflare[.]com' /var/log/cloudflared.log 2>/dev/null | head -1)
      [ -n \"\$U\" ] && break
      sleep 2
    done
    pgrep -x cloudflared >/dev/null 2>&1 || U=
    [ -n \"\$U\" ] && echo \"url=\$U\"
    [ -n \"\$U\" ] && echo \"token=\$(cat /root/.codex/api_token 2>/dev/null)\"
    cat /root/.codex/runtime_stats 2>/dev/null
    if [ -f /root/.codex/status ]; then echo \"status_age=\$(( \$(date +%s) - \$(stat -c %Y /root/.codex/status) ))\"; cat /root/.codex/status; fi
  " 2>/dev/null || true)"
# Stats from the VM first, local values as fallbacks (inf takes the first match)
INFO="$TUNNEL_INFO
backend=$BACKEND
agent=$AGENT
model=$MODEL_REF
quant=$QUANT
temp=$TEMPERATURE
top_p=$TOP_P
top_k=$TOP_K
rep=$REPETITION_PENALTY
keepalive=$(ka_status "$SESSION")"
if [ "$PWD" = "$SCRIPT_DIR" ]; then CFG=./config.sh; else CFG="$SCRIPT_DIR/config.sh"; fi

print_box() {
  echo
  echo "───────────────────────────────────────────"
  t box_gpu "$(tier_label "$ACTUAL")" "$SESSION"
  print_info_rows
  if [ -z "$(inf url)" ] && [ "$EXPOSE" = 1 ]; then t box_api_err; fi
  t box_log "$DEPLOY_LOG"
  t box_later "$CFG --list"
  t box_stop "$CFG"
  echo "───────────────────────────────────────────"
  if [ -n "$(inf url)" ]; then print_curl "$(inf url)" "$(inf token)" "$(inf alias local-model)"; fi
}
print_box | log_lines

if [ "$ENTER" = 0 ]; then
  exit 0
fi

if [ "$EXPOSE" = 1 ] && [ -t 0 ]; then
  read -rp "$(t press_enter)" _
fi

# ---- Attach ----
if [ "${HERDR:-1}" = 1 ]; then
  LAUNCH='export PATH="$HOME/.local/bin:$PATH"; exec herdr'
elif [ "$AGENT" = codex ]; then
  LAUNCH="exec codex -s workspace-write"
elif [ "$AGENT" = omp ]; then
  LAUNCH='export PATH="$HOME/.local/bin:$PATH"; exec omp'
else
  LAUNCH='export PATH="$HOME/.opencode/bin:$HOME/.bun/bin:$PATH" OMO_DISABLE_POSTHOG=1; exec opencode'
fi
ssh -t "${SSH_OPTS[@]}" root@colab "cd /content && $LAUNCH" || true
print_box
