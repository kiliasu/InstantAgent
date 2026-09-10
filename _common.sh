#!/usr/bin/env bash
# Shared by start.sh and config.sh. bash 3.2 compatible.

UI_LANG="${UI_LANG:-en}"

# t <key> [args]: message in $UI_LANG
t() {
  local k="$1" en zh; shift
  case "$k" in
    gpu)          en="GPU:";                                   zh="GPU:" ;;
    resume)       en="Resume %s";                              zh="恢复 %s" ;;
    mode)         en="Mode:";                                  zh="用途:" ;;
    m_agent)      en="Agent";                                  zh="Agent" ;;
    m_api)        en="API";                                    zh="API" ;;
    m_both)       en="Both";                                   zh="两者" ;;
    agent)        en="Agent:";                                 zh="Agent:" ;;
    invalid)      en="Invalid choice";                         zh="无效选择" ;;
    bad_opt)      en="Unknown option: %s";                     zh="未知参数: %s" ;;
    bad_gpu)      en="Unknown GPU: %s (h100|g4|a100hm|a100)";  zh="未知 GPU: %s (h100|g4|a100hm|a100)" ;;
    no_resume)    en="No session to resume";                   zh="没有可恢复的会话" ;;
    no_herdr)     en="Cannot attach to %s, running full setup"; zh="无法接入 %s，转为完整部署" ;;
    reuse)        en="Reusing connection";                     zh="复用连接" ;;
    connecting)   en="Connecting %s ...";                      zh="连接 %s ..." ;;
    unavail)      en="%s unavailable";                         zh="%s 不可用" ;;
    all_unavail)  en="No GPU available. Last error:";          zh="没有可用 GPU。最后的报错:" ;;
    fellback)     en="Fell back: %s → %s";                     zh="已回落: %s → %s" ;;
    others)       en="Other sessions still billing: %s";       zh="另有会话在计费: %s" ;;
    deploying)    en="Deploying ...";                          zh="部署中 ..." ;;
    box_gpu)      en=" GPU      %s   Session %s";              zh=" 机型     %s   会话 %s" ;;
    box_backend)  en=" Backend  %s   Agent %s";                zh=" 后端     %s   Agent %s" ;;
    box_model)    en=" Model    %s";                           zh=" 模型     %s" ;;
    box_served)   en=" Served   %s";                           zh=" 服务名   %s" ;;
    box_ctx)      en=" Context  %s   Max out %s   Parallel %s"; zh=" 上下文   %s   输出上限 %s   并发 %s" ;;
    box_mem)      en=" VRAM     %s MiB";                       zh=" 显存     %s MiB" ;;
    box_api)      en=" API      %s";                           zh=" API      %s" ;;
    box_token)    en=" Token    %s";                           zh=" Token    %s" ;;
    box_api_err)  en=" API      failed";                       zh=" API      失败" ;;
    box_later)    en=" Later    %s";                           zh=" 稍后查看 %s" ;;
    box_stop)     en=" Stop     %s";                           zh=" 停止     %s" ;;
    press_enter)  en="Press Enter to attach ...";              zh="按回车进入 ..." ;;
    action)       en="Action:";                                zh="操作:" ;;
    a_status)     en="Status";                                 zh="查看状态" ;;
    a_stop)       en="Stop a session";                         zh="停止会话" ;;
    a_stop_all)   en="Stop all";                               zh="停止全部" ;;
    no_sessions)  en="No active sessions";                     zh="没有活动会话" ;;
    session)      en="Session:";                               zh="会话:" ;;
    stopped)      en="Stopped %s";                             zh="已停止 %s" ;;
    stop_fail)    en="Failed to stop %s";                      zh="停止失败 %s" ;;
    no_colab)     en="colab CLI not found. Install:";          zh="未找到 colab CLI。安装:" ;;
    no_ssh)       en="colab CLI has no ssh subcommand. Install:"; zh="colab CLI 没有 ssh 子命令。安装:" ;;
    gen_key)      en="Generating SSH key ...";                 zh="生成 SSH 密钥 ..." ;;
    sessions_err) en="colab sessions failed:";                 zh="colab sessions 执行失败:" ;;
  esac
  if [ "$UI_LANG" = zh ]; then printf "$zh\n" "$@"; else printf "$en\n" "$@"; fi
}

# Absolute path of the colab CLI
resolve_colab() {
  if [ -n "${COLAB_BIN:-}" ] && [ -x "${COLAB_BIN:-}" ]; then
    :
  elif command -v colab >/dev/null 2>&1; then
    COLAB_BIN="$(command -v colab)"
  elif [ -x "$HOME/.local/bin/colab" ]; then
    COLAB_BIN="$HOME/.local/bin/colab"
  else
    echo "!! $(t no_colab)" >&2
    echo "   uv tool install git+https://github.com/googlecolab/google-colab-cli" >&2
    return 1
  fi
  case "$COLAB_BIN" in
    /*) ;;
    *)  COLAB_BIN="$(cd "$(dirname "$COLAB_BIN")" && pwd)/$(basename "$COLAB_BIN")" ;;
  esac
  export COLAB_BIN
}

require_colab_ssh() {
  if ! "$COLAB_BIN" ssh --help >/dev/null 2>&1; then
    echo "!! $(t no_ssh)" >&2
    echo "   uv tool install --force git+https://github.com/googlecolab/google-colab-cli" >&2
    return 1
  fi
}

ensure_ssh_key() {
  for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa"; do
    if [ -f "$k" ]; then SSH_KEY="$k"; export SSH_KEY; return 0; fi
  done
  echo "==> $(t gen_key)"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N '' -C "colab-codex" -f "$HOME/.ssh/id_ed25519" >/dev/null
  SSH_KEY="$HOME/.ssh/id_ed25519"; export SSH_KEY
}

# Active session names, one per line; returns 1 if the query fails
list_sessions() {
  local out
  if ! out="$("$COLAB_BIN" sessions 2>&1)"; then
    echo "!! $(t sessions_err)" >&2
    echo "$out" | tail -3 | sed 's/^/   /' >&2
    return 1
  fi
  echo "$out" | grep -oE '^\[[A-Za-z0-9_.-]+\]' | tr -d '[]' | grep -v '^colab$' || true
}

# ---- GPU tiers ----
tier_flags() {
  case "$1" in
    h100)   echo "--gpu H100" ;;
    g4)     echo "--gpu G4" ;;
    a100hm) echo "--gpu A100 --high-mem" ;;
    a100)   echo "--gpu A100" ;;
  esac
}

tier_label() {
  case "$1" in
    h100)   echo "H100" ;;
    g4)     echo "G4" ;;
    a100hm) echo "A100 High-RAM" ;;
    a100)   echo "A100" ;;
  esac
}

# Fallback chain
tier_chain() {
  case "$1" in
    h100)   echo "h100 g4 a100hm" ;;
    g4)     echo "g4 a100hm" ;;
    a100hm) echo "a100hm" ;;
    a100)   echo "a100" ;;
    *)      return 1 ;;
  esac
}

# SSH options into the global array SSH_OPTS
build_ssh_opts() {
  local session="$1" flags="$2"
  mkdir -p "$HOME/.ssh/cm"
  SSH_OPTS=(
    -o "ProxyCommand=$COLAB_BIN ssh --proxy-mode -s $session -i $SSH_KEY $flags"
    -i "$SSH_KEY"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ControlMaster=auto
    -o "ControlPath=$HOME/.ssh/cm/$session"
    -o ControlPersist=10m
    -o ServerAliveInterval=30
  )
}
