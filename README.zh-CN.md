# InstantAgent

[English](README.md)

在 Colab GPU 上运行本地大模型，并接入终端编码 agent（opencode / oh my pi / codex），或通过 Cloudflare 隧道将其暴露为带鉴权的 API。

默认：vLLM，`OBLITERATUS/Qwen3.8-27B-OBLITERATED`，opencode + oh-my-openagent。

## 环境要求

- Linux 或 macOS，OpenSSH
- Colab CLI，main 分支：`uv tool install --force git+https://github.com/googlecolab/google-colab-cli`
- 已完成 `colab auth`

## 用法

如果脚本没有执行权限，运行 `chmod +x start.sh config.sh`。

```bash
./start.sh                            # 交互式
./start.sh --resume                   # 重新接入正在运行的会话
./start.sh a100hm                     # 跳过 GPU 选择 (h100|g4|a100hm|a100)
./start.sh a100hm --model=hemmingway  # 指定模型，见「模型」
./start.sh a100hm --expose            # 同时暴露公网 API
./start.sh a100hm --setup-only        # 只部署，不进入
./start.sh a100hm --omo               # opencode + oh-my-openagent（默认）
./start.sh a100hm --omp               # oh my pi
./start.sh a100hm --codex             # codex
./start.sh a100hm --opencode          # 纯 opencode
./start.sh a100hm --ollama            # ollama 后端（默认 vllm）
./start.sh a100hm --no-herdr          # 不经 herdr 直接运行 agent
./start.sh --zh                       # 中文界面

./config.sh                           # 交互式：状态 / 停止 / 保活
./config.sh --list                    # 状态，含 API 地址和 token
./config.sh --all                     # 停止全部会话
./config.sh --keepalive               # 重新启动保活
```

交互式运行会依次询问语言、GPU、后端、模型、用途（Agent、API 或两者）、agent 和选项预设。参数或环境变量已经回答的问题会跳过，参数给全时不再提问。选过的语言会被记住，`config.sh` 也沿用。

可选 GPU：H100（80 GB）、G4（96 GB）、A100 High-RAM（80 GB）、A100（40 GB）。所选 GPU 不可用时回落：H100 → G4 → A100 High-RAM；G4 → A100 High-RAM。

