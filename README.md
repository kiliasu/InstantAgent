# InstantAgent

[简体中文](README.zh-CN.md)

Run a local LLM on a Colab GPU and attach a terminal coding agent
(opencode / oh my pi / codex), or expose it as an authenticated API
through a Cloudflare tunnel.

Defaults: vLLM, `OBLITERATUS/Qwen3.8-27B-OBLITERATED`, opencode + oh-my-openagent.

## Requirements

- Linux or macOS, OpenSSH
- Colab CLI, main branch: `uv tool install --force git+https://github.com/googlecolab/google-colab-cli`
- `colab auth` completed

## Usage

If the scripts are not executable, run `chmod +x start.sh config.sh`.

```bash
./start.sh                            # interactive
./start.sh --resume                   # reattach to the running session
./start.sh a100hm                     # skip the GPU question (h100|g4|a100hm|a100)
./start.sh a100hm --model=hemmingway  # pick a model, see Models
./start.sh a100hm --expose            # also expose a public API
./start.sh a100hm --setup-only        # deploy only, don't attach
./start.sh a100hm --omo               # opencode + oh-my-openagent (default)
./start.sh a100hm --omp               # oh my pi
./start.sh a100hm --codex             # codex
./start.sh a100hm --opencode          # plain opencode
./start.sh a100hm --ollama            # ollama backend (default vllm)
./start.sh a100hm --no-herdr          # run the agent without herdr
./start.sh --zh                       # Chinese UI

./config.sh                           # interactive: status / stop / keep-alive
./config.sh --list                    # status, including API address and token
./config.sh --all                     # stop all sessions
./config.sh --keepalive               # restart the keep-alive loop
```

An interactive run asks for the language, GPU, backend, model, mode (agent, API or both), agent
and an options preset. A question already answered by a flag or env var is skipped, so a fully
flagged run asks nothing. The language you pick is remembered, so `config.sh` answers in it too.

The GPUs are H100 (80 GB), G4 (96 GB), A100 High-RAM (80 GB) and A100 (40 GB). If the requested
GPU is unavailable: H100 → G4 → A100 High-RAM; G4 → A100 High-RAM.

