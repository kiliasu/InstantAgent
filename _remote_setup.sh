#!/usr/bin/env bash
# Runs on the Colab VM: deploy the inference backend and agent
#
# Env:
#   MODEL_REF     required. HF repo id for vllm, ollama model ref for ollama
#   QUANT         vllm only: fp8 = quantize the weights to FP8 at load time
#   BACKEND       vllm (default) | ollama
#   AGENT         opencode (default) | omp | codex
#   OMO           1 (default, opencode + oh-my-openagent) | 0
#   HERDR         1 (default, agent runs inside herdr) | 0
#   CONTEXT       context length, default 262144
#   MAX_OUTPUT    max tokens per reply, default 16384
#   TEMPERATURE / TOP_P / TOP_K / REPETITION_PENALTY   default sampling
#   KV_TYPE       ollama only: KV cache quant, default q8_0
#   PARALLEL      ollama only: parallel slots, default 1
#   MAX_SEQS      vllm only: max concurrent sequences, default 64
#   THINKING      vllm only: 1 (default) | 0 = answer without a thinking block
#   REASONING     vllm only: low | medium | xhigh, thinking effort (template default: xhigh)
#   SPEC_TOKENS   vllm only: MTP speculative decoding, draft tokens per step, default 0 = off
#   UI_LANG       en (default) | zh
set -euo pipefail

MODEL="${MODEL_REF:?MODEL_REF is required}"
BACKEND="${BACKEND:-vllm}"
AGENT="${AGENT:-opencode}"
CTX="${CONTEXT:-262144}"
MAXOUT="${MAX_OUTPUT:-16384}"
QUANT="${QUANT:-}"
TEMPERATURE="${TEMPERATURE:-1.0}"
TOP_P="${TOP_P:-0.95}"
TOP_K="${TOP_K:-20}"
REP_PENALTY="${REPETITION_PENALTY:-1.0}"
ALIAS="local-model"
PORT=11434
# vLLM concurrency cap. vLLM defaults to 1024 on >=70 GB GPUs (H100, G4), but the
# Qwen3.8 hybrid models need one Mamba cache block per in-flight sequence, and at
# 262k context only a few hundred fit, so startup fails. 64 is plenty for an agent + API.
MAX_SEQS="${MAX_SEQS:-64}"
THINKING="${THINKING:-1}"
REASONING="${REASONING:-}"
SPEC_TOKENS="${SPEC_TOKENS:-0}"
UI_LANG="${UI_LANG:-en}"
DEPLOY_T0="$(date +%s)"
# Filled in along the way, written to runtime_stats at the end
START_SECS="" TPS="" KV_TOKENS="" KV_CONC="" ENGINE_VER=""
mkdir -p /root/.codex

