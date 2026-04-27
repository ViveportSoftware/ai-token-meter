# AI Token Meter (ATM)

> A transparent reverse proxy that silently monitors every AI API call your team makes — token counts, costs, latency, and per-user budgets — without changing a single line of code.

[![GitHub release](https://img.shields.io/github/v/release/ViveportSoftware/ai-token-meter?style=flat-square)](https://github.com/ViveportSoftware/ai-token-meter/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

---

## How it works

```
Your AI Tool (Cursor / OpenCode / Aider / Continue)
        │  OPENAI_BASE_URL=http://localhost:40080
        ▼
  ┌─────────────────┐
  │  ATM  :40080    │──────────────────────► LLM Provider
  │  reverse proxy  │                       (OpenAI / Anthropic / …)
  └────────┬────────┘
           │ metrics
           ▼
     GET /metrics ◄── Prometheus ◄── Grafana
```

ATM sits between your AI tools and the LLM provider. It is **completely transparent** — just set `OPENAI_BASE_URL` and forget it. Tokens are counted, costs are calculated, and budgets are enforced automatically.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ViveportSoftware/ai-token-meter/main/scripts/install.sh | bash
```

The installer:
- Downloads the correct binary for your OS and architecture
- Installs to `~/.local/bin/atm`
- Writes a default config to `~/.config/atm/config.yaml`
- Sets `OPENAI_BASE_URL=http://localhost:40080` in your shell profile

Then reload your shell and start the daemon:

```bash
source ~/.zshrc   # or ~/.bashrc on Linux
atm &
```

Verify it is running:

```bash
curl http://localhost:40080/health
# → {"status":"ok"}
```

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ViveportSoftware/ai-token-meter/main/scripts/install.sh | bash -s -- --uninstall
```

---

## Configuration

Config lives at `~/.config/atm/config.yaml`. Edit it to match your setup:

```yaml
upstream_url: "https://api.openai.com"   # your LLM provider

budget:
  enabled: true
  daily_limit: 100000      # tokens per user per day  (0 = unlimited)
  monthly_limit: 2000000   # tokens per user per month (0 = unlimited)

rate_limit:
  enabled: true
  requests_per_minute: 60
  burst: 10
```

Restart `atm` after any config change.

### Full config reference

| Key | Default | Description |
|---|---|---|
| `listen_addr` | `:40080` | Proxy listen address |
| `upstream_url` | `https://api.openai.com` | LLM provider base URL |
| `budget.enabled` | `false` | Enforce per-user token budgets |
| `budget.daily_limit` | `0` | Daily token limit (0 = unlimited) |
| `budget.monthly_limit` | `0` | Monthly token limit (0 = unlimited) |
| `rate_limit.enabled` | `false` | Enforce per-user rate limits |
| `rate_limit.requests_per_minute` | `60` | Max requests per minute per user |
| `rate_limit.burst` | `10` | Burst allowance above the rate limit |
| `log_level` | `info` | `debug` / `info` / `warn` / `error` |

---

## Metrics

All metrics are exposed at `http://localhost:40080/metrics` in Prometheus format.

| Metric | Type | Labels |
|---|---|---|
| `atm_tokens_total` | Counter | `user_id`, `model`, `tool`, `type` (`input`\|`output`) |
| `atm_requests_total` | Counter | `user_id`, `model`, `tool`, `status` |
| `atm_request_duration_seconds` | Histogram | `model`, `tool` |

`tool` is auto-detected from the `User-Agent` header: `aider`, `opencode`, `cursor`, `continue`, or `unknown`.

### Example PromQL

```promql
# Token usage rate by model
sum by (model) (rate(atm_tokens_total[5m]))

# Estimated cost (gpt-4o example: $5 / 1M input tokens)
sum(increase(atm_tokens_total{type="input", model="gpt-4o"}[1h])) * 0.000005

# P95 request latency
histogram_quantile(0.95, rate(atm_request_duration_seconds_bucket[5m]))

# Error rate
rate(atm_requests_total{status=~"5.."}[5m]) / rate(atm_requests_total[5m])
```

---

## Supported tools

ATM works with any tool that respects `OPENAI_BASE_URL` or `ANTHROPIC_BASE_URL`:

| Tool | Detection |
|---|---|
| [Cursor](https://cursor.sh) | `User-Agent: cursor` |
| [OpenCode](https://opencode.ai) | `User-Agent: opencode` |
| [Claude Code](https://claude.ai/code) | `User-Agent: claude` |
| [Aider](https://aider.chat) | `User-Agent: aider` |
| [Continue](https://continue.dev) | `User-Agent: continue` |
| Any OpenAI-compatible SDK | tracked as `unknown` |

---

## Using with OpenCode

The install script sets both `OPENAI_BASE_URL` and `ANTHROPIC_BASE_URL` automatically, so OpenCode works out of the box after a shell reload:

```bash
source ~/.zshrc
opencode   # all API calls routed through ATM
```

To configure manually, add a `provider` entry to your `opencode.json` (project root or `~/.config/opencode/opencode.json`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "anthropic": {
      "options": {
        "baseURL": "http://localhost:40080"
      }
    },
    "openai": {
      "options": {
        "baseURL": "http://localhost:40080"
      }
    }
  }
}
```

For custom OpenAI-compatible providers (e.g. GitHub Copilot routed through ATM):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "my-provider-via-atm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "My Provider via ATM",
      "options": {
        "baseURL": "http://localhost:40080",
        "headers": {
          "Authorization": "Bearer $MY_API_KEY"
        }
      },
      "models": {
        "my-model": { "name": "my-model" }
      }
    }
  }
}
```

Token usage appears as `tool="opencode"` in metrics.

---

## Using with Claude Code

The install script sets `ANTHROPIC_BASE_URL` automatically. After a shell reload, all `claude` CLI calls are tracked:

```bash
source ~/.zshrc
claude   # all Anthropic API calls routed through ATM
```

To configure manually:

```bash
export ANTHROPIC_BASE_URL=http://localhost:40080
claude
```

Or persist it in `~/.claude/settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:40080"
  }
}
```

Token usage appears as `tool="claude"` in metrics.

> **Note:** Claude Code disables MCP tool search when `ANTHROPIC_BASE_URL` points to a non-first-party host. Claude Code's own tools (Bash, file read/write, etc.) are unaffected.

---

## Verify tracking is working

After sending a request through any AI tool:

```bash
curl -s http://localhost:40080/metrics | grep atm_tokens_total
```

Expected output:

```
atm_tokens_total{model="claude-sonnet-4-5",tool="claude",type="input",user_id="mymac-alice"} 1234
atm_tokens_total{model="claude-sonnet-4-5",tool="claude",type="output",user_id="mymac-alice"} 567
```

If `tool` shows `unknown`, see [Troubleshooting](#troubleshooting).

---

## Troubleshooting

**Proxy not starting**
- Check `upstream_url` is reachable: `curl https://api.openai.com`
- Run with debug logging: `atm --debug`

**User ID shows as `anonymous`**
- Reload your shell: `source ~/.zshrc`
- Check: `echo $ATM_USER_ID`

**Budget not enforced**
- Set `budget.enabled: true` in `~/.config/atm/config.yaml` and restart

**No metrics appearing**
- Check proxy is up: `curl http://localhost:40080/health`

---

## License

MIT — see [LICENSE](LICENSE) for details.
