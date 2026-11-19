# ACP (Agent Client Protocol) v1 仕様と拡張境界の整理

- **確認日**: `2026-11-19`
- **対象仕様**: Agent Client Protocol (ACP) v1（`protocolVersion: 1`）
- **出典**: ACP 公式仕様（`https://agentclientprotocol.com/protocol/v1/overview` ほか各章、確認日 `2026-11-19`）

---

## 1. 外部一次資料の事実（トランスポートと基本ライフサイクル）

- **トランスポート**: **JSON-RPC 2.0 over `stdio`**（改行区切り JSON: Newline-Delimited JSON / 1 メッセージ 1 行 `\n` 終端）。
  - クライアント（エディタや `acp_cli_client`）がエージェントエンジン（`agent_os_daemon`）をサブプロセスとして起動し、エージェントの **`stdout` は JSON-RPC メッセージ専用** とする（デバッグログ等を `stdout` に混入させるとプロトコル破損になるため、エンジンの内部ログはすべてファイルまたは `stderr` に出すこと）。
- **基本フロー**:
  1. `initialize`（Client → Agent Request）：プロトコルバージョン（整数 `1`）と双方の Capabilities を交渉。
  2. `session/new`（Client → Agent Request）：作業ディレクトリ `cwd` 等を指定してセッションを生成し、`sessionId` と初期設定一覧（`configOptions` / `modes`）を受け取る。
  3. `session/prompt`（Client → Agent Request）：ユーザー入力を送信してターンを開始。
  4. ターン実行中、Agent → Client へ **`session/update`（Notification）** で思考・本文チャンク・ツール実行状態・コンテキスト使用量をストリーム通知し、承認が必要な操作では Agent → Client へ **`session/request_permission`（双方向 JSON-RPC Request）** を送って応答を待機する。
  5. ターン完了時、Agent が最初の `session/prompt` Request に対する JSON-RPC Response（`stopReason: "end_turn"` 等）を返して 1 ターンが終了する。

---

## 2. Stage 1 Step 1-3 で実装すべきコアメソッド一覧

| メソッド名 | 種別 / 方向 | 主要パラメータ (`params`) | 応答 (`result`)・備考 |
| --- | --- | --- | --- |
| `initialize` | Request<br>Client → Agent | `protocolVersion: 1`, `clientCapabilities: {...}`, `clientInfo: {name, version}` | `protocolVersion: 1`, `agentCapabilities: {...}`, `agentInfo: {name, version}`, `authMethods: []` |
| `session/new` | Request<br>Client → Agent | `cwd: "<abs_path>"`, `mcpServers: [...]`（空配列 `[]` 可） | `sessionId: "sess_..."`, `configOptions: [...]`（モデル・モード選択用、後述） |
| `session/prompt` | Request<br>Client → Agent | `sessionId: "sess_..."`, `prompt: [{type: "text", text: "..."}]`（`_meta` 付与可） | `stopReason: "end_turn" \| "cancelled" \| "max_tokens" \| "refusal"`（`_meta` 付与可） |
| `session/update` | Notification<br>Agent → Client | `sessionId: "sess_..."`, `update: { sessionUpdate: "<kind>", ... }` | 応答なし（Notification）。詳細は 2.1 節 |
| `session/request_permission` | Request<br>**Agent → Client** | `sessionId: "sess_..."`, `toolCall: {...}`, `options: [{optionId, name, kind}]` | `outcome: { outcome: "selected", optionId: "..." }` または `{ outcome: "cancelled" }` |
| `session/cancel` | Notification<br>Client → Agent | `sessionId: "sess_..."` | 進行中の推論・`sys_exec`・承認待ちを中断し、進行中の `session/prompt` を `stopReason: "cancelled"` で完了させる |
| `session/set_config_option` | Request<br>Client → Agent | `sessionId: "sess_..."`, `configId: "model"`, `value: "openrouter/..."` | 更新後の `configOptions: [...]` を返却（モデル切替・モード切替の推奨統一方式） |
| `session/set_mode` | Request<br>Client → Agent | `sessionId: "sess_..."`, `modeId: "..."` | 空オブジェクト `{}`（ACP v1 レガシー互換。`set_config_option` の `category: "mode"` への統合が進んでいる） |

### 2.1 `session/update` の標準 `sessionUpdate` ペイロード種別

| `sessionUpdate` 値 | 用途 | 主なフィールド |
| --- | --- | --- |
| `"agent_thought_chunk"` | 思考過程（Thinking）のストリーム出力 | `content: { type: "text", text: "..." }` |
| `"agent_message_chunk"` | エージェント応答本文のストリーム出力 | `content: { type: "text", text: "..." }` |
| `"tool_call"` | システムコール（ツール）開始通知 | `toolCallId`, `title`, `kind` (`"read" \| "edit" \| "delete" \| "move" \| "search" \| "execute" \| "think" \| "fetch" \| "other"`), `status` (`"pending" \| "in_progress"`), `content` (任意), `locations` (任意) |
| `"tool_call_update"` | システムコール状態遷移・結果・Diff 通知 | `toolCallId`, `status` (`"in_progress" \| "completed" \| "failed"`), `content: [...]`（テキスト出力や **`diff` ブロック**） |
| `"usage_update"` | コンテキスト窓使用量・累積コスト通知 | `used: <int>`, `size: <int>`, `cost: { amount: <number>, currency: "USD" }`（任意） |
| `"config_option_update"` | 利用可能モデルや現在選択モデルの変化通知 | `configOptions: [...]` |
| `"plan"` | タスク計画ステップの提示（任意） | `entries: [{ content, priority, status }]` |

