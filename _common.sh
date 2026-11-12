#!/usr/bin/env bash
# Shared by start.sh and config.sh. bash 3.2 compatible.

# Language: UI_LANG env or a --zh/--en flag wins, else the one chosen last time, else English
LANG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/instantagent/lang"
if [ -z "${UI_LANG:-}" ] && [ -f "$LANG_FILE" ]; then UI_LANG="$(cat "$LANG_FILE" 2>/dev/null)"; fi
case "${UI_LANG:-}" in zh|en) ;; *) UI_LANG=en ;; esac
# save_lang: remember $UI_LANG for the next run of either script
save_lang() { mkdir -p "$(dirname "$LANG_FILE")" 2>/dev/null && echo "$UI_LANG" > "$LANG_FILE" 2>/dev/null || true; }

# t <key> [args]: message in $UI_LANG
t() {
  local k="$1" en zh; shift
  case "$k" in
    gpu)          en="GPU:";                                   zh="GPU:" ;;
    resume)       en="Resume %s";                              zh="恢复 %s" ;;
    model)        en="Model:";                                 zh="模型:" ;;
    mode)         en="Mode:";                                  zh="用途:" ;;
    m_agent)      en="Agent";                                  zh="Agent" ;;
    m_api)        en="API     public URL + token";              zh="API     公网地址 + token" ;;
    m_both)       en="Both";                                   zh="两者" ;;
    backend)      en="Backend:";                               zh="后端:" ;;
    b_vllm)       en="vLLM";                                   zh="vLLM" ;;
    b_ollama)     en="Ollama   GGUF, no tool calling";         zh="Ollama   GGUF，不支持工具调用" ;;
    d_fp8)        en="FP8 at load, about 31 GB VRAM";          zh="加载时 FP8，显存约 31 GB" ;;
    options)      en="Options:";                               zh="选项:" ;;
    o_default)    en="Default        thinking xhigh";          zh="默认       思考 xhigh" ;;
    o_fast)       en="Fast writing   thinking low · MTP x2";   zh="快速写作   思考 low · MTP x2" ;;
    o_nothink)    en="No thinking    MTP x2";                  zh="不思考     MTP x2" ;;
    o_ollama)     en="Default";                                zh="默认" ;;
    o_custom)     en="Custom ...";                             zh="自定义 ..." ;;
    recommended)  en="  <- recommended";                       zh="  <- 推荐" ;;
    q_think)      en="Thinking:";                              zh="思考:" ;;
    q_effort)     en="Reasoning effort:";                      zh="推理强度:" ;;
    q_spec)       en="Speculative decoding (MTP):";            zh="投机解码 (MTP):" ;;
    spec_hint)    en="about 1.8x";                             zh="约 1.8 倍" ;;
    spec_hint3)   en="about 2.3x";                             zh="约 2.3 倍" ;;
    q_ctx)        en="Context length:";                        zh="上下文长度:" ;;
    agent)        en="Agent:";                                 zh="Agent:" ;;
    invalid)      en="Invalid choice";                         zh="无效选择" ;;
    bad_opt)      en="Unknown option: %s";                     zh="未知参数: %s" ;;
    need_val)     en="%s needs a value";                       zh="%s 缺少取值" ;;
    bad_gpu)      en="Unknown GPU: %s (h100|g4|a100hm|a100)";  zh="未知 GPU: %s (h100|g4|a100hm|a100)" ;;
    bad_model)    en="Unknown model: %s (%s, or an HF repo id / Ollama ref)"; zh="未知模型: %s (%s，或 HF 仓库 ID / Ollama 模型引用)" ;;
    no_build)     en="%s is not available with %s";            zh="%s 不支持 %s 后端" ;;
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
    box_sampling) en=" Sampling temp %s   top_p %s   top_k %s   rep %s"; zh=" 采样     温度 %s   top_p %s   top_k %s   重复惩罚 %s" ;;
    box_mem)      en=" VRAM     %s MiB";                       zh=" 显存     %s MiB" ;;
    box_api)      en=" API      %s";                           zh=" API      %s" ;;
    box_token)    en=" Token    %s";                           zh=" Token    %s" ;;
    box_api_err)  en=" API      failed";                       zh=" API      失败" ;;
    box_later)    en=" Later    %s";                           zh=" 稍后查看 %s" ;;
    box_stop)     en=" Stop     %s";                           zh=" 停止     %s" ;;
    box_ka)       en=" Alive    %s";                           zh=" 保活     %s" ;;
    ka_on)        en="running, last ping %s";                zh="运行中，上次 %s" ;;
    ka_off)       en="not running";                          zh="未运行" ;;
    ka_started)   en="Keep-alive started: a no-op runs in the kernel every %s min (log: %s)"; zh="已启动保活：每 %s 分钟在内核执行一次空操作（日志 %s）" ;;
    ka_fail)      en="Keep-alive failed to start, see %s";    zh="保活启动失败，见 %s" ;;
    ka_stopped)   en="Keep-alive stopped";                   zh="已停止保活" ;;
    a_keepalive)  en="Start keep-alive";                     zh="启动保活" ;;
    no_session)   en="No active session named %s";          zh="没有名为 %s 的活动会话" ;;
    box_timer)    en=" Timer    VM up %s   status %ss old";      zh=" 计时     机器已开 %s   状态更新于 %s 秒前" ;;
    box_stale)    en=" Status   reporter stopped, last update %s ago"; zh=" 状态     汇报脚本已停，最后更新 %s 前" ;;
    box_gpu_live) en=" GPU      util %s%%   mem %s/%s MiB   %s°C   %s W"; zh=" GPU      利用率 %s%%   显存 %s/%s MiB   %s°C   %s W" ;;
    box_sys)      en=" System   load %s/%s   RAM %s/%s GB   disk free %s"; zh=" 系统     负载 %s/%s   内存 %s/%s GB   磁盘可用 %s" ;;
    box_reqs)     en=" Requests running %s   waiting %s   done %s   errors %s   last %s"; zh=" 请求     进行中 %s   排队 %s   累计 %s   出错 %s   上次 %s" ;;
    box_thru)     en=" Rate     %s tok/s now   KV %s%%   prompt %s · generated %s tokens"; zh=" 吞吐     当前生成 %s tok/s   KV 占用 %s%%   累计 prompt %s · 生成 %s tokens" ;;
    box_parts)    en=" Parts    %s";                           zh=" 组件     %s" ;;
    c_tunnel)     en="tunnel";                                 zh="隧道" ;;
    c_proxy)      en="proxy";                                  zh="代理" ;;
    running)      en="running";                                zh="运行中" ;;
    stopped_s)    en="stopped";                                zh="已停止" ;;
    none_yet)     en="none yet";                               zh="暂无" ;;
    just_now)     en="just now";                               zh="刚刚" ;;
    ago)          en="%s ago";                                 zh="%s 前" ;;
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
    sessions_err) en="colab sessions failed:";                zh="colab sessions 执行失败:" ;;
    box_hw)       en=" Hardware %s   %s";                       zh=" 硬件     %s   %s" ;;
    box_health)   en=" Status   %s   up %s";                     zh=" 状态     %s   已运行 %s" ;;
    box_kv)       en=" KV cache %s tokens   full-context streams %s"; zh=" 缓存     KV %s tokens   满上下文并发 %s" ;;
    box_think)    en=" Thinking %s   Effort %s   Speculative %s"; zh=" 思考     %s   推理强度 %s   投机解码 %s" ;;
    box_speed)    en=" Speed    %s tok/s (single stream)";       zh=" 速度     %s tok/s（单路）" ;;
    box_time)     en=" Time     deploy %s   backend start %s";   zh=" 耗时     部署 %s   后端启动 %s" ;;
    box_log)      en=" Log      %s";                             zh=" 日志     %s" ;;
    on)           en="on";                                       zh="开" ;;
    off)          en="off";                                      zh="关" ;;
    default)      en="default";                                  zh="默认" ;;
    healthy)      en="serving";                                  zh="正常" ;;
    unhealthy)    en="not responding";                           zh="无响应" ;;
    curl_hint)    en="Try it (the URL changes whenever the tunnel restarts):"; zh="试一下（隧道重启后地址会变）:" ;;
    deploy_fail)  en="Deploy failed, local log: %s";             zh="部署失败，本地日志: %s" ;;
    bad_reasoning) en="REASONING must be low, medium or xhigh (got %s)"; zh="REASONING 只能是 low、medium 或 xhigh（当前 %s）" ;;
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