# t <key> [args]: message in $UI_LANG
t() {
  local k="$1" en zh; shift
  case "$k" in
    no_gpu)         en="No GPU detected";                       zh="未检测到 GPU" ;;
    deps)           en="Installing dependencies";               zh="安装依赖" ;;
    vllm_install)   en="Installing vLLM";                        zh="安装 vLLM" ;;
    vllm_inst_fail) en="vLLM install failed:";                  zh="vLLM 安装失败:" ;;
    download)       en="Downloading weights";                   zh="下载权重" ;;
    download_fail)  en="Download failed";                       zh="下载失败" ;;
    tpl_patched)    en="Patching chat template";                 zh="修补对话模板" ;;
    vllm_start)     en="Starting vLLM";                          zh="启动 vLLM" ;;
    vllm_fail)      en="vLLM failed to start:";                 zh="vLLM 启动失败:" ;;
    vllm_timeout)   en="vLLM start timed out:";                  zh="vLLM 启动超时:" ;;
    ollama_install) en="Installing Ollama";                     zh="安装 Ollama" ;;
    ollama_fail)    en="Ollama failed to start";                zh="Ollama 启动失败" ;;
    ollama_start)   en="Starting Ollama";                       zh="启动 Ollama" ;;
    ollama_restart) en="Restarting Ollama";                      zh="重启 Ollama" ;;
    pull)           en="Pulling model";                         zh="拉取模型" ;;
    pull_retry)     en="Pull attempt %s failed, retrying";       zh="第 %s 次拉取失败，重试" ;;
    pull_fail)      en="Pull failed";                            zh="拉取失败" ;;
    configure)      en="Configuring model";                      zh="配置模型" ;;
    codex_install)  en="Installing Codex CLI";                  zh="安装 Codex CLI" ;;
    omp_install)    en="Installing omp";                        zh="安装 omp" ;;
    oc_install)     en="Installing opencode";                   zh="安装 opencode" ;;
    omo_install)    en="Installing oh-my-openagent";            zh="安装 oh-my-openagent" ;;
    omo_fail)       en="oh-my-openagent install failed, see /var/log/omo_install.log"; zh="oh-my-openagent 安装失败，见 /var/log/omo_install.log" ;;
    workspace)      en="Initializing workspace";                zh="初始化工作区" ;;
    herdr_install)  en="Installing herdr";                      zh="安装 herdr" ;;
    herdr_start)    en="Starting herdr";                        zh="启动 herdr" ;;
    herdr_ws)       en="Setting up workspace";                  zh="布置工作区" ;;
    herdr_fail)     en="herdr install failed, running agent directly"; zh="herdr 安装失败，agent 直接运行" ;;
    smoke)          en="Checking tool calling";                 zh="自检工具调用" ;;
    smoke_ok)       en="Tool calling OK";                       zh="工具调用正常" ;;
    smoke_fail)     en="Tool calling failed";                    zh="工具调用失败" ;;
    tunnel)         en="Setting up tunnel";                     zh="配置公网隧道" ;;
    tunnel_reuse)   en="Reusing tunnel";                        zh="复用已有隧道" ;;
    tunnel_ok)      en="Tunnel ready";                          zh="隧道就绪" ;;
    tunnel_fail)    en="Tunnel failed";                          zh="隧道失败" ;;
    vllm_ready)     en="vLLM ready (%ss)";                       zh="vLLM 就绪（%s 秒）" ;;
    m_weights)      en="weights loaded: %s GiB, %ss";            zh="权重加载完成：%s GiB，%s 秒" ;;
    m_compile)      en="torch.compile done: %ss";                zh="torch.compile 完成：%s 秒" ;;
    m_warmup)       en="warmup done: %ss";                       zh="预热完成：%s 秒" ;;
    m_graphs)       en="CUDA graphs captured: %ss";              zh="CUDA graph 捕获完成：%s 秒" ;;
    m_kv)           en="KV cache: %s tokens, %s streams at full context"; zh="KV cache：%s tokens，满上下文并发 %s" ;;
    root_cause)     en="Root cause:";                            zh="根因:" ;;
    full_log)       en="Full log: %s";                           zh="完整日志: %s" ;;
    kernels)        en="Downloading precompiled kernels";        zh="下载预编译内核" ;;
    kernels_fail)   en="Kernel download failed, see /var/log/vllm_kernels.log; startup will JIT-compile"; zh="预编译内核下载失败，见 /var/log/vllm_kernels.log；启动时将现场编译" ;;
    speed)          en="Measuring generation speed";             zh="测量生成速度" ;;
    speed_ok)       en="%s tok/s (single stream)";               zh="%s tok/s（单路）" ;;
    speed_fail)     en="Speed probe failed";                     zh="速度测量失败" ;;
    bad_reasoning)  en="REASONING must be low, medium or xhigh (got %s)"; zh="REASONING 只能是 low、medium 或 xhigh（当前 %s）" ;;
    no_mtp)         en="Model has no MTP head, speculative decoding off"; zh="模型没有 MTP 头，已关闭投机解码" ;;
  esac
  if [ "$UI_LANG" = zh ]; then printf "$zh\n" "$@"; else printf "$en\n" "$@"; fi
}
step() { echo "  · $(t "$@")"; }
ok()   { echo "  ✔ $(t "$@")"; }
fail() { echo "  ✖ $(t "$@")"; }
warn() { echo "  ! $(t "$@")"; }
prog() { local el="$1"; shift; printf "    [%ss] %s\n" "$el" "$(t "$@")"; }

case "$REASONING" in
  ""|low|medium|xhigh) ;;
  *) fail bad_reasoning "$REASONING"; exit 1 ;;
esac

# vLLM startup milestones from /var/log/vllm.log, each printed once with the
# elapsed time since T_VLLM. Fills KV_TOKENS / KV_CONC.
vllm_progress() {
  local l el
  el=$(( $(date +%s) - T_VLLM ))
  case "$SEEN" in *weights*) ;; *)
    l="$(grep -aoE 'Model loading took [0-9.]+ GiB memory and [0-9.]+ seconds' /var/log/vllm.log 2>/dev/null | head -1 || true)"
    if [ -n "$l" ]; then
      SEEN="$SEEN weights"
      prog "$el" m_weights "$(echo "$l" | awk '{print $4}')" "$(echo "$l" | awk '{printf "%.0f", $8}')"
    fi ;;
  esac
  case "$SEEN" in *compile*) ;; *)
    l="$(grep -aoE 'torch\.compile took [0-9.]+ s in total' /var/log/vllm.log 2>/dev/null | head -1 || true)"
    if [ -n "$l" ]; then
      SEEN="$SEEN compile"
      prog "$el" m_compile "$(echo "$l" | awk '{printf "%.0f", $3}')"
    fi ;;
  esac
  case "$SEEN" in *warmup*) ;; *)
    l="$(grep -aoE 'Initial profiling/warmup run took [0-9.]+ s' /var/log/vllm.log 2>/dev/null | head -1 || true)"
    if [ -n "$l" ]; then
      SEEN="$SEEN warmup"
      prog "$el" m_warmup "$(echo "$l" | awk '{printf "%.0f", $5}')"
    fi ;;
  esac
  case "$SEEN" in *graphs*) ;; *)
    l="$(grep -aoE 'Graph capturing finished in [0-9]+ secs' /var/log/vllm.log 2>/dev/null | head -1 || true)"
    if [ -n "$l" ]; then
      SEEN="$SEEN graphs"
      prog "$el" m_graphs "$(echo "$l" | awk '{print $5}')"
    fi ;;
  esac
  case "$SEEN" in *kv*) ;; *)
    vllm_kv_info
    if [ -n "$KV_TOKENS" ]; then
      SEEN="$SEEN kv"
      prog "$el" m_kv "$KV_TOKENS" "$KV_CONC"
    fi ;;
  esac
  return 0
}

