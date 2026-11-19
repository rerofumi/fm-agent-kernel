# 42_spec_kernel_and_llm.md — カーネルコア・I/O キャップ・Canonical IR・3 プロバイダ LLM・監査/キャッシュ監視仕様

関連文書:
- 全体構造・優先順位・副作用境界（正本）: [40_specification.md](./40_specification.md)
- 要求・受け入れ条件: [30_requirement.md](./30_requirement.md)（対象: `REQ-01`, `REQ-03`, `REQ-04`）
- 技術調査・実測根拠: [llm_providers_and_cache.md](../cheatsheet/llm_providers_and_cache.md), [env_and_dart_windows.md](../cheatsheet/env_and_dart_windows.md)

---

## 1. カーネルコア構造・PCB・シングルプロセス安全ロック（`REQ-01`）

### 1.1 PCB・保護リング・ケーパビリティ・クオータモデル

D-005: プロセス制御ブロック（PCB）・保護リング・シングルプロセス安全ロック

対応要求: `REQ-01`, `REQ-10`（関連判断: `OM-01`, 依存境界: `[D-001]`, `[D-002]`）

#### 配置パス（`packages/agent_kernel/lib/src/`）
- `pcb.dart`: `ProcessControlBlock`, `Pid`, `ProtectionRing`, `ProcessState`, `JjTxContext`
- `capability.dart`: `CapHandle`, `CapRight`, `CapabilityEntry`, `CapabilityTable` (`CSpace`)
- `quota.dart`: `ResourceQuota`, `QuotaConsumption`
- `syscall_gate.dart`: `SyscallRequest`, `SyscallResult`, `SyscallDefinition`, `SyscallGate`
- `packages/agent_runtime/lib/src/process_runner.dart`: `ProcessRunner`（Stage 1 `GreenTaskProcessRunner`）, `LeadAgent`

#### 主要データ構造と状態遷移
```dart
enum ProtectionRing {
  ring0, // Kernel Core (TCB)
  ring1, // System Services (Stage 2 ContextPager 等)
  ring2, // LeadAgent (標準コーディングエージェント: 要注意操作で ASK_USER)
  ring3, // Sandboxed Sub-Agent (Stage 2 以降: UI 承認要求禁止・減衰権限のみ)
}

enum ProcessState {
  ready,
  running,
  waitingSyscall,
  waitingApproval, // Ring 2 ASK_USER により一時停止中
  stopped,
  terminated,
}
```

- **`ProcessControlBlock` (`PCB`) の保持項目**:
  - `pid` (`int`: Stage 1 では `LeadAgent` が `pid = 1`)、`parentPid` (`null`)、`name` (`"lead-agent"`)
  - `ring` (`ProtectionRing.ring2`)、`state` (`ProcessState`)
  - `cspace` (`CapabilityTable`: `/workspace` の `read | writeCow | exec | vcsRead | vcsTx | llmInfer` ハンドルを保持)
  - `quota` (`ResourceQuota`: `maxChildProcesses = 0`【Stage 1 安全ロック】、`maxSyscallCountPerTurn` 既定 `64`、任意のトークン・費用上限)
  - `namespace` (`VfsNamespace` `[D-011]`)、`jjContext` (`JjTxContext` `[D-015]`)、`memory` (`VirtualContextMemory` `[D-007]`)
- **Stage 1 シングルプロセス安全ロックと Stage 2 拡張境界**:
  - `KernelProcessTable` は Stage 1 構成で `maxActiveProcesses = 1`・`quota.maxChildProcesses = 0` を強制する。万一 `sys_spawn` が呼ばれた場合は `[D-002]` Stage 2 検査で `SyscallErrorCode.eperm`（`reason: "STAGE1_SINGLE_PROCESS_LOCK"`）を返す。
  - `SyscallDefinition` はハンドラ本体に加え、任意の Stage 2 事前条件検査コールバック（`TxState.active` 必須検査等）および任意の Stage 4 承認プレビュー生成コールバック `ApprovalPreviewBuilder`（副作用ゼロ契約：`--ignore-working-copy` 参照等のみ許容）を保持できる。`KernelBootstrap` `[D-022]` がドライバ側の非破壊プレビュー関数をここへ配線することで、`agent_kernel` と `agent_acp` が `JjDriver` や VFS 実装へ直接依存せずに `[D-020]` の `ApprovalRequest` 差分を構築できる。
  - ユーザー空間の `LeadAgent`（`packages/agent_runtime`）は「ユーザー入力受付 → `sys_llm_chat` 推論 → Tool Call があれば `SyscallGate.invoke` で順次実行し結果を Canonical IR へ追記 → 最終テキスト応答でターン終了」という ReAct ループのみを担い、ドライバ実体への参照を一切持たない。

