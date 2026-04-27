# AI Token Meter (ATM)

> 透明的反向代理，靜默監控團隊所有的 AI API 呼叫 — Token 數量、費用、延遲與個人預算限制 — 無需修改任何程式碼。

[![GitHub release](https://img.shields.io/github/v/release/ViveportSoftware/ai-token-meter?style=flat-square)](https://github.com/ViveportSoftware/ai-token-meter/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

[English](README.md) | 繁體中文

---

## 運作原理

```
你的 AI 工具（Cursor / OpenCode / Aider / Continue）
        │  OPENAI_BASE_URL=http://localhost:40080
        ▼
  ┌─────────────────┐
  │  ATM  :40080    │──────────────────────► LLM 供應商
  │  反向代理        │                       (OpenAI / Anthropic / …)
  └────────┬────────┘
           │ metrics
           ▼
     GET /metrics ◄── Prometheus ◄── Grafana
```

ATM 插在你的 AI 工具和 LLM 供應商之間，**完全透明**。只要設定 `OPENAI_BASE_URL` 就完成了，不需要修改任何工具設定或程式碼。Token 計數、費用計算、預算管控全部自動運作。

---

## 安裝

```bash
curl -fsSL https://raw.githubusercontent.com/ViveportSoftware/ai-token-meter/main/scripts/install.sh | bash
```

安裝程式會：
- 根據你的 OS 和 CPU 架構下載對應的 binary
- 安裝到 `~/.local/bin/atm`
- 寫入預設設定檔到 `~/.config/atm/config.yaml`
- 在 shell profile 加入 `OPENAI_BASE_URL=http://localhost:40080`

重新載入 shell 後啟動 daemon：

```bash
source ~/.zshrc   # Linux 用 ~/.bashrc
atm &
```

確認運作正常：

```bash
curl http://localhost:40080/health
# → {"status":"ok"}
```

### 解除安裝

```bash
curl -fsSL https://raw.githubusercontent.com/ViveportSoftware/ai-token-meter/main/scripts/install.sh | bash -s -- --uninstall
```

---

## 設定

設定檔位置：`~/.config/atm/config.yaml`，根據需求修改：

```yaml
upstream_url: "https://api.openai.com"   # 你的 LLM 供應商

budget:
  enabled: true
  daily_limit: 100000      # 每人每日 token 上限（0 = 無限制）
  monthly_limit: 2000000   # 每人每月 token 上限（0 = 無限制）

rate_limit:
  enabled: true
  requests_per_minute: 60
  burst: 10
```

修改設定後需重啟 `atm`。

### 完整設定參考

| 設定項目 | 預設值 | 說明 |
|---|---|---|
| `listen_addr` | `:40080` | Proxy 監聽位址 |
| `upstream_url` | `https://api.openai.com` | LLM 供應商的 base URL |
| `budget.enabled` | `false` | 開啟個人 token 預算管控 |
| `budget.daily_limit` | `0` | 每日 token 上限（0 = 無限制）|
| `budget.monthly_limit` | `0` | 每月 token 上限（0 = 無限制）|
| `rate_limit.enabled` | `false` | 開啟個人請求頻率限制 |
| `rate_limit.requests_per_minute` | `60` | 每人每分鐘最大請求數 |
| `rate_limit.burst` | `10` | 超過頻率限制時允許的爆量值 |
| `log_level` | `info` | `debug` / `info` / `warn` / `error` |

---

## Metrics

所有指標透過 `http://localhost:40080/metrics` 以 Prometheus 格式輸出。

| 指標 | 類型 | Labels |
|---|---|---|
| `atm_tokens_total` | Counter | `user_id`, `model`, `tool`, `type`（`input`\|`output`）|
| `atm_requests_total` | Counter | `user_id`, `model`, `tool`, `status` |
| `atm_request_duration_seconds` | Histogram | `model`, `tool` |

`tool` 由 `User-Agent` header 自動偵測：`aider`、`opencode`、`cursor`、`continue` 或 `unknown`。

### PromQL 範例

```promql
# 各模型的 token 使用速率
sum by (model) (rate(atm_tokens_total[5m]))

# 估算費用（以 gpt-4o 為例：$5 / 1M input tokens）
sum(increase(atm_tokens_total{type="input", model="gpt-4o"}[1h])) * 0.000005

# P95 請求延遲
histogram_quantile(0.95, rate(atm_request_duration_seconds_bucket[5m]))

# 錯誤率
rate(atm_requests_total{status=~"5.."}[5m]) / rate(atm_requests_total[5m])
```

---

## 支援的工具

任何支援 `OPENAI_BASE_URL` 或 `ANTHROPIC_BASE_URL` 的工具都可以直接使用：

| 工具 | 偵測方式 |
|---|---|
| [Cursor](https://cursor.sh) | `User-Agent: cursor` |
| [OpenCode](https://opencode.ai) | `User-Agent: opencode` |
| [Claude Code](https://claude.ai/code) | `User-Agent: claude` |
| [Aider](https://aider.chat) | `User-Agent: aider` |
| [Continue](https://continue.dev) | `User-Agent: continue` |
| 任何 OpenAI 相容 SDK | 標記為 `unknown` |

---

## 在 OpenCode 中使用

安裝腳本會自動設定 `OPENAI_BASE_URL` 和 `ANTHROPIC_BASE_URL`，重新載入 shell 後 OpenCode 即可直接使用：

```bash
source ~/.zshrc
opencode   # 所有 API 呼叫都會透過 ATM 轉發
```

若需手動設定，在 `opencode.json`（專案根目錄或 `~/.config/opencode/opencode.json`）加入 `provider` 設定：

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

若要透過 ATM 使用自訂 OpenAI 相容供應商（例如 GitHub Copilot）：

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

Token 使用量在 metrics 中會以 `tool="opencode"` 顯示。

---

## 在 Claude Code 中使用

安裝腳本會自動設定 `ANTHROPIC_BASE_URL`，重新載入 shell 後即可追蹤所有 `claude` CLI 呼叫：

```bash
source ~/.zshrc
claude   # 所有 Anthropic API 呼叫都會透過 ATM 轉發
```

若需手動設定：

```bash
export ANTHROPIC_BASE_URL=http://localhost:40080
claude
```

或寫入 `~/.claude/settings.json` 永久生效：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:40080"
  }
}
```

Token 使用量在 metrics 中會以 `tool="claude"` 顯示。

> **注意：** 當 `ANTHROPIC_BASE_URL` 指向非 Anthropic 官方主機時，Claude Code 會停用 MCP tool search 功能。Claude Code 本身的工具（Bash、檔案讀寫等）不受影響。

---

## 確認追蹤正常運作

透過任何 AI 工具送出請求後：

```bash
curl -s http://localhost:40080/metrics | grep atm_tokens_total
```

預期輸出：

```
atm_tokens_total{model="claude-sonnet-4-5",tool="claude",type="input",user_id="mymac-alice"} 1234
atm_tokens_total{model="claude-sonnet-4-5",tool="claude",type="output",user_id="mymac-alice"} 567
```

若 `tool` 顯示 `unknown`，請參考[常見問題](#常見問題)。

---

## 常見問題

**Proxy 無法啟動**
- 確認 `upstream_url` 可連線：`curl https://api.openai.com`
- 開啟 debug 模式：`atm --debug`

**User ID 顯示為 `anonymous`**
- 重新載入 shell：`source ~/.zshrc`
- 確認環境變數：`echo $ATM_USER_ID`

**預算沒有生效**
- 在 `~/.config/atm/config.yaml` 設定 `budget.enabled: true` 後重啟

**沒有 metrics 資料**
- 確認 proxy 正在執行：`curl http://localhost:40080/health`

---

## 授權

MIT — 詳見 [LICENSE](LICENSE)。
