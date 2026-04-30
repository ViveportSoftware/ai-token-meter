# AI Token Meter (ATM)

> A transparent reverse proxy that silently monitors every AI API call your team makes — token counts, costs, latency, and per-user audit log — without changing a single line of code.

[![GitHub release](https://img.shields.io/github/v/release/ViveportSoftware/ai-token-meter?style=flat-square)](https://github.com/ViveportSoftware/ai-token-meter/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

---

## How it works

```
Your AI Tool (Cursor / Claude Code / Cline / Aider / OpenCode)
        │  OPENAI_API_BASE=http://localhost:40080
        ▼
  ┌─────────────────┐
  │  ATM  :40080    │──────────────────────► LLM Provider
  │  reverse proxy  │                       (OpenAI / Anthropic / …)
  └────────┬────────┘
           │ metrics + audit log
           ▼
     GET /metrics ◄── Prometheus ◄── Grafana
```

ATM sits between your AI tools and the LLM provider. It is **completely transparent** — just set `OPENAI_API_BASE` (or `ANTHROPIC_BASE_URL`) and forget it. Tokens are counted, requests are audited, and metrics are exposed automatically.

---

## Install

```bash
curl -fsSL https://github.com/ViveportSoftware/ai-token-meter/releases/latest/download/install.sh | bash
```

The installer:
- Downloads the correct binary for your OS and architecture
- Installs to `~/.local/bin/atm`
- Writes a default config to `~/.atm/config.yaml`
- Sets `OPENAI_API_BASE=http://localhost:40080` in your shell profile
- Sets `ANTHROPIC_BASE_URL=http://localhost:40080` in your shell profile

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
curl -fsSL https://github.com/ViveportSoftware/ai-token-meter/releases/latest/download/install.sh | bash -s -- --uninstall
```

---

## Configuration

Config lives at `~/.atm/config.yaml`. Edit it to match your setup:

```yaml
listen_addr: ":40080"
openai_upstream_url: "https://api.openai.com"       # OpenAI-compatible provider
anthropic_upstream_url: "https://api.anthropic.com" # Anthropic API (optional; empty = disabled)
log_level: "info"

audit:
  enabled: true
  db_path: ~/.atm/audit.db
  retention_days: 30
```

Restart `atm` after any config change.

### Full config reference

| Key | Default | Description |
|---|---|---|
| `listen_addr` | `:40080` | Proxy listen address |
| `openai_upstream_url` | `https://api.openai.com` | OpenAI-compatible provider base URL |
| `anthropic_upstream_url` | `""` | Anthropic API base URL (empty = disabled) |
| `metrics_path` | `/metrics` | Prometheus metrics endpoint path |
| `log_level` | `info` | `debug` / `info` / `warn` / `error` |
| `log_format` | `json` | `json` / `text` |
| `audit.enabled` | `true` | Persist request metadata to SQLite |
| `audit.db_path` | `~/.atm/audit.db` | SQLite database file path |
| `audit.retention_days` | `30` | Auto-delete entries older than N days |
| `audit.buffer_size` | `1000` | Batch insert size |
| `audit.flush_interval_seconds` | `5` | Max seconds before flushing buffer |
| `forward_proxy.enabled` | `false` | Enable MITM forward proxy mode (for Copilot) |
| `forward_proxy.ca_cert_path` | `~/.atm/ca.crt` | CA certificate for TLS interception |
| `forward_proxy.ca_key_path` | `~/.atm/ca.key` | CA private key |

---

## Metrics

All metrics are exposed at `http://localhost:40080/metrics` in Prometheus format.

| Metric | Type | Labels |
|---|---|---|
| `atm_tokens_total` | Counter | `user_id`, `model`, `tool`, `type` (`input`\|`output`) |
| `atm_requests_total` | Counter | `user_id`, `model`, `tool`, `status` |
| `atm_request_duration_seconds` | Histogram | `model`, `tool` |

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

## Usage statistics

ATM stores every request in a local SQLite audit log. Query it with `atm stats`:

```bash
# Summary for the last 30 days (default)
atm stats

# Today only
atm stats --today

# Filter by tool or model
atm stats --tool cursor --days 7
atm stats --model gpt-4o --days 14

# Machine-readable JSON
atm stats --json
```

You can also query the last 100 requests via HTTP:

```bash
curl http://localhost:40080/admin/audit | jq .
```

---

## Supported tools

ATM works with any tool that respects `OPENAI_API_BASE` or `ANTHROPIC_BASE_URL`. Tool identity is detected automatically — no per-tool configuration required.

| Tool | Detection method |
|---|---|
| [Cursor](https://cursor.sh) | `User-Agent: cursor` or `X-Cursor-Client-Version` header |
| [Claude Code](https://claude.ai/code) | `User-Agent: claude` |
| [Cline](https://github.com/cline/cline) | `X-Title: Cline` header |
| [OpenCode](https://opencode.ai) | `User-Agent: opencode` |
| [Aider](https://aider.chat) | `User-Agent: aider` |
| [Continue](https://continue.dev) | `User-Agent: continue` |
| [Codex](https://github.com/openai/codex) | `User-Agent: codex` |
| [GitHub Copilot](https://github.com/features/copilot) | `User-Agent: copilot` / forward proxy mode |
| Self-reporting tool | `X-ATM-Tool-ID: <name>` header (highest priority) |
| Any other SDK | tracked as `unknown` |

### Tool self-reporting

Any tool can self-identify by setting the `X-ATM-Tool-ID` header. This overrides all automatic detection:

```bash
curl http://localhost:40080/v1/chat/completions \
  -H "X-ATM-Tool-ID: my-script" \
  ...
```

---

## Using with OpenCode

The install script sets both `OPENAI_API_BASE` and `ANTHROPIC_BASE_URL` automatically, so OpenCode works out of the box after a shell reload:

```bash
source ~/.zshrc
opencode   # all API calls routed through ATM
```

To configure manually:

```bash
export OPENAI_API_BASE=http://localhost:40080
export ANTHROPIC_BASE_URL=http://localhost:40080
```

Or add a `provider` entry to your `opencode.json` (project root or `~/.config/opencode/opencode.json`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "anthropic": {
      "options": { "baseURL": "http://localhost:40080" }
    },
    "openai": {
      "options": { "baseURL": "http://localhost:40080" }
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

## Using with GitHub Copilot (forward proxy mode)

GitHub Copilot does not respect `OPENAI_API_BASE`. To track Copilot usage, ATM includes an optional MITM forward proxy mode that intercepts HTTPS traffic.

1. Enable forward proxy in config:

```yaml
forward_proxy:
  enabled: true
  ca_cert_path: ~/.atm/ca.crt
  ca_key_path: ~/.atm/ca.key
```

2. Start ATM — it generates a CA certificate on first run.

3. Trust the CA cert in your system keychain:

```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/.atm/ca.crt
```

4. Configure VS Code to use ATM as HTTPS proxy:

```json
// settings.json
{
  "http.proxy": "http://localhost:40080",
  "http.proxyStrictSSL": true
}
```

Token usage appears as `tool="copilot"` in metrics.

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
- Check `openai_upstream_url` is reachable: `curl https://api.openai.com`
- Run with debug logging: `atm -debug`

**User ID shows as `anonymous`**
- Reload your shell: `source ~/.zshrc`
- Check your config: `cat ~/.atm/config.yaml | grep default_user_id`

**tool shows as `unknown`**
- For tools with no identifiable User-Agent, add a detection rule in `identity.tools` or set `X-ATM-Tool-ID` header

**No metrics appearing**
- Check proxy is up: `curl http://localhost:40080/health`

**Claude Code: "MCP server search disabled"**
- This is expected when `ANTHROPIC_BASE_URL` points to a non-first-party host. Claude Code's own tools (Bash, file read/write) are unaffected.

---

## License

MIT — see [LICENSE](LICENSE) for details.