---

### 1.2 カーネル I/O 出力サイズ強制キャップ機構（`REQ-01`）

D-006: カーネル I/O 出力サイズ強制キャップ機構（IoPayloadCapper）

対応要求: `REQ-01`, `REQ-02`, `REQ-07`（パイプライン位置: `[D-002]` Stage 7）

#### 配置パス
- `packages/agent_kernel/lib/src/io_payload_capper.dart`

#### 動作仕様と境界条件
LLM コンテキストへ返却される全ツール系システムコール出力（`sys_read_lines`, `sys_glob`, `sys_grep`, `sys_jj_status`, `sys_jj_log`, `sys_jj_diff`, `sys_exec` の `stdout`/`stderr` 等。※推論応答自体の `sys_llm_chat` を除く）に対し、`[D-002]` Stage 7 で決定論的なハードリミットを適用する。

1. **既定上限パラメータ（`IoCapConfig`：起動時注入可、テストで小値変更可）**:
   - `maxLines`: **`200` 行**（先頭保持 `headLines = 140` 行、末尾保持 `tailLines = 60` 行）
   - `maxUtf8Bytes`: **`16,384` バイト（16 KiB）**（1 行極長ミニファイファイル対策として、行数上限以内でも UTF-8 バイト長が超過した場合は先頭 `11,264` バイト＋末尾 `4,096` バイトを UTF-8 ルーン境界を壊さずに切り詰める）
2. **境界値での振る舞い**:
   - **上限以下（`lines <= maxLines && utf8Bytes <= maxUtf8Bytes`）**: 1 バイトの改変・省略もなく原文をそのまま返し、メタデータ `truncated: false` を設定する。
   - **上限超過（`lines > maxLines || utf8Bytes > maxUtf8Bytes`）**:
     1. 全文を `/workspace/.agent_os/io_spill/<sessionId>/<syscallSeq>_<syscallName>.txt` へ UTF-8 保存する（`[D-003]` により `.agent_os/` は `jj` 追跡対象外）。
     2. 返却テキストを以下の決定論的フォーマットへ置換し、`truncated: true`, `originalLines`, `originalBytes`, `omittedLines`, `omittedBytes` を付与する：
        ```text
        <先頭 head 部分>
        ... [KERNEL I/O CAP: omitted <omittedLines> lines (<omittedBytes> bytes) out of <originalLines> lines (<originalBytes> bytes). Narrow range with sys_read_lines(startLine, endLine) or refine pattern.] ...
        <末尾 tail 部分>
        ```
     3. 構造化 JSON フィールドを持つ結果（例: `sys_read_lines` の `sha256`, `totalLines` や `sys_exec` の `exitCode`）は切り詰め対象から保護し、本文テキストフィールド（`content`, `matches`, `diff`, `stdout`, `stderr`）のみをキャップする。これにより `sys_read_lines` がキャップされた場合でも、ファイル全体の正確な `sha256` と `totalLines` は欠損せず返却される。

---

## 2. Prefix 保持 Canonical IR と 3 LLM プロバイダドライバ（`REQ-03`）

### 2.1 Prefix 保持 3 セグメント Canonical IR とモデル切替射影規則

D-007: Prefix 保持 3 セグメント Canonical IR（VirtualContextMemory）

対応要求: `REQ-03`, `REQ-04`（関連判断: `OM-02`, 優先順位正本: `[D-002]`）

#### 配置パス
- `packages/agent_kernel/lib/src/context_memory.dart`

#### 3 セグメント構造（KV キャッシュ Exact Prefix Match 保護）
`VirtualContextMemory` はベンダー固有 JSON を一切保持せず、以下の 3 セグメント順序で論理コンテキストを構成する：