vllm_kv_info() {
  local l
  l="$(grep -aoE 'GPU KV cache size: [0-9,]+ tokens, Maximum concurrency for [0-9,]+ tokens per request: [0-9.]+x' /var/log/vllm.log 2>/dev/null | head -1 || true)"
  KV_TOKENS="$(echo "$l" | awk '{print $5}')"
  KV_CONC="$(echo "$l" | awk '{print $NF}')"
  return 0
}

# Why vLLM died: the root-cause exception first, then a readable tail
# (progress bars stripped). $1 = tail lines.
vllm_diag() {
  local n="${1:-12}" root
  root="$(grep -aE '^\(EngineCore[^)]*\) ERROR [^ ]+ [^ ]+ \[[^]]*\] [A-Za-z_.]*(Error|Exception): ' /var/log/vllm.log 2>/dev/null \
          | tail -1 | sed -E 's/^\(EngineCore[^)]*\) ERROR [^ ]+ [^ ]+ \[[^]]*\] //' || true)"
  [ -n "$root" ] || root="$(grep -aE '^[A-Za-z_.]+(Error|Exception): ' /var/log/vllm.log 2>/dev/null \
          | grep -v 'Engine core initialization failed' | tail -1 || true)"
  if [ -n "$root" ]; then
    echo "    $(t root_cause) $root"
    # Continuation lines, e.g. pydantic's "Value error, ..." under "N validation errors for X"
    grep -aA3 -F -- "$root" /var/log/vllm.log 2>/dev/null | tail -n +2 \
      | grep -aE '^[[:space:]]+[A-Za-z]' | grep -av 'For further information' | head -2 \
      | sed -E 's/^[[:space:]]+/      /' | cut -c1-240 || true
  fi
  echo "    $(t full_log /var/log/vllm.log)"
  tr '\r' '\n' < /var/log/vllm.log | grep -avE 'it/s\]|^[[:space:]]*$' | tail -n "$n" | cut -c1-240 | sed 's/^/    /' || true
  return 0
}

# ---- GPU ----
if [ -d /usr/lib64-nvidia ]; then
  export LD_LIBRARY_PATH="/usr/lib64-nvidia${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  ldconfig /usr/lib64-nvidia 2>/dev/null || true
fi
nvidia-smi -L >/dev/null 2>&1 || warn no_gpu

# ---- System packages ----
NEED_PKGS=()
if [ "$AGENT" = codex ]; then
  command -v bwrap >/dev/null 2>&1 || NEED_PKGS+=(bubblewrap)
fi
if [ "$BACKEND" = ollama ]; then
  command -v zstd >/dev/null 2>&1 || NEED_PKGS+=(zstd)
else
  command -v ninja  >/dev/null 2>&1 || NEED_PKGS+=(ninja-build)
  command -v cmake  >/dev/null 2>&1 || NEED_PKGS+=(cmake)
  command -v g++    >/dev/null 2>&1 || NEED_PKGS+=(build-essential)
fi
if [ ${#NEED_PKGS[@]} -gt 0 ]; then
  step deps
  apt-get install -y -qq "${NEED_PKGS[@]}" >/dev/null 2>&1 || {
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq "${NEED_PKGS[@]}" >/dev/null 2>&1
  }
fi

server_up() { curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; }

# ============================ vLLM ============================
if [ "$BACKEND" = vllm ]; then
  VENV=/opt/vllm
  HF_REPO="${MODEL#hf.co/}"; HF_REPO="${HF_REPO%%:*}"
  MODEL_DIR="/root/models/$(echo "$HF_REPO" | tr '/' '_')"

  export PATH="$HOME/.local/bin:$PATH"
  if [ ! -x "$VENV/bin/vllm" ]; then
    step vllm_install
    command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null | sh >/dev/null 2>&1
    uv venv "$VENV" --python 3.12 >/dev/null 2>&1
    if ! uv pip install --python "$VENV/bin/python" vllm >/var/log/vllm_install.log 2>&1; then
      fail vllm_inst_fail; tail -15 /var/log/vllm_install.log; exit 1
    fi
  fi
  # FlashInfer's precompiled kernels; without them every cold start JIT-compiles for a minute
  if ! ls -d "$VENV"/lib/python*/site-packages/flashinfer_cubin >/dev/null 2>&1; then
    step kernels
    "$VENV/bin/vllm" download-kernels >/var/log/vllm_kernels.log 2>&1 || warn kernels_fail
  fi

  if [ ! -f "$MODEL_DIR/config.json" ] || [ ! -f "$MODEL_DIR/.download_complete" ]; then
    step download
    HF_HUB_DISABLE_PROGRESS_BARS=1 "$VENV/bin/python" - "$HF_REPO" "$MODEL_DIR" <<'DLEOF' || { fail download_fail; exit 1; }
import json, os, sys
from huggingface_hub import snapshot_download

repo, dest = sys.argv[1], sys.argv[2]
META = ["*.json", "*.txt", "*.jinja", "*.model", "*.py"]

snapshot_download(repo, local_dir=dest, allow_patterns=META)

idx = os.path.join(dest, "model.safetensors.index.json")
if os.path.exists(idx):
    need = sorted(set(json.load(open(idx))["weight_map"].values()))
    patterns = META + need
else:
    patterns = META + ["*.safetensors"]

snapshot_download(repo, local_dir=dest, max_workers=8, allow_patterns=patterns)
open(os.path.join(dest, ".download_complete"), "w").close()
DLEOF
  fi

  # Chat template, cached per model
  TPL="/root/.codex/chat_template.$(basename "$MODEL_DIR").jinja"
  if [ ! -s "$TPL" ]; then
    SRC="$MODEL_DIR/chat_template.jinja"
    if [ ! -s "$SRC" ] || ! grep -q "tools" "$SRC" 2>/dev/null; then
      case "$HF_REPO" in
        *Qwen3.8*) UP=Qwen/Qwen3.8-27B ;;
        *Qwen3.6*) UP=Qwen/Qwen3.6-27B ;;
        *)         UP="" ;;
      esac
      if [ -n "$UP" ]; then
        curl -fsSL -m 120 "https://huggingface.co/$UP/raw/main/chat_template.jinja" \
          -o "$TPL" 2>/dev/null || true
      fi
    fi
    if [ ! -s "$TPL" ] && [ -s "$SRC" ]; then cp "$SRC" "$TPL"; fi
  fi
  if [ -s "$TPL" ] && grep -q "System message must be at the beginning" "$TPL"; then
    python3 - "$TPL" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace(
    "{{- raise_exception('System message must be at the beginning.') }}",
    "{{- '<|im_start|>system\\n' + content + '<|im_end|>\\n' }}")