agent 运行在 [herdr](https://herdr.dev) 内，断线后会话保留；`--resume` 重新接入。加上其他参数可以修改正在运行的会话，例如 `./start.sh --resume --model=hemmingway`，其余设置不变。

API 兼容 OpenAI 接口，使用 `Authorization: Bearer <token>` 鉴权，模型名为 `local-model`。部署完成后以及运行 `./config.sh --list` 时，都会给出地址、token 和一条可直接粘贴的 curl 命令。

用完请通过 `./config.sh` 停止会话，否则会持续计费。

## 模型

| `--model=` | vLLM | Ollama |
|---|---|---|
| `obliterated`（默认） | `OBLITERATUS/Qwen3.8-27B-OBLITERATED`，BF16，55 GB | `hf.co/OBLITERATUS/Qwen3.8-27B-OBLITERATED:Q8_0`，29 GB |
| `obliterated-q8` | 同一份权重，加载时量化为 FP8，显存约 31 GB | 同 `obliterated` |
| `obliterated-q6` | 无 | `hf.co/OBLITERATUS/Qwen3.8-27B-OBLITERATED:Q6_K`，22 GB |
| `obliterated-q4` | `quocbao747/Qwen3.8-27B-OBLITERATED-W4A16-24GB`，GPTQ 4-bit，20 GB | `hf.co/OBLITERATUS/Qwen3.8-27B-OBLITERATED:Q4_K_M`，17 GB |
| `hemmingway` | `HemmingwayAI/Hemmingway-1`，BF16，55 GB | `hf.co/mradermacher/Hemmingway-1-GGUF:Q8_0`，29 GB |

`obliterated` 是去除了拒答的 Qwen3.8-27B。量化版本用少量质量换速度：权重更小，解码更快，也给长上下文留出更多显存。vLLM 的 4-bit 版本是社区制作的 GPTQ 量化（据其模型卡，MMLU 为 81.6，BF16 为 82.3）。

`hemmingway` 是针对日常写作（而非编码）微调的 Qwen3.8-27B。许可为 CC BY-NC 4.0，仅限非商业用途。

`--model` 也可以直接填 HF 仓库 ID（vLLM）或 Ollama 模型引用。要让工具调用和思考正常工作，应使用 Qwen3.6 / Qwen3.8 系列的模型。

Ollama 可以提供 API，但它的 GGUF 版本不支持工具调用，所以 agent 需要用 vLLM。

在运行中的会话上切换模型会重启后端；已下载的权重保留在 VM 上。

### 采样

每个模型有各自的默认采样参数。请求里自带的参数优先。

| 模型 | temperature | top_p | top_k | 重复惩罚 |
|---|---|---|---|---|
| `obliterated*` | 0.2 | 0.95 | 20 | 1.15 |
| `hemmingway`、自定义模型 | 1.0 | 0.95 | 20 | 1.0 |

默认值取自模型卡：OBLITERATED 用面向 agent 的设置，Hemmingway-1 用 Qwen3.8 思考模式的设置。可用 `TEMPERATURE` / `TOP_P` / `TOP_K` / `REPETITION_PENALTY` 修改。

## 选项

交互式运行的最后一问是选项预设：

| 预设 | 思考 | 推理强度 | 投机解码 | 上下文 |
|---|---|---|---|---|
| 默认 | 开 | xhigh | 关 | 262144 |
| 快速写作（推荐用于 `hemmingway`） | 开 | low | MTP x2 | 262144 |
| 不思考 | 关 | - | MTP x2 | 262144 |
| 自定义 | 询问 | 询问 | 关 / x2 / x3 | 262144 / 131072 / 65536 / 32768 |

MTP 投机解码可以加快生成。在 G4 上用 Hemmingway-1 实测，单路速度关闭时为 26 tok/s，x2 时为 47 tok/s，x3 时为 60 tok/s。使用 Ollama 时，预设只包含上下文长度。

不想逐项回答时，可以用环境变量 `THINKING`、`REASONING`、`SPEC_TOKENS`、`CONTEXT` 直接设置。单个 API 请求也可以用 `"chat_template_kwargs": {"enable_thinking": false, "reasoning_effort": "low"}` 覆盖思考设置。Hemmingway-1 微调后习惯先思考，关掉思考后偶尔仍会自己开一段。

## 状态与保活

每次部署完成后会显示一份摘要：硬件、各项设置、实测单路速度和 API 地址。`./config.sh --list` 显示同样的摘要，另加实时数据：运行时长、GPU 利用率和显存；使用 vLLM 时还有请求队列、生成速率和 token 累计。隧道、鉴权代理和 herdr 是否在运行也会列出。

Colab 会在内核约一小时没有活动后关闭会话，SSH 流量不算活动。因此 `start.sh` 会在本机后台启动保活，每隔 `KA_INTERVAL` 秒 ping 一次会话，直到会话结束。保活只在本机没有休眠时工作；本机重启后，用 `./config.sh --keepalive` 重新启动。

每次部署的日志保存在 `~/.cache/instantagent/`，保留最近 20 份。vLLM 启动失败时会先打印根因；完整日志在 VM 上的 `/var/log/vllm.log`。

## 环境变量

| 变量 | 默认值 | 含义 |
|---|---|---|
| `MODEL` | obliterated | 同 `--model` |
| `BACKEND` | vllm | `vllm` / `ollama` |
| `AGENT` | opencode | `opencode` / `omp` / `codex` |
| `OMO` | 1 | 为 opencode 加装 oh-my-openagent |
| `HERDR` | 1 | 在 herdr 内运行 agent |
| `UI_LANG` | en | `en` / `zh` |
| `CONTEXT` | 262144 | 上下文长度 |
| `MAX_OUTPUT` | 16384 | 单次回复最大 token 数 |
| `TEMPERATURE` / `TOP_P` / `TOP_K` / `REPETITION_PENALTY` | 随模型 | 采样参数，见「模型」 |
| `THINKING` | 1 | 仅 vLLM：设为 `0` 时不带思考块直接回答 |
| `REASONING` | xhigh | 仅 vLLM：推理强度，`low` / `medium` / `xhigh` |
| `SPEC_TOKENS` | 0 | 仅 vLLM：MTP 投机解码，每步草拟的 token 数 |
| `MAX_SEQS` | 64 | 仅 vLLM：最大并发序列数 |
| `KV_TYPE` | q8_0 | 仅 ollama：KV cache 量化类型 |
| `PARALLEL` | 1 | 仅 ollama：并发槽位数 |
| `KA_INTERVAL` | 300 | 两次保活 ping 之间的秒数 |

`SPEC_TOKENS` 需要模型带有 MTP 头。vLLM 的预设模型都带；没有时会给出警告并关闭该选项。`MAX_SEQS` 默认只设 64：262k 上下文下只能容纳几百个序列，vLLM 自带的默认值 1024 会启动失败。

## 文件

| 文件 | 作用 |
|---|---|
| `start.sh` | 入口 |
| `config.sh` | 查看状态、停止会话、保活 |
| `_common.sh` | 共享函数与界面文案 |
| `_remote_setup.sh` | 在 VM 上运行：后端 + agent |
| `_expose.sh` | 在 VM 上运行：鉴权代理 + 隧道 |

## 许可证

MIT