| 順序 | セグメント | 保持する正規化型 | 不変条件（KV キャッシュ維持規約） |
| :---: | :--- | :--- | :--- |
| **0** | `SystemPinnedSegment` | `PinnedSystemInstruction`（基本 OS ルール・`jj` 作業モデル説明）＋ 名前順ソート済みの `List<SyscallToolSchema>` | セッション生存中は **1 バイトも書き換えない**。現在時刻・担当 `Change ID` 等の動的値を混ぜない。 |
| **1** | `AppendOnlyHistorySegment` | 完了済みターンの追記列：`CanonicalUserTurn`, `CanonicalAssistantTurn`, `CanonicalToolResultTurn` | Stage 1 では途中の要素の削除・並び替え・書き換えを行わず末尾追記のみとする。 |
| **2** | `EphemeralTailSegment` | 当該ターンの動的コンテキスト添付（必要時の現在 `jj` 状態サマリ等）＋ 今回のユーザー入力 | 末尾に配置されるため、毎ターン変化しても Segment 0 + Segment 1 の Prefix キャッシュを壊さない。 |

#### `CanonicalAssistantTurn` とモデル間射影（State Spill 防止 4 原則）
[llm_providers_and_cache.md](../cheatsheet/llm_providers_and_cache.md) §4 で特定されたモデル切替時の `400 Bad Request` 要因を、ドライバ射影層（`CanonicalIrProjector`）で以下の通り決定論的に吸収する：

1. **`tool_call_id` の 9 文字英数字決定論的正規化（`[a-zA-Z0-9]{9}`）**:
   - Canonical IR 内部では一意な `canonicalCallId`（例: `sc_0001`）を保持する。
   - 任意の LLM ドライバへ射影する際、`SHA-256("<sessionId>:<canonicalCallId>")` の先頭バイト列を Base62（`0-9a-zA-Z`）へエンコードした **固定 9 文字英数字 ID** を生成し、`assistant` メッセージの `tool_calls[].id` と対応する `tool` 結果メッセージの `tool_call_id` の双方に同一値を射影する。これにより Mistral 系の厳格な `[a-zA-Z0-9]{9}` 制約を含む全プロバイダ間で 100% 互換となる。
2. **Thinking 署名・推論詳細の条件付きエコーバック／剥離**:
   - `CanonicalAssistantTurn` は `originProvider`、`originModel`、平文 `thoughtText`（任意）、および生メタデータ `rawReasoningDetails`（OpenRouter `reasoning_details` / `thought_signature` 等、任意）を保持する。
   - 次回推論の `(targetProvider, targetModel)` が `(originProvider, originModel)` と **完全一致する場合のみ** `rawReasoningDetails`（または Ollama の `thinking` フィールド）をそのまま復元射影する。
   - **プロバイダまたはモデルが切り替わった場合** は暗号化署名を含む `rawReasoningDetails` を完全に剥離し、互換エラーを防止する。
3. **空 `content` と System ロール位置の正規化**:
   - Tool Call のみを返し本文テキストがない `CanonicalAssistantTurn` は、`content: ""`（空文字列）へ正規化する。
   - `role: "system"` は先頭 Segment 0 の単一メッセージのみとし、会話途中には挿入しない。
4. **切替タイミング**: `[D-002]` §2.1(2) の通り、ユーザー入力ターン境界でモデルを確定し、Tool Call ループ途中での別モデル混在を行わない。

---

### 2.2 `LlmDriver` 抽象と `OllamaDriver`（Local / Cloud ネイティブ `/api/chat`）

D-008: LlmDriver 抽象と OllamaDriver（Local / Cloud ネイティブ /api/chat 対応）

対応要求: `REQ-03`, `REQ-04`（関連判断: `OM-06`, `OM-07`）

#### 配置パス
- `packages/agent_kernel/lib/src/llm_driver.dart`（抽象 IF `LlmDriver`, `LlmChatRequest`, `LlmStreamEvent`, `LlmChatResponse`, `LlmUsageTelemetry`）
- `packages/agent_drivers/lib/src/llm/ollama_driver.dart`（`OllamaDriver`：Local / Cloud 共通ネイティブ `/api/chat` 実装）