open(p, "w").write(s)
PY
    step tpl_patched
  fi

  # Default sampling for requests that don't set their own
  GEN_CFG="{\"temperature\":$TEMPERATURE,\"top_p\":$TOP_P,\"top_k\":$TOP_K,\"repetition_penalty\":$REP_PENALTY}"
  QUANT_ARGS=()
  if [ "$QUANT" = fp8 ]; then
    # Qwen's own FP8 recipe: 128x128 blocks, GDN gate projection and vision tower stay BF16
    QUANT_ARGS=(--quantization fp8_per_block
                --quantization-config '{"ignore":["*in_proj_ba","*visual*"]}')
  fi

  # Chat template defaults: thinking on/off and reasoning effort (Qwen3.8 template)
  TPL_KW=""
  [ "$THINKING" = 0 ] && TPL_KW='"enable_thinking":false'
  [ -n "$REASONING" ] && TPL_KW="${TPL_KW:+$TPL_KW,}\"reasoning_effort\":\"$REASONING\""
  TPL_ARGS=()
  [ -n "$TPL_KW" ] && TPL_ARGS=(--default-chat-template-kwargs "{$TPL_KW}")

  # MTP speculative decoding, opt-in; needs the model's MTP head, otherwise vLLM won't start
  SPEC_ARGS=()
  if [ "$SPEC_TOKENS" -gt 0 ] 2>/dev/null; then
    if grep -q '"mtp' "$MODEL_DIR/model.safetensors.index.json" 2>/dev/null \
       || grep -qE '"mtp_num_hidden_layers": *[1-9]' "$MODEL_DIR/config.json" 2>/dev/null; then
      SPEC_ARGS=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":$SPEC_TOKENS}")
    else
      warn no_mtp
      SPEC_TOKENS=0
    fi
  fi

  # Restart on config change
  TPL_SIG=none
  [ -s "$TPL" ] && TPL_SIG="$(md5sum "$TPL" | cut -d" " -f1)"
  WANT="model=$HF_REPO quant=${QUANT:-none} ctx=$CTX seqs=$MAX_SEQS think=$THINKING reasoning=${REASONING:-default} spec=$SPEC_TOKENS alias=$ALIAS tpl=$TPL_SIG gen=$GEN_CFG"
  if ! server_up || [ "$WANT" != "$(cat /root/.codex/server_env 2>/dev/null || true)" ]; then
    pkill -f 'vllm serve' 2>/dev/null || true
    pkill -x ollama 2>/dev/null || true
    sleep 2
    step vllm_start
    CHAT_ARG=""
    [ -s "$TPL" ] && CHAT_ARG="--chat-template $TPL"
    # 0.93: vLLM's memory profiler now counts CUDA graphs, so this matches the old 0.92 budget
    # shellcheck disable=SC2086
    nohup "$VENV/bin/vllm" serve "$MODEL_DIR" \
      --served-model-name "$ALIAS" \
      --host 127.0.0.1 --port "$PORT" \
      --max-model-len "$CTX" \
      --max-num-seqs "$MAX_SEQS" \
      --gpu-memory-utilization 0.93 \
      --kv-cache-dtype fp8 \
      --enable-auto-tool-choice \
      --tool-call-parser qwen3_coder \
      --reasoning-parser qwen3 \
      --override-generation-config "$GEN_CFG" \
      ${QUANT_ARGS[@]+"${QUANT_ARGS[@]}"} \
      ${TPL_ARGS[@]+"${TPL_ARGS[@]}"} \
      ${SPEC_ARGS[@]+"${SPEC_ARGS[@]}"} \
      $CHAT_ARG \
      >/var/log/vllm.log 2>&1 &
    echo "$WANT" > /root/.codex/server_env
    T_VLLM="$(date +%s)"
    SEEN=""
    for _ in $(seq 1 240); do
      vllm_progress
      server_up && break
      if ! pgrep -f 'vllm serve' >/dev/null 2>&1; then
        fail vllm_fail; vllm_diag 12; exit 1
      fi
      sleep 5
    done
    vllm_progress
    server_up || { fail vllm_timeout; vllm_diag 6; exit 1; }
    START_SECS=$(( $(date +%s) - T_VLLM ))
    ok vllm_ready "$START_SECS"
  fi
  vllm_kv_info
  ENGINE_VER="vLLM $(grep -aoE 'version [0-9][^ ]*' /var/log/vllm.log 2>/dev/null | head -1 | cut -d' ' -f2 || true)"
  PROVIDER=vllm
  PROVIDER_NAME="vLLM"
  BASE_URL="http://127.0.0.1:$PORT/v1"