# ---- Models ----
# Presets in menu order; the first is the default
MODELS="obliterated obliterated-q8 obliterated-q6 obliterated-q4 hemmingway"

# model_ref <model> <backend>: HF repo id (vllm) or Ollama ref (ollama);
# fails if the preset has no build for that backend.
# Anything containing / or : is already a ref and passes through.
model_ref() {
  case "$1" in */*|*:*) echo "$1"; return 0 ;; esac
  case "$1:$2" in
    obliterated:vllm|obliterated-q8:vllm)
                           echo "OBLITERATUS/Qwen3.8-27B-OBLITERATED" ;;
    obliterated-q4:vllm)   echo "quocbao747/Qwen3.8-27B-OBLITERATED-W4A16-24GB" ;;
    obliterated:ollama|obliterated-q8:ollama)
                           echo "hf.co/OBLITERATUS/Qwen3.8-27B-OBLITERATED:Q8_0" ;;
    obliterated-q6:ollama) echo "hf.co/OBLITERATUS/Qwen3.8-27B-OBLITERATED:Q6_K" ;;
    obliterated-q4:ollama) echo "hf.co/OBLITERATUS/Qwen3.8-27B-OBLITERATED:Q4_K_M" ;;
    hemmingway:vllm)       echo "HemmingwayAI/Hemmingway-1" ;;
    hemmingway:ollama)     echo "hf.co/mradermacher/Hemmingway-1-GGUF:Q8_0" ;;
    *)                     return 1 ;;
  esac
}

# model_quant <model> <backend>: quantization vLLM applies at load time
model_quant() {
  case "$1:$2" in
    obliterated-q8:vllm) echo fp8 ;;
  esac
}

# model_sampling <model>: temperature top_p top_k repetition_penalty
model_sampling() {
  case "$1" in
    obliterated*) echo "0.2 0.95 20 1.15" ;;  # OBLITERATED model card, agentic settings
    *)            echo "1.0 0.95 20 1.0" ;;   # Qwen3.8 thinking mode; Hemmingway-1 ships the same
  esac
}

# model_preset <ref> <backend> [quant]: the preset that deploys this, else the ref itself
model_preset() {
  for m in $MODELS; do
    if [ "$(model_ref "$m" "$2")" = "$1" ] && [ "$(model_quant "$m" "$2")" = "${3:-}" ]; then
      echo "$m"; return 0
    fi
  done
  echo "$1"
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

# ---- Runtime info ----
# inf <field> [default]: a runtime_stats field from $INFO; the first match wins
inf() {
  local v
  v="$(printf '%s\n' "${INFO:-}" | sed -n "s|^$1=||p" | head -1)"
  echo "${v:-${2:-}}"
}

# fmt_secs <n>: 75 -> 1m15s; "-" when empty or not a number
fmt_secs() {
  case "${1:-}" in ''|*[!0-9]*) echo "-"; return 0 ;; esac
  if [ "$1" -ge 60 ]; then echo "$(( $1 / 60 ))m$(( $1 % 60 ))s"; else echo "${1}s"; fi
}

# Info rows shared by start.sh and config.sh, rendered from $INFO
print_info_rows() {
  local q spec r
  [ -n "$(inf gpu)" ] && t box_hw "$(inf gpu)" "$(inf engine)"
  if [ -n "$(inf health)" ]; then
    if [ "$(inf health)" = ok ]; then r="$(t healthy)"; else r="$(t unhealthy)"; fi
    t box_health "$r" "$(fmt_secs "$(inf up_secs)")"
  fi
  [ -n "$(inf keepalive)" ] && t box_ka "$(inf keepalive)"
  print_live_rows
  t box_backend "$(inf backend)" "$(inf agent)"
  q="$(inf quant)"
  t box_model "$(inf model)${q:+ ($q)}"
  [ -n "$(inf alias)" ] && t box_served "$(inf alias)"
  [ -n "$(inf ctx)" ] && t box_ctx "$(inf ctx)" "$(inf maxout ?)" "$(inf parallel 1)"
  [ -n "$(inf kv_tokens)" ] && t box_kv "$(inf kv_tokens)" "$(inf kv_conc)"
  t box_sampling "$(inf temp)" "$(inf top_p)" "$(inf top_k)" "$(inf rep)"
  if [ -n "$(inf think)" ]; then
    spec="$(inf spec 0)"
    if [ "$spec" = 0 ]; then spec="$(t off)"; else spec="MTP x$spec"; fi
    r="$(inf reasoning)"; [ -n "$r" ] || r="$(t default)"
    if [ "$(inf think)" = 0 ]; then t box_think "$(t off)" "$r" "$spec"; else t box_think "$(t on)" "$r" "$spec"; fi
  fi
  [ -n "$(inf tps)" ] && t box_speed "$(inf tps)"
  [ -n "$(inf mem)" ] && [ -z "$(inf gpu_mem_used)" ] && t box_mem "$(inf mem)"
  [ -n "$(inf deploy_secs)" ] && t box_time "$(fmt_secs "$(inf deploy_secs)")" "$(fmt_secs "$(inf start_secs)")"
  [ -n "$(inf url)" ] && t box_api "$(inf url)"
  [ -n "$(inf token)" ] && t box_token "$(inf token)"
  return 0
}

# fmt_k <n>: 950148 -> 950k, 1234567 -> 1.2M
fmt_k() {
  awk -v n="${1:-0}" 'BEGIN { if (n >= 1e6) printf "%.1fM", n / 1e6; else if (n >= 1e3) printf "%.0fk", n / 1e3; else printf "%d", n }'
}

# Rows from the VM's status reporter (/root/.codex/status, see _remote_setup.sh)
print_live_rows() {
  local age lr parts
  [ -n "$(inf ts)" ] || return 0
  age="$(inf status_age 0)"
  if [ "$age" -gt 60 ] 2>/dev/null; then
    t box_stale "$(fmt_secs "$age")"
    return 0
  fi
  t box_timer "$(fmt_secs "$(inf vm_up)")" "$age"
  [ -n "$(inf gpu_util)" ] && t box_gpu_live "$(inf gpu_util)" "$(inf gpu_mem_used)" "$(inf gpu_mem_total)" "$(inf gpu_temp)" "$(inf gpu_power)"
  t box_sys "$(inf load1)" "$(inf cpus)" "$(inf ram_used)" "$(inf ram_total)" "$(inf disk_free)"
  if [ -n "$(inf reqs_done)" ]; then
    lr="$(inf last_req_ago)"
    if [ -z "$lr" ]; then lr="$(t none_yet)"
    elif [ $((lr + age)) -lt 10 ]; then lr="$(t just_now)"
    else lr="$(t ago "$(fmt_secs $((lr + age)))")"; fi
    t box_reqs "$(inf reqs_running)" "$(inf reqs_waiting)" "$(inf reqs_done)" "$(inf reqs_err 0)" "$lr"
    t box_thru "$(inf gen_rate 0)" "$(inf kv_usage 0)" "$(fmt_k "$(inf prompt_tokens)")" "$(fmt_k "$(inf gen_tokens)")"
  fi
  parts=""
  if [ -n "$(inf url)" ]; then
    if [ "$(inf tunnel)" = ok ]; then parts="$(t c_tunnel) $(t healthy)"; else parts="$(t c_tunnel) $(t unhealthy)"; fi
    if [ "$(inf proxy)" = ok ]; then parts="$parts   $(t c_proxy) $(t healthy)"; else parts="$parts   $(t c_proxy) $(t unhealthy)"; fi
  fi
  if [ -n "$(inf herdr_state)" ]; then
    if [ "$(inf herdr_state)" = running ]; then parts="$parts   herdr $(t running)"; else parts="$parts   herdr $(t stopped_s)"; fi
  fi
  parts="${parts#   }"
  [ -n "$parts" ] && t box_parts "$parts"
  return 0
}

# print_curl <url> <token> <alias>: a request ready to paste
print_curl() {
  echo
  t curl_hint
  echo "  curl $1/v1/chat/completions \\"
  echo "    -H \"Authorization: Bearer $2\" -H \"Content-Type: application/json\" \\"
  echo "    -d '{\"model\":\"$3\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
}

# ---- Model menu text ----
# model_size <model> <backend>: weight size shown in the menu
model_size() {
  case "$1:$2" in
    obliterated:vllm)      echo "55 GB" ;;
    obliterated-q8:vllm)   echo "55 GB" ;;
    obliterated-q4:vllm)   echo "20 GB" ;;
    hemmingway:vllm)       echo "55 GB" ;;
    obliterated:ollama|obliterated-q8:ollama)
                           echo "29 GB" ;;
    obliterated-q6:ollama) echo "22 GB" ;;
    obliterated-q4:ollama) echo "17 GB" ;;
    hemmingway:ollama)     echo "29 GB" ;;
  esac
}

# model_name <model>: display name in the menu
model_name() {
  case "$1" in
    obliterated*) echo "Qwen 3.8 27B" ;;
    hemmingway)   echo "Hemmingway-1" ;;
    *)            echo "$1" ;;
  esac
}

# model_desc <model> <backend>: the build's quantization
model_desc() {
  case "$1:$2" in
    obliterated:vllm|hemmingway:vllm)
                           echo "BF16" ;;
    obliterated-q8:vllm)   t d_fp8 ;;
    obliterated-q4:vllm)   echo "GPTQ 4-bit" ;;
    obliterated:ollama|obliterated-q8:ollama|hemmingway:ollama)
                           echo "Q8_0 GGUF" ;;
    obliterated-q6:ollama) echo "Q6_K GGUF" ;;
    obliterated-q4:ollama) echo "Q4_K_M GGUF" ;;
  esac
}

# ---- Keep-alive ----
# colab CLI 0.7.3+ has no keep-alive daemon, and Colab prunes a session with no
# kernel activity after about an hour; ssh traffic does not count. So a detached
# loop runs a no-op in the session's kernel every KA_INTERVAL seconds and exits
# by itself once the session is gone. One loop per session, tracked by a pid file.
# The loop is written to its own file first: bash reads scripts incrementally, so
# a loop running straight from this file would break on the next edit here.
KA_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/instantagent"
KA_INTERVAL="${KA_INTERVAL:-300}"

ka_pid_file() { echo "$KA_DIR/keepalive-$1.pid"; }
ka_log_file() { echo "$KA_DIR/keepalive-$1.log"; }

# ka_pid <session>: pid of the live loop, or failure
ka_pid() {
  local pid
  pid="$(cat "$(ka_pid_file "$1")" 2>/dev/null)" || return 1
  [ -n "$pid" ] || return 1
  ps -o args= -p "$pid" 2>/dev/null | grep -q "keepalive-$1.sh" || return 1
  echo "$pid"
}

# ka_status <session>: one line for the info box
ka_status() {
  local last
  if ka_pid "$1" >/dev/null; then
    last="$(awk '/ ok$/ {t=$2} END {print t}' "$(ka_log_file "$1")" 2>/dev/null || true)"
    t ka_on "${last:-?}"
  else
    t ka_off
  fi
}

# ka_start <session>: start the loop unless it is already running
ka_start() {
  local s="$1" f i
  ka_pid "$s" >/dev/null && return 0
  mkdir -p "$KA_DIR"
  rm -f "$(ka_pid_file "$s")"
  f="$KA_DIR/keepalive-$s.sh"
  {
    echo '#!/usr/bin/env bash'
    echo "# Keep-alive for colab session $s, written by InstantAgent (_common.sh ka_start)"
    echo "S='$s'; COLAB='$COLAB_BIN'; EVERY=$KA_INTERVAL"
    echo "LOG='$(ka_log_file "$s")'; PIDF='$(ka_pid_file "$s")'"
    cat <<'EOF'
# One loop per session: a second copy exits at once
if p="$(cat "$PIDF" 2>/dev/null)" && [ -n "$p" ] && [ "$p" != "$$" ] \
   && ps -o args= -p "$p" 2>/dev/null | grep -q "keepalive-$S.sh"; then exit 0; fi
echo $$ > "$PIDF"
# colab exec occasionally hangs under load; never let one call stall the loop
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 120"
if [ -f "$LOG" ]; then tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; fi
echo "$(date '+%F %T') started pid $$ every ${EVERY}s" >> "$LOG"
while :; do
  # Stop once the session is really gone; a failed listing (network) is not that
  if out="$($TO "$COLAB" sessions 2>/dev/null)"; then
    echo "$out" | grep -q "^\[$S\]" || break
  fi
  if echo pass | $TO "$COLAB" exec -s "$S" >/dev/null 2>&1; then
    echo "$(date '+%F %T') ok" >> "$LOG"
  else
    echo "$(date '+%F %T') exec failed" >> "$LOG"
  fi
  sleep "$EVERY"
done
echo "$(date '+%F %T') session gone, exiting" >> "$LOG"
rm -f "$PIDF"
EOF
  } > "$f"
  ( nohup bash "$f" >/dev/null 2>&1 </dev/null & )
  for i in 1 2 3 4 5 6 7 8 9 10; do ka_pid "$s" >/dev/null && break; sleep 0.5; done
  if ka_pid "$s" >/dev/null; then
    echo "==> $(t ka_started $(( (KA_INTERVAL + 59) / 60 )) "$(ka_log_file "$s")")"
  else
    echo "!! $(t ka_fail "$(ka_log_file "$s")")"
  fi
}

# ka_stop <session>
ka_stop() {
  local s="$1" pid
  if pid="$(ka_pid "$s")"; then
    kill "$pid" 2>/dev/null || true
    echo "$(date '+%F %T') stopped" >> "$(ka_log_file "$s")"
    t ka_stopped
  fi
  rm -f "$(ka_pid_file "$s")"
}