#### 採用仕様とワイヤ変換契約
`PT-01` 実測（[llm_providers_and_cache.md](../cheatsheet/llm_providers_and_cache.md) §1.2）により、Ollama の OpenAI 互換 `/v1/chat/completions` は `stream: true` 時に `cached_tokens` が常に `0` になるため、`OllamaDriver` は **ネイティブ `POST <baseUrl>/api/chat`（NDJSON ストリーム）** を採用する。

| プロバイダ ID | 既定 Base URL | 認証ヘッダ | 固有処理 |
| :--- | :--- | :--- | :--- |
| `local-ollama` | `http://localhost:11434` | 不要 | 環境変数 `OLLAMA_HOST` を参照する場合、`0.0.0.0` または `[::]` はサーバー待受用アドレスのため接続先ホストとしては **`127.0.0.1`（または `localhost`）へ正規化** する（明示設定値があればそちらを優先）。リクエストに `"keep_alive": "15m"`（設定変更可）を付与し KV キャッシュの VRAM アンロードを抑止する。 |
| `ollama-cloud` | `https://ollama.com` | `Authorization: Bearer <OLLAMA_API_KEY>` | 環境変数 `OLLAMA_API_KEY` 未設定または空文字時は通信前に `SyscallErrorCode.eprovider`（`reason: "MISSING_API_KEY"`, 設定変数名のみ通知）を返す。 |

- **リクエスト変換（Canonical IR → Ollama `/api/chat`）**:
  - `messages`: `assistant` の `tool_calls[].function.arguments` は JSON 文字列ではなく **JSON Object (`Map<String, dynamic>`)** として渡す。
  - `role: "tool"` メッセージには `"role": "tool"`, `"tool_name": "<syscallName>"`, `"tool_call_id": "<id9>"`, `"content": "<string>"` を設定する。
  - `"stream": true` を基本とし、テスト等で非ストリーム指定時も同一パーサで処理可能とする。
- **NDJSON ストリーム受信とキャッシュ統計抽出**:
  - レスポンスを UTF-8 行単位（`\n` 区切り）で読み取り、`message.thinking` → `LlmThoughtDelta`、`message.content` → `LlmTextDelta`、`message.tool_calls` → `LlmToolCallSpec` としてリアルタイム送出する（Step 1-3 の ACP `session/update` `[D-019]` へ直結）。
  - 最終チャンク（`"done": true`）から以下を抽出する：
    - `promptTokens = json['prompt_eval_count'] as int? ?? 0`
    - `completionTokens = json['eval_count'] as int? ?? 0`
    - `cachedTokens = json['prompt_eval_cached_count'] as int?`（キー未存在時は `null` として記録：`OM-06`）
    - 初回チャンク到着時刻から `ttftMs`、完了時刻から `durationMs` を計測する。

---

### 2.3 `OpenRouterDriver`（Sticky Routing・Claude `cache_control`・Usage 抽出）

D-009: OpenRouterDriver（Sticky Routing・Claude cache_control 自動射影・Usage 抽出）

対応要求: `REQ-03`, `REQ-04`（関連判断: `OM-06`, `OM-07`）

#### 配置パス
- `packages/agent_drivers/lib/src/llm/openrouter_driver.dart`

#### エンドポイント・認証・キャッシュ最適化仕様
1. **接続先と認証**:
   - `POST https://openrouter.ai/api/v1/chat/completions`
   - 環境変数 `OPENROUTER_API_KEY` から Bearer トークンを取得し、未設定・空文字時は通信前に `SyscallErrorCode.eprovider`（`reason: "MISSING_API_KEY"`）を返す。
2. **Provider Sticky Routing（KV キャッシュヒット率最大化）**:
   - セッション生成時に発行した固定 UUID `sessionUuid` を、HTTP ヘッダ **`x-session-id: <sessionUuid>`** およびリクエスト JSON ボディ **`"session_id": "<sessionUuid>"`** の双方に付与し、同一バックエンドエンドポイントへの 60 分固定ルーティングを有効化する。