# ============================ Ollama ============================
else
  if ! command -v ollama >/dev/null 2>&1; then
    step ollama_install
    curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1
  fi
  export OLLAMA_HOST="127.0.0.1:$PORT"

  start_ollama() {
    OLLAMA_CONTEXT_LENGTH="$CTX" OLLAMA_FLASH_ATTENTION=1 OLLAMA_KEEP_ALIVE=-1 \
    OLLAMA_LOAD_TIMEOUT=20m OLLAMA_KV_CACHE_TYPE="${KV_TYPE:-q8_0}" \
    OLLAMA_NUM_PARALLEL="${PARALLEL:-1}" OLLAMA_HOST="127.0.0.1:$PORT" \
      nohup ollama serve >/var/log/ollama.log 2>&1 &
    for _ in $(seq 1 30); do
      curl -sf "http://127.0.0.1:$PORT/api/version" >/dev/null && return 0
      sleep 1
    done
    fail ollama_fail; tail -20 /var/log/ollama.log; return 1
  }

  # Restart on config change
  WANT="model=$MODEL ctx=$CTX kv=${KV_TYPE:-q8_0} par=${PARALLEL:-1}"
  if ! curl -sf "http://127.0.0.1:$PORT/api/version" >/dev/null; then
    pkill -f 'vllm serve' 2>/dev/null || true
    step ollama_start
    start_ollama
  elif [ "$WANT" != "$(cat /root/.codex/server_env 2>/dev/null || true)" ]; then
    step ollama_restart
    pkill -x ollama || true; sleep 2; start_ollama
  fi
  echo "$WANT" > /root/.codex/server_env

  step pull
  # Output is piped, so ollama's live progress bar would never show; print a line every 10%
  pull_model() {
    local pid last=-10 cur pct
    ollama pull "$MODEL" >/var/log/ollama_pull.log 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      sleep 5
      cur="$(tr '\r' '\n' < /var/log/ollama_pull.log 2>/dev/null \
             | grep -aoE '[0-9]+% .*[0-9.]+ [KMG]B/ *[0-9.]+ [KMG]B' | tail -1 || true)"
      pct="${cur%%%*}"
      if [ -n "$pct" ] && [ "$pct" -ge $(( last + 10 )) ] 2>/dev/null; then
        echo "    $(echo "$cur" | sed -E 's/▕[^▏]*▏ *//; s/  +/ /g')"
        last="$pct"
      fi
    done
    wait "$pid"
  }
  PULL_OK=0
  for attempt in 1 2 3 4; do
    if pull_model; then PULL_OK=1; break; fi
    warn pull_retry "$attempt"; tail -3 /var/log/ollama_pull.log; sleep 15
  done
  [ "$PULL_OK" = 1 ] || { fail pull_fail; exit 1; }

  # Patch the embedded chat template
  PATCHED="$(python3 - "$MODEL" <<'PY'
import re, subprocess, sys
mf = subprocess.run(["ollama", "show", "--modelfile", sys.argv[1]],
                    capture_output=True, text=True).stdout
m = re.search(r"^FROM (/.*blobs/sha256-\S+)", mf, re.M)
if not m:
    print("noblob"); raise SystemExit
OLD = b"{{- raise_exception('System message must be at the beginning.') }}"
CORE = b"{{- '<|im_start|>system\\n' + content + '<|im_end|>\\n'"
NEW = CORE + b" " * (len(OLD) - len(CORE) - 3) + b" }}"
with open(m.group(1), "r+b") as f:
    head = f.read(16 * 1024 * 1024)
    if OLD in head:
        f.seek(head.index(OLD)); f.write(NEW); print("patched")
    elif CORE in head:
        print("already")
    else:
        print("none")
PY
)"
  if [ "$PATCHED" = "patched" ]; then
    step tpl_patched
    pkill -x ollama || true; sleep 2; start_ollama
  fi

  cat > /root/Modelfile <<EOF
FROM $MODEL
PARAMETER num_ctx $CTX
PARAMETER temperature $TEMPERATURE
PARAMETER top_p $TOP_P
PARAMETER top_k $TOP_K
PARAMETER repeat_penalty $REP_PENALTY
EOF
  step configure
  ollama create "$ALIAS" -f /root/Modelfile >/dev/null 2>&1
  ENGINE_VER="Ollama $(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
  PROVIDER=ollama-local
  PROVIDER_NAME="Ollama"
  BASE_URL="http://127.0.0.1:$PORT/v1/"
fi