The agent runs inside [herdr](https://herdr.dev), so the session survives disconnects; `--resume`
reattaches. Add other flags to change the running session, for example
`./start.sh --resume --model=hemmingway`; everything else stays as it was.

The API is OpenAI-compatible, takes `Authorization: Bearer <token>`, and serves the model as
`local-model`. The address, the token and a ready-to-paste curl command are shown after every
deploy and by `./config.sh --list`.

Stop the session with `./config.sh` when done, or it keeps billing.

## Models

| `--model=` | vLLM | Ollama |
|---|---|---|
| `obliterated` (default) | `OBLITERATUS/Qwen3.8-27B-OBLITERATED`, BF16, 55 GB | `hf.co/OBLITERATUS/Qwen3.8-27B-OBLITERATED:Q8_0`, 29 GB |
| `obliterated-q8` | same weights, FP8 at load time, about 31 GB VRAM | same as `obliterated` |
| `obliterated-q6` | none | `hf.co/OBLITERATUS/Qwen3.8-27B-OBLITERATED:Q6_K`, 22 GB |
| `obliterated-q4` | `quocbao747/Qwen3.8-27B-OBLITERATED-W4A16-24GB`, GPTQ 4-bit, 20 GB | `hf.co/OBLITERATUS/Qwen3.8-27B-OBLITERATED:Q4_K_M`, 17 GB |
| `hemmingway` | `HemmingwayAI/Hemmingway-1`, BF16, 55 GB | `hf.co/mradermacher/Hemmingway-1-GGUF:Q8_0`, 29 GB |

`obliterated` is Qwen3.8-27B with refusals removed. The quantized presets trade a little quality
for speed: smaller weights decode faster and leave more VRAM for long contexts. The 4-bit vLLM
build is a community GPTQ quant (MMLU 81.6 vs 82.3 for BF16, per its card).

`hemmingway` is Qwen3.8-27B tuned for everyday writing, not coding. CC BY-NC 4.0,
non-commercial only.

`--model` also takes an HF repo id (vLLM) or an Ollama ref directly. For tool calling and
thinking to work, it should be a Qwen3.6 / Qwen3.8 family model.

Ollama works for the API, but its GGUF builds cannot call tools, so the agents need vLLM.

Switching models on a running session restarts the backend; the weights stay cached on the VM.

### Sampling

Each model has its own default sampling. A request that sets its own values takes precedence.

| Model | temperature | top_p | top_k | repetition penalty |
|---|---|---|---|---|
| `obliterated*` | 0.2 | 0.95 | 20 | 1.15 |
| `hemmingway`, custom refs | 1.0 | 0.95 | 20 | 1.0 |

The defaults follow the model cards: OBLITERATED's settings for agent use, and the Qwen3.8
thinking-mode settings for Hemmingway-1. Change them with `TEMPERATURE` / `TOP_P` / `TOP_K` /
`REPETITION_PENALTY`.

## Options

An interactive run ends with an options preset:

| Preset | Thinking | Effort | Speculative decoding | Context |
|---|---|---|---|---|
| Default | on | xhigh | off | 262144 |
| Fast writing (recommended for `hemmingway`) | on | low | MTP x2 | 262144 |
| No thinking | off | - | MTP x2 | 262144 |
| Custom | asked | asked | off / x2 / x3 | 262144 / 131072 / 65536 / 32768 |

MTP speculative decoding makes generation faster. On a G4 with Hemmingway-1, a single stream ran
at 26 tok/s without it, 47 tok/s with x2 and 60 tok/s with x3. With Ollama the preset only covers
the context length.

To set these without the questions, use `THINKING`, `REASONING`, `SPEC_TOKENS` and `CONTEXT`.
A single API request can override thinking with
`"chat_template_kwargs": {"enable_thinking": false, "reasoning_effort": "low"}`. Hemmingway-1 is
tuned to think, so with thinking off it still opens a think block now and then.

## Status and keep-alive

Every deploy ends with a summary: hardware, settings, a measured single-stream speed and the API
address. `./config.sh --list` shows it again with live numbers: uptime, GPU load and memory, and
with vLLM the request queue, generation rate and token totals. It also shows whether the tunnel,
the auth proxy and herdr are up.

Colab shuts a session down after about an hour without kernel activity, and SSH traffic does not
count. `start.sh` therefore starts a keep-alive loop on your machine that pings the session every
`KA_INTERVAL` seconds until the session is gone. The loop only runs while your machine is awake;
after a reboot, start it again with `./config.sh --keepalive`.

Every deploy is logged to `~/.cache/instantagent/`, and the last 20 logs are kept. If vLLM fails
to start, the root cause is printed first; the full log is `/var/log/vllm.log` on the VM.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `MODEL` | obliterated | same as `--model` |
| `BACKEND` | vllm | `vllm` / `ollama` |
| `AGENT` | opencode | `opencode` / `omp` / `codex` |
| `OMO` | 1 | add oh-my-openagent to opencode |
| `HERDR` | 1 | run the agent inside herdr |
| `UI_LANG` | en | `en` / `zh` |
| `CONTEXT` | 262144 | context length |
| `MAX_OUTPUT` | 16384 | max tokens per reply |
| `TEMPERATURE` / `TOP_P` / `TOP_K` / `REPETITION_PENALTY` | per model | sampling, see Models |
| `THINKING` | 1 | vLLM only: `0` answers without a thinking block |
| `REASONING` | xhigh | vLLM only: thinking effort, `low` / `medium` / `xhigh` |
| `SPEC_TOKENS` | 0 | vLLM only: MTP speculative decoding, draft tokens per step |
| `MAX_SEQS` | 64 | vLLM only: max concurrent sequences |
| `KV_TYPE` | q8_0 | ollama only: KV cache quant |
| `PARALLEL` | 1 | ollama only: parallel slots |
| `KA_INTERVAL` | 300 | seconds between keep-alive pings |

`SPEC_TOKENS` needs a model with an MTP head. The vLLM presets all have one; without it the
option is switched off with a warning. `MAX_SEQS` is low on purpose: at 262k context only a few
hundred sequences fit, and vLLM's own default of 1024 fails to start.

## Files

| File | Role |
|---|---|
| `start.sh` | entry point |
| `config.sh` | status, stop sessions, keep-alive |
| `_common.sh` | shared functions and UI strings |
| `_remote_setup.sh` | runs on the VM: backend + agent |
| `_expose.sh` | runs on the VM: auth proxy + tunnel |

## License

MIT
