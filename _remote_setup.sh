#!/usr/bin/env bash
# Runs on the Colab VM: deploy the inference backend and agent
#
# Env:
#   MODEL_REF     required. HF repo id for vllm, ollama model ref for ollama
#   BACKEND       vllm (default) | ollama
#   AGENT         opencode (default) | omp | codex
#   OMO           1 (default, opencode + oh-my-openagent) | 0
#   HERDR         1 (default, agent runs inside herdr) | 0
#   CONTEXT       context length, default 262144
#   MAX_OUTPUT    max tokens per reply, default 16384
#   TEMPERATURE / TOP_P / TOP_K   sampling
#   KV_TYPE       ollama only: KV cache quant, default q8_0
#   PARALLEL      ollama only: parallel slots, default 1
#   UI_LANG       en (default) | zh
set -euo pipefail

MODEL="${MODEL_REF:?MODEL_REF is required}"
BACKEND="${BACKEND:-vllm}"
AGENT="${AGENT:-opencode}"
CTX="${CONTEXT:-262144}"
MAXOUT="${MAX_OUTPUT:-16384}"
ALIAS="local-model"
PORT=11434
UI_LANG="${UI_LANG:-en}"
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
  esac
  if [ "$UI_LANG" = zh ]; then printf "$zh\n" "$@"; else printf "$en\n" "$@"; fi
}
step() { echo "  · $(t "$@")"; }
ok()   { echo "  ✔ $(t "$@")"; }
fail() { echo "  ✖ $(t "$@")"; }
warn() { echo "  ! $(t "$@")"; }

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

  # Chat template
  TPL=/root/.codex/chat_template.jinja
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

  # Restart on config change
  TPL_SIG=none
  [ -s "$TPL" ] && TPL_SIG="$(md5sum "$TPL" | cut -d" " -f1)"
  WANT="model=$HF_REPO ctx=$CTX alias=$ALIAS tpl=$TPL_SIG"
  if ! server_up || [ "$WANT" != "$(cat /root/.codex/server_env 2>/dev/null || true)" ]; then
    pkill -f 'vllm serve' 2>/dev/null || true
    pkill -x ollama 2>/dev/null || true
    sleep 2
    step vllm_start
    CHAT_ARG=""
    [ -s "$TPL" ] && CHAT_ARG="--chat-template $TPL"
    # shellcheck disable=SC2086
    nohup "$VENV/bin/vllm" serve "$MODEL_DIR" \
      --served-model-name "$ALIAS" \
      --host 127.0.0.1 --port "$PORT" \
      --max-model-len "$CTX" \
      --gpu-memory-utilization 0.92 \
      --kv-cache-dtype fp8 \
      --enable-auto-tool-choice \
      --tool-call-parser qwen3_coder \
      --reasoning-parser qwen3 \
      $CHAT_ARG \
      >/var/log/vllm.log 2>&1 &
    echo "$WANT" > /root/.codex/server_env
    for _ in $(seq 1 240); do
      server_up && break
      if ! pgrep -f 'vllm serve' >/dev/null 2>&1; then
        fail vllm_fail; tail -20 /var/log/vllm.log; exit 1
      fi
      sleep 5
    done
    server_up || { fail vllm_timeout; tail -5 /var/log/vllm.log; exit 1; }
  fi
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
  WANT="ctx=$CTX kv=${KV_TYPE:-q8_0} par=${PARALLEL:-1}"
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
  PULL_OK=0
  for attempt in 1 2 3 4; do
    if ollama pull "$MODEL"; then PULL_OK=1; break; fi
    warn pull_retry "$attempt"; sleep 15
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
PARAMETER temperature ${TEMPERATURE:-1.0}
PARAMETER top_p ${TOP_P:-0.95}
PARAMETER top_k ${TOP_K:-20}
EOF
  step configure
  ollama create "$ALIAS" -f /root/Modelfile >/dev/null 2>&1
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
import json, sys, urllib.request
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
print(urllib.request.urlopen(req, timeout=900).read().decode())
PY
)"
if echo "$SMOKE" | grep -q '"tool_calls"'; then
  ok smoke_ok
else
  fail smoke_fail
  echo "$SMOKE" | head -c 300; echo
fi

# Runtime stats, read by the local scripts
{
  echo "backend=$BACKEND"
  echo "agent=$AGENT"
  echo "herdr=${HERDR:-1}"
  echo "model=$MODEL"
  echo "alias=$ALIAS"
  echo "ctx=$CTX"
  echo "maxout=$MAXOUT"
  if [ "$BACKEND" = vllm ]; then
    echo "parallel=auto"
  else
    echo "parallel=${PARALLEL:-1}"
  fi
  echo "mem=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | tr ',' '/')"
} > /root/.codex/runtime_stats 2>/dev/null || true
