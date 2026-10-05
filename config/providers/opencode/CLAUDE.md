# OpenCode CLI Provider Configuration

This file contains OpenCode-specific instructions for Claude Octopus workflows.

## Provider Information

- **Provider**: OpenCode CLI (multi-provider router)
- **Emoji**: 🟤
- **API Key**: Varies by backend — OAuth for Google, API keys for OpenAI/Z.AI/MiniMax
- **CLI Command**: `opencode run`
- **Agent Types**: `opencode`, `opencode-fast`, `opencode-research`
- **Cost**: Variable — free for Google OAuth, pay-per-use for OpenAI API, depends on backend model

## Detection

- CLI: `command -v opencode`
- Auth file: `~/.local/share/opencode/auth.json`
- Validation: `timeout 3 opencode auth list` (non-blocking check)

Workflows silently skip OpenCode if the CLI is not installed or not authenticated. Diagnostic tools (`/octo:doctor`) will still report the provider status.

## Authentication Setup

### Option 1: Interactive Login (recommended)

```bash
opencode auth login
```

Authenticates via credential flow for supported backends (Google, OpenAI).

### Option 2: Environment Variables (per backend)

```bash
export GITHUB_TOKEN="ghp_..."           # GitHub Copilot + GitHub Models
export OPENROUTER_API_KEY="sk-or-..."   # OpenRouter (100+ models)
export Z_AI_API_KEY="..."               # Z.AI direct (GLM models)
export MINIMAX_API_KEY="..."            # MiniMax models
```

### Option 3: Combined (maximum backend coverage)

Run `opencode auth login` for OAuth backends, then set env vars for API-key backends.

## Multi-Provider Architecture

OpenCode routes to multiple backends via a single CLI using `-m provider/model` format.

| Prefix | Backend | Example Models |
|--------|---------|----------------|
| `google/` | Google AI | `gemini-2.5-flash`, `gemini-2.5-pro` |
| `openai/` | OpenAI | `gpt-5.4`, `gpt-5.4-mini` |
| `z-ai/` | Z.AI | `glm-5`, `glm-5.1` |
| `openrouter/` | OpenRouter | `deepseek/deepseek-r1`, `z-ai/glm-5` |
| `github-copilot/` | GitHub Copilot | `claude-opus-4.6`, `gpt-5.4` |
| `github-models/` | GitHub Models | `meta/llama-3.1-70b-instruct` |
| `minimax/` | MiniMax | (MiniMax catalog) |
| `opencode/` | OpenCode built-in | `gpt-5-nano` (free) |

The same model can be routed through different backends (e.g., `z-ai/glm-5` direct vs `openrouter/z-ai/glm-5` proxied) for cost, latency, or availability reasons.

Run `opencode models` for the full model catalog.

## Model Configuration

```bash
# Set default model for all OpenCode agent types
/octo:model-config opencode google/gemini-2.5-flash

# Set capability-specific models (dot syntax)
/octo:model-config opencode.fast google/gemini-2.5-flash
/octo:model-config opencode.research z-ai/glm-5.1
```

## Dispatch Pattern

```bash
opencode --pure run -m provider/model "<prompt>"   # OpenCode 1.x
opencode run -m provider/model "<prompt>"          # OpenCode 2.x
```

### The `--pure` flag (OpenCode 1.x vs 2.x)

OpenCode 1.x takes the global `--pure` flag, which skips the external-plugin
auto-title path that could hang `opencode run` (Issue #566). OpenCode 2.x
removed the flag and rejects it (`Unrecognized flag: --pure`).

At startup Octopus reads `opencode --help` once per run (bounded by
`OCTOPUS_BARE_PROBE_TIMEOUT`, default 5s, stdin closed) and passes `--pure`
only when the help declares it. If the probe fails (non-zero exit, no output or
timeout) Octopus keeps passing `--pure` and logs a warning.

`OCTOPUS_OPENCODE_PURE` skips the probe and decides directly. Values are case
insensitive: `1`, `true`, `yes`, `on` pass `--pure`; `0`, `false`, `no`, `off`
omit it. Any other value is ignored with a warning and the probe runs.

The probe is not skipped by `OCTOPUS_SKIP_PROVIDER_PROBES` (on by default in
remote sessions): it reads local help text only, and without it every dispatch
on OpenCode 2.x would fail. Set `OCTOPUS_OPENCODE_PURE` to avoid it.

Known limits: OpenCode 2.x runs requests through a background server by
default, so a client-side timeout may not stop work already running on that
server. The Issue #566 hang has not been reproduced on 2.x without `--pure`,
but it has not been proven absent either.

## Role Assignment

OpenCode serves as an independent multi-provider router:
- **Default** (`opencode`) — general-purpose tasks via configured default model
- **Fast iteration** (`opencode-fast`) — quick feedback via fast/budget model
- **Research** (`opencode-research`) — deep analysis via research-grade model

OpenCode is a standalone provider, not a replacement for Codex or Antigravity.

## Limitations

- Cost depends entirely on the backend model selected (free to premium)
- No direct model selection from orchestrate.sh — uses model-resolver pipeline
- Output is plain text (ANSI stripped by caller)
- Some backends require separate API keys beyond OAuth

## Timeout Configuration

Default timeout: 90 seconds. Configurable via `OCTOPUS_OPENCODE_TIMEOUT` env var.

## Error Handling

Common errors:
- `unauthorized`: Not authenticated — run `opencode auth login`
- `model not found`: Invalid provider/model — check `opencode models`
- `Timeout`: Response took too long — increase timeout or use a faster model
- `command not found`: CLI not installed — `npm install -g opencode-ai`

## Integration with Workflows

OpenCode is used in:
- **Discover Phase**: Research via `opencode-research` agent type
- **Develop Phase**: Code generation via default or fast agent types
- **Deliver Phase**: Fast review feedback via `opencode-fast` agent type
