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
./start.sh                      # interactive
./start.sh --resume             # resume an existing session
./start.sh a100hm               # non-interactive (h100|g4|a100hm|a100)
./start.sh a100hm --expose      # also expose a public API
./start.sh a100hm --setup-only  # deploy only, don't attach
./start.sh a100hm --omo         # opencode + oh-my-openagent (default)
./start.sh a100hm --omp         # oh my pi
./start.sh a100hm --codex       # codex
./start.sh a100hm --opencode    # plain opencode
./start.sh a100hm --ollama      # ollama backend (default vllm)
./start.sh a100hm --no-herdr    # run the agent without herdr
./start.sh --zh                 # Chinese UI

./config.sh                     # interactive: status / stop
./config.sh --list              # status, including API address and token
./config.sh --all               # stop all sessions
```

If the requested GPU is unavailable: H100 → G4 → A100 High-RAM; G4 → A100 High-RAM.

The agent runs inside [herdr](https://herdr.dev), so the session survives disconnects; `--resume` reattaches.

The API is OpenAI-compatible, takes `Authorization: Bearer <token>`, and serves the model as `local-model`.

Stop the session with `./config.sh` when done, or it keeps billing.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `CONTEXT` | 262144 | context length |
| `MAX_OUTPUT` | 16384 | max tokens per reply |
| `TEMPERATURE` / `TOP_P` / `TOP_K` | 1.0 / 0.95 / 20 | sampling |
| `BACKEND` | vllm | `vllm` / `ollama` |
| `AGENT` | opencode | `opencode` / `omp` / `codex` |
| `OMO` | 1 | add oh-my-openagent to opencode |
| `HERDR` | 1 | run the agent inside herdr |
| `UI_LANG` | en | `en` / `zh` |
| `KV_TYPE` | q8_0 | ollama only: KV cache quant |
| `PARALLEL` | 1 | ollama only: parallel slots |

## Files

| File | Role |
|---|---|
| `start.sh` | entry point |
| `config.sh` | status, stop sessions |
| `_common.sh` | shared functions and UI strings |
| `_remote_setup.sh` | runs on the VM: backend + agent |
| `_expose.sh` | runs on the VM: auth proxy + tunnel |

## License

MIT