3. **Anthropic Claude 系モデルへの `cache_control` 自動射影**:
   - `modelName` が `"anthropic/"` で始まる場合のみ、Canonical IR 本体は変更せずワイヤ射影時のみ以下の最大 2 箇所（上限 4 箇所以下）へ `"cache_control": {"type": "ephemeral"}` を付与する：
     1. Segment 0（Pinned System メッセージ）のテキストブロック末尾。
     2. Segment 1（Append-Only 履歴）が空でない場合、その最終メッセージの末尾コンテンツブロック。
   - OpenAI / Gemini / DeepSeek 等の暗黙的 Prefix キャッシュ対応モデルでは余分なマークアップを付与しない。
4. **SSE ストリーム解析と Usage / コスト抽出**:
   - リクエストに `"stream": true`, `"stream_options": {"include_usage": true}` を指定する。
   - `data: ` プレフィックス付きの SSE 行を順次パースし（`data: [DONE]` で終了）、分割到着する `delta.tool_calls[index].function.arguments`（JSON 文字列断片）を `index` 単位のバッファで結合してから JSON パースする。
   - 最終 `usage` チャンクから以下を抽出する：
     - `promptTokens = usage['prompt_tokens']`
     - `completionTokens = usage['completion_tokens']`
     - `cachedTokens = usage['prompt_tokens_details']?['cached_tokens'] as int?`
     - `cacheWriteTokens = usage['prompt_tokens_details']?['cache_write_tokens'] as int?`
     - `costMicroUsd = usage['cost'] != null ? ((usage['cost'] as num) * 1000000).round() : null`
     - `cacheDiscountUsd = (usage['cache_discount'] as num?)?.toDouble()`（初回キャッシュ書込時は負値を取りうるため符号付き数値のまま保持）
5. **通信異常系の扱い**:
   - HTTP 4xx/5xx、JSON パース失敗、ソケット切断、タイムアウトはすべて捕捉し、`SecretRedactor` `[D-004]` を通した安全なメッセージとともに `SyscallErrorCode.eprovider` または `etimedout` として返す。

---

## 3. システムコール監査ログと LLM キャッシュ監視ログ（`REQ-04`）

D-010: システムコール監査ログ（syscalls.jsonl）と LLM キャッシュ監視ログ（llm_io.jsonl）

対応要求: `REQ-04`（パイプライン位置: `[D-002]` Stage 8, 隔離規則: `[D-003]`, 秘密保護: `[D-004]`）

#### 配置パスと出力先ファイル
- 実装: `packages/agent_kernel/lib/src/audit_logger.dart` (`AuditLogger`, `SecretRedactor`)
- 保存先ディレクトリ: `/workspace/.agent_os/logs/<sessionId>/`
  - システムコール監査: `syscalls.jsonl`（UTF-8、1 呼び出し 1 行 JSON）
  - LLM 入出力・キャッシュ監視: `llm_io.jsonl`（UTF-8、1 推論リクエスト 1 行 JSON）

### 3.1 `syscalls.jsonl` レコードスキーマ
許可・拒否（`EACCES`）・Hook 遮断（`HOOK_BLOCKED`）・引数不正（`EINVAL`）・タイムアウト（`ETIMEDOUT`）・キャンセルを含む**全システムコール**について、実行完了時点の `jjChangeId` / `jjOpId` を添えて出力する。

```json
{
  "seq": 12,
  "timestamp": "2026-11-19T15:40:01.234Z",
  "sessionId": "sess_01",
  "pid": 1,
  "ring": "ring2",
  "syscallName": "sys_edit_block",
  "argsSummary": {
    "path": "/workspace/lib/foo.dart",
    "expectedSha256": "9f86d081..."
  },
  "approvalRequired": false,
  "decision": "ALLOWED",
  "ok": true,
  "errorCode": null,
  "errorReason": null,
  "truncated": false,
  "durationMs": 18,
  "jjChangeId": "vnzyzqllrmrm",
  "jjOpId": "de3a916ace23..."
}
```
- `decision` の値域: `"ALLOWED"` | `"APPROVED_BY_USER"` | `"DENIED_BY_POLICY"` | `"DENIED_BY_USER"` | `"HOOK_BLOCKED"` | `"INVALID_ARGS"` | `"QUOTA_EXCEEDED"`.
- `jjOpId` は `JjDriver` が保持・取得した 128 文字 hex フル Operation ID（または `jj op log` で一意解決できる実在 ID）とし、`jj --at-op <jjOpId>` で当時のリポジトリ断面と突合可能であることを保証する（`jj` 管理外エラー時のみ `null`）。

