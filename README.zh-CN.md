# InstantAgent

[English](README.md)

在 Colab GPU 上运行本地大模型，并接入终端编码 agent（opencode / oh my pi / codex），
或通过 Cloudflare 隧道将其暴露为带鉴权的 API。

默认：vLLM，`OBLITERATUS/Qwen3.8-27B-OBLITERATED`，opencode + oh-my-openagent。

## 环境要求

- Linux 或 macOS，OpenSSH
- Colab CLI，main 分支：`uv tool install --force git+https://github.com/googlecolab/google-colab-cli`
- 已完成 `colab auth`

## 用法

如果脚本没有执行权限，运行 `chmod +x start.sh config.sh`。

```bash
./start.sh                      # 交互式
./start.sh --resume             # 恢复已有会话
./start.sh a100hm               # 非交互式 (h100|g4|a100hm|a100)
./start.sh a100hm --expose      # 同时暴露公网 API
./start.sh a100hm --setup-only  # 只部署，不进入
./start.sh a100hm --omo         # opencode + oh-my-openagent（默认）
./start.sh a100hm --omp         # oh my pi
./start.sh a100hm --codex       # codex
./start.sh a100hm --opencode    # 纯 opencode
./start.sh a100hm --ollama      # ollama 后端（默认 vllm）
./start.sh a100hm --no-herdr    # 不经 herdr 直接运行 agent
./start.sh --zh                 # 中文界面

./config.sh                     # 交互式：状态 / 停止
./config.sh --list              # 状态，含 API 地址和 token
./config.sh --all               # 停止全部会话
```

所选 GPU 不可用时回落：H100 → G4 → A100 High-RAM；G4 → A100 High-RAM。

agent 运行在 [herdr](https://herdr.dev) 内，断线后会话保留；`--resume` 重新接入。

API 兼容 OpenAI 接口，使用 `Authorization: Bearer <token>` 鉴权，模型名为 `local-model`。

用完请通过 `./config.sh` 停止会话，否则会持续计费。

## 环境变量

| 变量 | 默认值 | 含义 |
|---|---|---|
| `CONTEXT` | 262144 | 上下文长度 |
| `MAX_OUTPUT` | 16384 | 单次回复最大 token 数 |
| `TEMPERATURE` / `TOP_P` / `TOP_K` | 1.0 / 0.95 / 20 | 采样参数 |
| `BACKEND` | vllm | `vllm` / `ollama` |
| `AGENT` | opencode | `opencode` / `omp` / `codex` |
| `OMO` | 1 | 为 opencode 加装 oh-my-openagent |
| `HERDR` | 1 | 在 herdr 内运行 agent |
| `UI_LANG` | en | `en` / `zh` |
| `KV_TYPE` | q8_0 | 仅 ollama：KV cache 量化类型 |
| `PARALLEL` | 1 | 仅 ollama：并发槽位数 |

## 文件

| 文件 | 作用 |
|---|---|
| `start.sh` | 入口 |
| `config.sh` | 查看状态、停止会话 |
| `_common.sh` | 共享函数与界面文案 |
| `_remote_setup.sh` | 在 VM 上运行：后端 + agent |
| `_expose.sh` | 在 VM 上运行：鉴权代理 + 隧道 |

## 许可证

MIT