#### ファイル変更 Diff の表現（ACP v1 標準）
`tool_call` / `tool_call_update`（および `session/request_permission` 内の `toolCall.content`）には以下の `diff` オブジェクトを含められるため、`sys_tx_squash` や編集承認時にクライアント側でそのまま差分表示できる：
```json
{
  "type": "diff",
  "path": "c:/Users/rero2/develop/fm-agent-os-2/lib/main.dart",
  "oldText": "旧ファイル内容（新規作成時は null）",
  "newText": "新ファイル内容"
}
```
※ リポジトリ全体の統合 `jj diff --git` テキストを見せたい場合は、併せて `{ "type": "content", "content": { "type": "text", "text": "..." } }` または `_meta` に添付できる。

### 2.2 `session/request_permission`（Ring 2 承認ゲート）の正確な構造

エージェントプロセスが `WAITING_APPROVAL` に入った際、ACP サーバーは以下の JSON-RPC Request をクライアントへ送信する：

```json
{
  "jsonrpc": "2.0",
  "id": "perm_req_1",
  "method": "session/request_permission",
  "params": {
    "sessionId": "sess_01",
    "toolCall": {
      "toolCallId": "sc_0042",
      "title": "Squash working change into @- (2 files modified)",
      "kind": "edit",
      "status": "pending",
      "content": [
        {
          "type": "diff",
          "path": "c:/workspace/lib/foo.dart",
          "oldText": "...",
          "newText": "..."
        }
      ]
    },
    "options": [
      { "optionId": "allow_once", "name": "Allow once", "kind": "allow_once" },
      { "optionId": "allow_always", "name": "Allow for session", "kind": "allow_always" },
      { "optionId": "reject_once", "name": "Deny", "kind": "reject_once" }
    ]
  }
}
```

クライアントからの JSON-RPC Response:
- **承認時**: `{"jsonrpc": "2.0", "id": "perm_req_1", "result": {"outcome": {"outcome": "selected", "optionId": "allow_once"}}}` → カーネルがシステムコールを実行して結果をエージェントへ返す。
- **拒否時**: `{"jsonrpc": "2.0", "id": "perm_req_1", "result": {"outcome": {"outcome": "selected", "optionId": "reject_once"}}}` → カーネルが監査ログに `DENIED_BY_USER` を記録し、エージェントへ `EACCES` を返す。
- **ターンキャンセル時**: クライアントから `session/cancel` が届いた場合、未決の `request_permission` は `{"outcome": {"outcome": "cancelled"}}` として終了させる。

---

## 3. ACP 標準準拠部分と独自拡張の切り分け規則（Extensibility 規約）

ACP 公式の Extensibility 仕様（`https://agentclientprotocol.com/protocol/v1/extensibility`）には以下の厳格な互換ルールがある：
1. **標準オブジェクトのルート直下に未知の独自プロパティを追加してはならない（MUST NOT）**。
2. 任意の追加メタデータはすべての主要型に用意されている **`_meta: { [key: string]: unknown } | null`** フィールド内に格納する（キーには名前空間プレフィックス推奨、例 `"fm_agent_os/..."`）。
3. 独自の JSON-RPC メソッド／通知を追加する場合は、**メソッド名を必ずアンダースコア `_` で始める**（例: `"_fm_agent_os/rollback"`）。未対応クライアントは標準 JSON-RPC 規則（Request なら `-32601 Method not found`、Notification なら無視）で安全に処理できる。

### 本プロジェクト固有要件と ACP 標準のマッピング表

| 実現したい機能 | ACP 標準で実現できる範囲（最優先で採用） | 拡張（`_meta` または `_` メソッド）にする部分 |
| --- | --- | --- |
| **プロンプト毎のプロバイダ／モデル切替** | **`session/new` の `configOptions`（標準予約カテゴリ `category: "model"`, `id: "model"`）＋ `session/set_config_option`** で、Zed 等の一般 ACP クライアント UI 上のモデルドロップダウンからそのまま切り替え可能！（簡易 CLI の `/model <provider/model>` コマンドも内部で `session/set_config_option` を呼べば 100% 標準準拠になる） | もし 1 回の `session/prompt` 単位で一時的にモデルを上書き指定したい場合のみ、`session/prompt` の `params._meta["fm_agent_os/modelOverride"]` を補助的に受け付ける（標準クライアントとも完全互換）。 |
| **コンテキスト使用量・コスト表示** | **`session/update` の `sessionUpdate: "usage_update"`**（`used`, `size`, `cost`）で標準クライアントのコンテキストバーに表示可能。 | **ターン毎の `cachedTokens`, `cacheWriteTokens`, `cacheHitRate`, `ttftMs`, `provider`, `model`** といった詳細 KV キャッシュ統計は、`usage_update._meta["fm_agent_os/llmTelemetry"]`（および `session/prompt` 応答の `result._meta`）に格納する。`acp_cli_client` はここを読んでリッチ表示し、一般 ACP エディタは無視して壊れない。 |
| **`jj` トランザクション状態（`changeId`, `opId`）と手動 `undo`** | 各 `tool_call` / `tool_call_update` の表示タイトルや `diff` ブロックは標準フィールドで表現。 | 現在の `jjChangeId` / `jjOpId` は `tool_call_update._meta["fm_agent_os/jj"]` に添付。また CLI から人間が直接トランザクションロールバックを指示したい場合は、カスタムメソッド **`_fm_agent_os/tx_rollback`**（またはプロンプトのスラッシュコマンド）として切り分ける。 |