### 3.2 `llm_io.jsonl` レコードスキーマ
3 プロバイダすべての `sys_llm_chat` 実行ごとに以下の構造化レコードを出力する（`Authorization` ヘッダや API キー環境変数値を絶対に含めない）。

```json
{
  "seq": 3,
  "turnIndex": 2,
  "timestamp": "2026-11-19T15:40:05.678Z",
  "sessionId": "sess_01",
  "provider": "local-ollama",
  "model": "gemma4:12b",
  "endpoint": "http://localhost:11434/api/chat",
  "ok": true,
  "errorCode": null,
  "promptTokens": 1420,
  "completionTokens": 95,
  "totalTokens": 1515,
  "cachedTokens": 1280,
  "cacheWriteTokens": null,
  "cacheHitRate": 0.9014,
  "costMicroUsd": null,
  "ttftMs": 145,
  "durationMs": 1820,
  "toolCallsCount": 1,
  "requestDebug": { "messageCount": 6, "toolsCount": 11, "messagesPreview": "[...]" },
  "responseDebug": { "finishReason": "tool_calls", "thoughtChars": 120, "textChars": 0 }
}
```
- `cacheHitRate`: `cachedTokens != null && promptTokens > 0` のとき `cachedTokens / promptTokens`（小数第 4 位丸め）、それ以外は `null`。

---

## 4. 対象 REQ との確認・検証マッピング（`tester` 引き渡し情報）

| REQ | 対象設計ID | 検証種別と必須確認シナリオ |
| :--- | :--- | :--- |
| **`REQ-01`** | `[D-001]`, `[D-002]`, `[D-004]`, `[D-005]`, `[D-006]` | - **`E3`**: `packages/agent_kernel/pubspec.yaml` と `lib/` に HTTP / FFI / 具象 LLM / ACP 依存が存在しないこと。<br>- **`E1`**: `IoPayloadCapper` 単体テスト（`maxLines` 未満・ちょうど・1万行超過・1行超長バイト超過）、`maxChildProcesses=0` ロックテスト。<br>- **`E2`**: 1万行超のファイル読取と数千件ヒットする `sys_grep` を含む質問を実行し、キャップサマリ返却後にエージェントが範囲指定で調査を継続完走できること。 |
| **`REQ-03`** | `[D-002]`, `[D-004]`, `[D-007]`, `[D-008]`, `[D-009]` | - **`E1`**: Canonical IR 射影単体テスト（`[a-zA-Z0-9]{9}` ペア変換、モデル切替時の `rawReasoningDetails` 剥離、Claude `cache_control` 射影、`OLLAMA_HOST=0.0.0.0` 正規化、API キー未設定時 `EPROVIDER`、秘密文字列マスク）。<br>- **`E2`**: `local-ollama`・`openrouter`・`ollama-cloud` の 3 プロバイダ実機すべてで Tool Call 往復が成功し、かつ同一セッション内で `local-ollama` → `openrouter` → `local-ollama`（＋`ollama-cloud`）へ毎ターン切り替えても `400 Bad Request` なく文脈を引き継いで応答できること（※前提 `P-2` の API キー設定後に実施）。 |
| **`REQ-04`** | `[D-002]`, `[D-003]`, `[D-004]`, `[D-010]` | - **`E1`**: 許可・拒否・Hook遮断・例外の全経路で `syscalls.jsonl` に出力され、`SecretRedactor` が Bearer キーを `"<REDACTED>"` 化することの自動テスト。<br>- **`E2`**: 実機実行後の `syscalls.jsonl` 内の `jjOpId` が `jj op log` の実在 ID と一致すること、およびキャッシュ統計返却対応プロバイダ／モデルでの同一モデル連続ターン対話（十分な長さの固定 Prefix 条件）において 1 ターン目より 2 ターン目以降で `llm_io.jsonl` の `cachedTokens` / `cacheHitRate` が上昇すること。 |