# ============================ Agent ============================
if [ "$AGENT" = codex ]; then
  if ! command -v codex >/dev/null 2>&1; then
    step codex_install
    TMP="$(mktemp -d)"
    curl -fsSL -o "$TMP/codex.tar.gz" \
      https://github.com/openai/codex/releases/latest/download/codex-x86_64-unknown-linux-musl.tar.gz
    tar xzf "$TMP/codex.tar.gz" -C "$TMP"
    BIN="$(find "$TMP" -maxdepth 1 -type f -name 'codex*' ! -name '*.tar.gz' | head -1)"
    install -m 755 "$BIN" /usr/local/bin/codex
    rm -rf "$TMP"
  fi
  mkdir -p ~/.codex
  cat > ~/.codex/config.toml <<CODEXEOF
model = "$ALIAS"
model_provider = "$PROVIDER"
model_context_window = $CTX
model_max_output_tokens = $MAXOUT
model_auto_compact_token_limit = $(( CTX * 3 / 4 ))

[model_providers.$PROVIDER]
name = "$PROVIDER_NAME"
base_url = "$BASE_URL"
wire_api = "responses"
CODEXEOF

elif [ "$AGENT" = omp ]; then
  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v omp >/dev/null 2>&1; then
    step omp_install
    curl -fsSL https://omp.sh/install 2>/dev/null | sh >/dev/null 2>&1
  fi

  mkdir -p "$HOME/.omp/agent"
  cat > "$HOME/.omp/agent/models.yml" <<OMPMODELS
providers:
  local:
    baseUrl: $BASE_URL
    apiKey: local
    api: openai-completions
    models:
      - id: $ALIAS
        name: $MODEL
        api: openai-completions
        reasoning: true
        input: [text]
        contextWindow: $CTX
        maxTokens: $MAXOUT
        cost:
          input: 0
          output: 0
          cacheRead: 0
          cacheWrite: 0
OMPMODELS
  cat > "$HOME/.omp/agent/config.yml" <<OMPCONFIG
modelRoles:
  default: local/$ALIAS
  slow: local/$ALIAS
  tiny: local/$ALIAS
  plan: local/$ALIAS
modelProviderOrder:
  - local
setupVersion: 2
defaultThinkingLevel: auto
OMPCONFIG

else
  export PATH="$HOME/.opencode/bin:$HOME/.bun/bin:$PATH"
  if ! command -v opencode >/dev/null 2>&1; then
    step oc_install
    curl -fsSL https://opencode.ai/install 2>/dev/null | bash >/dev/null 2>&1
  fi

  if [ "${OMO:-1}" = 1 ] && ! grep -q oh-my-openagent "$HOME/.config/opencode/opencode.json" 2>/dev/null; then
    step omo_install
    command -v bun >/dev/null 2>&1 || curl -fsSL https://bun.sh/install 2>/dev/null | bash >/dev/null 2>&1
    export PATH="$HOME/.bun/bin:$PATH"
    OMO_DISABLE_POSTHOG=1 bunx oh-my-openagent install --no-tui \
      --platform=opencode --claude=no --gemini=no --copilot=no \
      >/var/log/omo_install.log 2>&1 \
      || warn omo_fail
  fi

  # Pin omo agents to the local model
  if [ "${OMO:-1}" = 1 ]; then
    python3 - "$ALIAS" <<'OMOEOF'
import json, os, sys

model = "local/" + sys.argv[1]
AGENTS = ["sisyphus", "hephaestus", "prometheus", "oracle", "librarian", "explore",
          "multimodal-looker", "metis", "momus", "atlas", "sisyphus-junior"]
CATEGORIES = ["visual-engineering", "ultrabrain", "deep", "artistry", "quick",
              "unspecified-low", "unspecified-high", "writing"]
