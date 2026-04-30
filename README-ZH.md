# AI Token Meter (ATM)

> 透明的反向代理，靜默監控團隊所有的 AI API 呼叫 — Token 數量、費用、延遲與個人請求稽核紀錄 — 無需修改任何程式碼。

[![GitHub release](https://img.shields.io/github/v/release/ViveportSoftware/ai-token-meter?style=flat-square)](https://github.com/ViveportSoftware/ai-token-meter/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

[English](README.md) | 繁體中文

---

## 運作原理

```
你的 AI 工具（Cursor / Claude Code / Cline / Aider / OpenCode）
        │  OPENAI_API_BASE=http://localhost:40080
        ▼
  ┌─────────────────┐
  │  ATM  :40080    │──────────────────────► LLM 供應商
  │  反向代理        │                       (OpenAI / Anthropic / …)
  └────────┬────────┘
           │ metrics + 稽核紀錄
           ▼
     GET /metrics ◄── Prometheus ◄── Grafana
```

ATM 插在你的 AI 工具和 LLM 供應商之間，**完全透明**。只要設定 `OPENAI_API_BASE`（或 `ANTHROPIC_BASE_URL`）就完成了。Token 計數、請求稽核、指標輸出全部自動運作。

---

## 安裝

```bash
curl -fsSL https://raw.githubusercontent.com/ViveportSoftware/ai-token-meter/main/scripts/install.sh | bash
```

安裝程式會：
- 根據你的 OS 和 CPU 架構下載對應的 binary
- 安裝到 `~/.local/bin/atm`
- 寫入預設設定檔到 `~/.config/atm/config.yaml`
- 在 shell profile 加入 `OPENAI_API_BASE=http://localhost:40080`
- 在 shell profile 加入 `ANTHROPIC_BASE_URL=http://localhost:40080`

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
listen_addr: ":40080"
openai_upstream_url: "https://api.openai.com"       # OpenAI 相容供應商
anthropic_upstream_url: "https://api.anthropic.com" # Anthropic API（選填；留空則停用）
log_level: "info"

audit:
  enabled: true
  db_path: ~/.local/share/atm/audit.db
  retention_days: 30
```

修改設定後需重啟 `atm`。

### 完整設定參考

| 設定項目 | 預設值 | 說明 |
|---|---|---|
| `listen_addr` | `:40080` | Proxy 監聽位址 |
| `openai_upstream_url` | `https://api.openai.com` | OpenAI 相容供應商的 base URL |
| `anthropic_upstream_url` | `""` | Anthropic API base URL（空字串 = 停用）|
| `metrics_path` | `/metrics` | Prometheus metrics 端點路徑 |
| `log_level` | `info` | `debug` / `info` / `warn` / `error` |
| `log_format` | `json` | `json` / `text` |
| `audit.enabled` | `true` | 將請求 metadata 寫入 SQLite |
| `audit.db_path` | `~/.local/share/atm/audit.db` | SQLite 資料庫路徑 |
| `audit.retention_days` | `30` | 自動刪除 N 天前的紀錄 |
| `audit.buffer_size` | `1000` | 批次寫入大小 |
| `audit.flush_interval_seconds` | `5` | 緩衝區最大保留秒數 |
| `forward_proxy.enabled` | `false` | 啟用 MITM forward proxy 模式（用於 Copilot）|
| `forward_proxy.ca_cert_path` | `~/.config/atm/ca.crt` | TLS 攔截用 CA 憑證 |
| `forward_proxy.ca_key_path` | `~/.config/atm/ca.key` | CA 私鑰 |

---

## Metrics

所有指標透過 `http://localhost:40080/metrics` 以 Prometheus 格式輸出。

| 指標 | 類型 | Labels |
|---|---|---|
| `atm_tokens_total` | Counter | `user_id`, `model`, `tool`, `type`（`input`\|`output`）|
| `atm_requests_total` | Counter | `user_id`, `model`, `tool`, `status` |
| `atm_request_duration_seconds` | Histogram | `model`, `tool` |

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

## 使用量統計

ATM 會將每筆請求寫入本機 SQLite 稽核紀錄，使用 `atm stats` 查詢：

```bash
# 過去 30 天的摘要（預設）
atm stats

# 僅今天
atm stats --today

# 依工具或模型過濾
atm stats --tool cursor --days 7
atm stats --model gpt-4o --days 14

# 輸出為 JSON
atm stats --json
```

也可透過 HTTP 查詢最近 100 筆請求：

```bash
curl http://localhost:40080/admin/audit | jq .
```

---

## 支援的工具

任何支援 `OPENAI_API_BASE` 或 `ANTHROPIC_BASE_URL` 的工具都可以直接使用，工具身份自動偵測，不需個別設定。

| 工具 | 偵測方式 |
|---|---|
| [Cursor](https://cursor.sh) | `User-Agent: cursor` 或 `X-Cursor-Client-Version` header |
| [Claude Code](https://claude.ai/code) | `User-Agent: claude` |
| [Cline](https://github.com/cline/cline) | `X-Title: Cline` header |
| [OpenCode](https://opencode.ai) | `User-Agent: opencode` |
| [Aider](https://aider.chat) | `User-Agent: aider` |
| [Continue](https://continue.dev) | `User-Agent: continue` |
| [Codex](https://github.com/openai/codex) | `User-Agent: codex` |
| [GitHub Copilot](https://github.com/features/copilot) | `User-Agent: copilot` / forward proxy 模式 |
| 自行申報的工具 | `X-ATM-Tool-ID: <名稱>` header（最高優先）|
| 其他 SDK | 標記為 `unknown` |

### 工具自行申報

任何工具可透過設定 `X-ATM-Tool-ID` header 自行申報身份，優先於所有自動偵測：

```bash
curl http://localhost:40080/v1/chat/completions \
  -H "X-ATM-Tool-ID: my-script" \
  ...
```

---

## 在 OpenCode 中使用

安裝腳本會自動設定 `OPENAI_API_BASE` 和 `ANTHROPIC_BASE_URL`，重新載入 shell 後 OpenCode 即可直接使用：

```bash
source ~/.zshrc
opencode   # 所有 API 呼叫都會透過 ATM 轉發
```

若需手動設定：

```bash
export OPENAI_API_BASE=http://localhost:40080
export ANTHROPIC_BASE_URL=http://localhost:40080
```

或在 `opencode.json`（專案根目錄或 `~/.config/opencode/opencode.json`）加入 `provider` 設定：

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

## 在 GitHub Copilot 中使用（forward proxy 模式）

GitHub Copilot 不支援 `OPENAI_API_BASE`。若要追蹤 Copilot 使用量，ATM 提供選用的 MITM forward proxy 模式攔截 HTTPS 流量。

1. 在設定檔啟用 forward proxy：

```yaml
forward_proxy:
  enabled: true
  ca_cert_path: ~/.config/atm/ca.crt
  ca_key_path: ~/.config/atm/ca.key
```

2. 啟動 ATM — 第一次執行時會自動產生 CA 憑證。

3. 將 CA 憑證加入系統信任清單：

```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/.config/atm/ca.crt
```

4. 在 VS Code settings.json 設定 ATM 為 HTTPS proxy：

```json
{
  "http.proxy": "http://localhost:40080",
  "http.proxyStrictSSL": true
}
```

Token 使用量在 metrics 中會以 `tool="copilot"` 顯示。

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
- 確認 `openai_upstream_url` 可連線：`curl https://api.openai.com`
- 開啟 debug 模式：`atm --debug`

**User ID 顯示為 `anonymous`**
- 重新載入 shell：`source ~/.zshrc`
- 確認環境變數：`echo $ATM_USER_ID`

**tool 顯示為 `unknown`**
- 對於沒有可識別 User-Agent 的工具，在 `identity.tools` 加入偵測規則，或設定 `X-ATM-Tool-ID` header

**沒有 metrics 資料**
- 確認 proxy 正在執行：`curl http://localhost:40080/health`

**Claude Code：顯示「MCP server search disabled」**
- 當 `ANTHROPIC_BASE_URL` 指向非官方主機時，此行為是預期的。Claude Code 本身的工具（Bash、檔案讀寫）不受影響。

---

## 授權

MIT — 詳見 [LICENSE](LICENSE)。