cfg = {
    "$schema": "https://raw.githubusercontent.com/code-yeongyu/oh-my-openagent/dev/assets/omo.schema.json",
    "[opencode]": {
        "agents": {a: {"model": model} for a in AGENTS},
        "categories": {c: {"model": model} for c in CATEGORIES},
    },
}
for path in ("~/.omo/omo.jsonc", "~/.config/opencode/oh-my-openagent.json"):
    path = os.path.expanduser(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
OMOEOF
  fi

  # Disable TUI mouse capture
  python3 - <<'TUIEOF'
import json, os

path = os.path.expanduser("~/.config/opencode/tui.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    cfg = json.load(open(path))
except Exception:
    cfg = {}
cfg["mouse"] = False
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
TUIEOF

  # opencode config
  mkdir -p "$HOME/.config/opencode"
  python3 - "$ALIAS" "$BASE_URL" "$CTX" "$MAXOUT" "${OMO:-1}" <<'OCEOF'
import json, os, sys

alias, base = sys.argv[1], sys.argv[2].rstrip("/")
ctx, maxout, omo = int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
path = os.path.expanduser("~/.config/opencode/opencode.json")
try:
    cfg = json.load(open(path))
except Exception:
    cfg = {}
cfg["$schema"] = "https://opencode.ai/config.json"
cfg.setdefault("provider", {})["local"] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Local",
    "options": {"baseURL": base, "apiKey": "dummy"},
    "models": {alias: {"name": alias,
                       "limit": {"context": ctx, "output": maxout}}},
}
cfg["model"] = "local/" + alias
cfg["permission"] = "allow"
if omo == "1":
    plugins = cfg.get("plugin") or []
    if not any(str(x).startswith("oh-my-openagent") for x in plugins):
        plugins.append("oh-my-openagent@latest")
    cfg["plugin"] = plugins
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
OCEOF
fi

if ! git -C /content rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  step workspace
  git config --global user.email "codex@colab.local"
  git config --global user.name  "Colab Codex"
  git config --global init.defaultBranch main
  git -C /content init -q
  printf 'drive/\nsample_data/\n.config/\n' > /content/.gitignore
  git -C /content add -A >/dev/null 2>&1 || true
  git -C /content commit -qm "init" >/dev/null 2>&1 || true
fi

# ---- herdr ----
if [ "${HERDR:-1}" = 1 ]; then
  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v herdr >/dev/null 2>&1; then
    step herdr_install
    curl -fsSL https://herdr.dev/install.sh 2>/dev/null | sh >/dev/null 2>&1 || true
  fi

  if command -v herdr >/dev/null 2>&1; then
    if [ "$AGENT" = codex ]; then
      printf '#!/usr/bin/env bash\nunset LD_LIBRARY_PATH\nexec codex -s workspace-write\n' > /usr/local/bin/agent-start
    elif [ "$AGENT" = omp ]; then
      printf '#!/usr/bin/env bash\nunset LD_LIBRARY_PATH\nexport PATH="$HOME/.local/bin:$PATH"\nexec omp\n' > /usr/local/bin/agent-start
    else
      printf '#!/usr/bin/env bash\nunset LD_LIBRARY_PATH\nexport PATH="$HOME/.opencode/bin:$HOME/.bun/bin:$PATH"\nexport OMO_DISABLE_POSTHOG=1\nexec opencode\n' > /usr/local/bin/agent-start
    fi
    chmod +x /usr/local/bin/agent-start

    if ! herdr status server 2>/dev/null | grep -q '^status: running'; then
      step herdr_start
      nohup herdr server >/var/log/herdr.log 2>&1 &
      sleep 3
    fi

    if ! herdr workspace list 2>/dev/null | grep -q '"workspace_id"'; then
      step herdr_ws
      PANE="$(herdr workspace create --cwd /content --label colab 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])' 2>/dev/null || true)"
      [ -n "${PANE:-}" ] && herdr pane run "$PANE" agent-start >/dev/null 2>&1 || true
    fi
  else
    warn herdr_fail
  fi
fi

# ---- Smoke test ----
step smoke
SMOKE="$(python3 - "$ALIAS" "$PORT" <<'PY' || true
import json, sys, urllib.error, urllib.request
alias, port = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/v1/chat/completions",
    data=json.dumps({
        "model": alias, "stream": False,
        "messages": [{"role": "user", "content": "List the files in the current directory using the tool."}],
        "tools": [{"type": "function", "function": {
            "name": "list_files", "description": "List files in a directory",
            "parameters": {"type": "object",
                           "properties": {"path": {"type": "string"}},
                           "required": ["path"]}}}],
    }).encode(), headers={"Content-Type": "application/json"})
try:
    print(urllib.request.urlopen(req, timeout=900).read().decode())
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}: {e.read().decode()[:300]}")
except Exception as e:
    print(f"{type(e).__name__}: {e}")
PY
)"
if echo "$SMOKE" | grep -q '"tool_calls"'; then
  ok smoke_ok
else
  fail smoke_fail
  echo "$SMOKE" | head -c 300; echo
fi

# Single-stream decode speed from a short bounded completion
step speed
TPS="$(python3 - "$ALIAS" "$PORT" <<'PY' 2>/dev/null || true
import json, sys, time, urllib.request
alias, port = sys.argv[1], sys.argv[2]
body = {"model": alias, "stream": False, "max_tokens": 96,
        "messages": [{"role": "user", "content": "Write a short paragraph about the sea."}]}
req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                             data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json"})
# Warm-up so a cold model load (Ollama) does not count as decode time
warm = dict(body, max_tokens=1)
urllib.request.urlopen(urllib.request.Request(req.full_url, data=json.dumps(warm).encode(),
                       headers={"Content-Type": "application/json"}), timeout=600).read()
t = time.time()
r = json.loads(urllib.request.urlopen(req, timeout=600).read())
dt = time.time() - t
n = r["usage"]["completion_tokens"]
if n and dt > 0:
    print(f"{n / dt:.1f}")
PY
)"
if [ -n "$TPS" ]; then ok speed_ok "$TPS"; else fail speed_fail; fi

# Runtime stats, read by the local scripts
{
  echo "backend=$BACKEND"
  echo "agent=$AGENT"
  echo "omo=${OMO:-1}"
  echo "herdr=${HERDR:-1}"
  echo "model=$MODEL"
  echo "alias=$ALIAS"
  echo "ctx=$CTX"
  echo "maxout=$MAXOUT"
  echo "temp=$TEMPERATURE"
  echo "top_p=$TOP_P"
  echo "top_k=$TOP_K"
  echo "rep=$REP_PENALTY"
  if [ "$BACKEND" = vllm ]; then
    echo "parallel=$MAX_SEQS"
    echo "quant=$QUANT"
    echo "think=$THINKING"
    echo "reasoning=$REASONING"
    echo "spec=$SPEC_TOKENS"
    echo "kv_tokens=$KV_TOKENS"
    echo "kv_conc=$KV_CONC"
  else
    echo "parallel=${PARALLEL:-1}"
  fi
  echo "engine=$ENGINE_VER"
  echo "gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | sed 's/^NVIDIA //')"
  echo "tps=$TPS"
  echo "start_secs=$START_SECS"
  echo "deploy_secs=$(( $(date +%s) - DEPLOY_T0 ))"
  echo "mem=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | tr ',' '/')"
} > /root/.codex/runtime_stats 2>/dev/null || true

# Live status reporter: a loop on the VM that rewrites /root/.codex/status every
# 10 s (uptime, GPU, load, vLLM request and token counters, tunnel/proxy/herdr
# state). config.sh --list reads it. Restarted on every deploy.
cat > /root/.codex/statusd.sh <<'STATUSD_EOF'
#!/usr/bin/env bash
PORT="${PORT:-11434}"
OUT=/root/.codex/status
export PATH="$HOME/.local/bin:$PATH"
prev_ts=""; prev_gen=""; prev_done=""; last_req=""
while :; do
  now=$(date +%s)
  m="$(curl -s -m 3 "http://127.0.0.1:$PORT/metrics" 2>/dev/null \
       | grep -E '^vllm:(num_requests_running|num_requests_waiting|kv_cache_usage_perc|prompt_tokens_total|generation_tokens_total|request_success_total)[{ ]')"
  # sum <metric>: total over all label sets
  sum() { echo "$m" | awk -v k="vllm:$1" '{ n=$1; sub(/\{.*/, "", n); if (n == k) s+=$NF } END { printf "%.0f", s }'; }
  if curl -sf -m 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then health=ok; else health=down; fi
  pid=$(pgrep -f "vllm serve|ollama serve" | head -1)
  server_up=""; [ -n "$pid" ] && server_up=$(ps -o etimes= -p "$pid" | tr -d ' ')
  gpu="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
  IFS=, read -r gpu_util gpu_mem_used gpu_mem_total gpu_temp gpu_power <<< "$gpu"
  gpu_power="${gpu_power%%.*}"
  read -r ram_used ram_total <<< "$(free -m | awk '/Mem:/ { printf "%.1f %.0f", $3 / 1024, $2 / 1024 }')"
  disk_free="$(df -BG /root | awk 'NR == 2 { print $4 }')"
  load1="$(cut -d' ' -f1 /proc/loadavg)"
  vm_up="$(cut -d. -f1 /proc/uptime)"
  if pgrep -x cloudflared >/dev/null 2>&1; then tunnel=ok; else tunnel=down; fi
  if pgrep -f auth_proxy.py >/dev/null 2>&1; then proxy=ok; else proxy=down; fi
  herdr_state=""
  if command -v herdr >/dev/null 2>&1; then
    if herdr status server 2>/dev/null | grep -q '^status: running'; then herdr_state=running; else herdr_state=stopped; fi
  fi
  reqs_running=""; reqs_waiting=""; reqs_done=""; reqs_err=""; kv_usage=""; prompt_tokens=""; gen_tokens=""; gen_rate=""
  if [ -n "$m" ]; then
    reqs_running=$(sum num_requests_running); reqs_waiting=$(sum num_requests_waiting)
    reqs_done=$(sum request_success_total)
    reqs_err=$(echo "$m" | awk '/^vllm:request_success_total\{.*finished_reason="(error|abort)"/ { s+=$NF } END { printf "%.0f", s }')
    kv_usage=$(echo "$m" | awk '/^vllm:kv_cache_usage_perc/ { v=$NF } END { printf "%.1f", v * 100 }')
    prompt_tokens=$(sum prompt_tokens_total); gen_tokens=$(sum generation_tokens_total)
    if [ -n "$prev_ts" ] && [ "$now" -gt "$prev_ts" ]; then
      gen_rate=$(( (gen_tokens - prev_gen) / (now - prev_ts) ))
      if [ "$gen_tokens" != "$prev_gen" ] || [ "$reqs_done" != "$prev_done" ]; then last_req=$now; fi
    fi
    prev_ts=$now; prev_gen=$gen_tokens; prev_done=$reqs_done
  fi
  last_req_ago=""; [ -n "$last_req" ] && last_req_ago=$(( now - last_req ))
  {
    echo "ts=$now"; echo "vm_up=$vm_up"; echo "server_up=$server_up"; echo "health=$health"
    echo "gpu_util=$gpu_util"; echo "gpu_mem_used=$gpu_mem_used"; echo "gpu_mem_total=$gpu_mem_total"
    echo "gpu_temp=$gpu_temp"; echo "gpu_power=$gpu_power"
    echo "load1=$load1"; echo "cpus=$(nproc)"; echo "ram_used=$ram_used"; echo "ram_total=$ram_total"; echo "disk_free=$disk_free"
    echo "reqs_running=$reqs_running"; echo "reqs_waiting=$reqs_waiting"; echo "reqs_done=$reqs_done"; echo "reqs_err=$reqs_err"
    echo "kv_usage=$kv_usage"; echo "prompt_tokens=$prompt_tokens"; echo "gen_tokens=$gen_tokens"; echo "gen_rate=$gen_rate"
    echo "last_req_ago=$last_req_ago"
    echo "tunnel=$tunnel"; echo "proxy=$proxy"; echo "herdr_state=$herdr_state"
  } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
  sleep 10
done
STATUSD_EOF
pkill -f /root/.codex/statusd.sh 2>/dev/null || true
PORT="$PORT" setsid nohup bash /root/.codex/statusd.sh >/var/log/statusd.log 2>&1 < /dev/null &
