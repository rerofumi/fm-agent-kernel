# Cheatsheet Links — 外部一次資料・出典台帳

すべての URL は記載の確認日（`2026-11-19`〜`2026-11-21`）時点で最終到達先（HTTP `200 OK`）を実確認済みの正規 URL である。ローカル実測のみの項目には架空 URL を付与せず、各トピック本文にコマンドと観測結果を記録している。

## 1. Dart SDK・Pub Workspaces・Windows FFI

| 出典 URL | 出典種別 | 確認日 | 関連ローカル資料 | 参照理由 |
| --- | --- | :---: | --- | --- |
| https://dart.dev/tools/pub/workspaces | 公式ドキュメント | `2026-11-19` | [env_and_dart_windows.md](./env_and_dart_windows.md) | Pub Workspaces の最小 SDK バージョン（`^3.6.0`）および `workspace:` / `resolution: workspace` 記法の確認 |
| https://dart.dev/tools/dart-compile | 公式ドキュメント | `2026-11-19` | [env_and_dart_windows.md](./env_and_dart_windows.md) | Windows での `dart compile exe` の単一バイナリ生成仕様・Build Hooks / `dart:mirrors` 制約の確認 |
| https://pub.dev/packages/win32 | 公式パッケージ仕様 | `2026-11-19` | [env_and_dart_windows.md](./env_and_dart_windows.md) | `package:win32` の対応 Dart SDK 要件および Win32 Job Object API バインディング有無の確認 |
| https://pub.dev/packages/ffi | 公式パッケージ仕様 | `2026-11-19` | [env_and_dart_windows.md](./env_and_dart_windows.md) | `calloc` / ネイティブ構造体メモリ確保・解放（`package:ffi`）の確認 |
| https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects | OS 公式仕様 | `2026-11-19` | [env_and_dart_windows.md](./env_and_dart_windows.md) | Windows Job Object の親子プロセス継承・Nested Jobs 仕様の確認 |
| https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information | OS 公式仕様 | `2026-11-19` | [env_and_dart_windows.md](./env_and_dart_windows.md) | `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` 構造体と `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (`0x2000`) の定義確認 |
| https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject | OS 公式仕様 | `2026-11-19` | [env_and_dart_windows.md](./env_and_dart_windows.md) | `AssignProcessToJobObject` に必要なプロセスハンドルアクセス権（`PROCESS_SET_QUOTA \| PROCESS_TERMINATE`）と解除不可制約の確認 |

## 2. Jujutsu (`jj`)

| 出典 URL | 出典種別 | 確認日 | 関連ローカル資料 | 参照理由 |
| --- | --- | :---: | --- | --- |
| https://docs.jj-vcs.dev/latest/cli-reference/ | 公式ドキュメント | `2026-11-19` | [jujutsu_cli_046.md](./jujutsu_cli_046.md) | `jj` CLI サブコマンド・グローバルオプション（`--ignore-working-copy`, `--at-op`）の仕様照合 |
| https://docs.jj-vcs.dev/latest/templates/ | 公式ドキュメント | `2026-11-19` | [jujutsu_cli_046.md](./jujutsu_cli_046.md) | `-T` テンプレート言語の `Commit` / `Operation` メソッドおよび `json(...)` シリアライズ仕様の確認 |
| https://docs.jj-vcs.dev/latest/git-compatibility/ | 公式ドキュメント | `2026-11-19` | [jujutsu_cli_046.md](./jujutsu_cli_046.md) | `jj git init` における Colocated / Non-colocated ワークスペースの挙動差の確認 |

## 3. LLM プロバイダ（Ollama / Ollama Cloud / OpenRouter）

| 出典 URL | 出典種別 | 確認日 | 関連ローカル資料 | 参照理由 |
| --- | --- | :---: | --- | --- |
| https://docs.ollama.com/api/introduction | 公式ドキュメント | `2026-11-19` | [llm_providers_and_cache.md](./llm_providers_and_cache.md) | Ollama ネイティブ `/api/chat` のリクエスト・NDJSON ストリーム・`prompt_eval_count` / `prompt_eval_cached_count` 仕様の確認 |
| https://docs.ollama.com/cloud | 公式ドキュメント | `2026-11-19` | [llm_providers_and_cache.md](./llm_providers_and_cache.md) | Ollama Cloud エンドポイント（`https://ollama.com/api/chat`, `https://ollama.com/v1`）と `OLLAMA_API_KEY` Bearer 認証の確認 |
| https://docs.ollama.com/api/openai-compatibility | 公式ドキュメント | `2026-11-19` | [llm_providers_and_cache.md](./llm_providers_and_cache.md) | Ollama `/v1/chat/completions` の対応パラメータ（`tools`, `stream_options`）の確認 |
| https://docs.ollama.com/capabilities/tool-calling | 公式ドキュメント | `2026-11-19` | [llm_providers_and_cache.md](./llm_providers_and_cache.md) | Ollama における Tool Calling（ストリーミング併用・`role: "tool"` 応答形式）の確認 |
| https://openrouter.ai/docs/guides/best-practices/prompt-caching | 公式ドキュメント | `2026-11-19` | [llm_providers_and_cache.md](./llm_providers_and_cache.md) | OpenRouter の Prompt Caching、Provider Sticky Routing（`session_id` / `x-session-id`）、Anthropic `cache_control` 要否の確認 |
| https://openrouter.ai/docs/cookbook/administration/usage-accounting | 公式ドキュメント | `2026-11-19` | [llm_providers_and_cache.md](./llm_providers_and_cache.md) | OpenRouter `usage` オブジェクト（`cached_tokens`, `cache_write_tokens`, `cache_discount`, `cost`）の自動返却仕様確認 |
| https://openrouter.ai/docs/guides/best-practices/reasoning-tokens | 公式ドキュメント | `2026-11-19` | [llm_providers_and_cache.md](./llm_providers_and_cache.md) | Gemini 3 `thought_signature` / Anthropic Thinking 等の `reasoning_details` 保存要件とモデル切替時の扱い確認 |

## 4. ACP (Agent Client Protocol)

| 出典 URL | 出典種別 | 確認日 | 関連ローカル資料 | 参照理由 |
| --- | --- | :---: | --- | --- |
| https://agentclientprotocol.com/protocol/v1/overview | 公式プロトコル仕様 | `2026-11-19` | [acp_protocol.md](./acp_protocol.md) | ACP v1 の全体アーキテクチャ・JSON-RPC 2.0 over `stdio` 仕様の確認 |
| https://agentclientprotocol.com/protocol/v1/initialization | 公式プロトコル仕様 | `2026-11-19` | [acp_protocol.md](./acp_protocol.md) | `initialize` ハンドシェイクと `protocolVersion: 1`・Capabilities 交渉の確認 |
| https://agentclientprotocol.com/protocol/v1/session-setup | 公式プロトコル仕様 | `2026-11-19` | [acp_protocol.md](./acp_protocol.md) | `session/new` パラメータ（`cwd`, `mcpServers`）および `sessionId` 発行仕様の確認 |
| https://agentclientprotocol.com/protocol/v1/prompt-turn | 公式プロトコル仕様 | `2026-11-19` | [acp_protocol.md](./acp_protocol.md) | `session/prompt`, `session/update` ストリーム通知、`session/cancel`, `stopReason` の確認 |
| https://agentclientprotocol.com/protocol/v1/tool-calls | 公式プロトコル仕様 | `2026-11-19` | [acp_protocol.md](./acp_protocol.md) | `tool_call` / `tool_call_update`、`diff` コンテンツ、`session/request_permission` の入出力スキーマ確認 |
| https://agentclientprotocol.com/protocol/v1/session-config-options | 公式プロトコル仕様 | `2026-11-19` | [acp_protocol.md](./acp_protocol.md) | `session/set_config_option`（予約カテゴリ `model`, `mode` 等）による標準モデル切替方式の確認 |
| https://agentclientprotocol.com/protocol/v1/extensibility | 公式プロトコル仕様 | `2026-11-19` | [acp_protocol.md](./acp_protocol.md) | `_meta` 拡張オブジェクトと `_` プレフィックス独自メソッドの厳格な互換性規則の確認 |

## 5. Stage 2：Dart `Isolate`・コンテキスト窓メタデータ・Web Search / SSRF・`SKILL.md`

| 出典 URL | 出典種別 | 確認日 | 関連ローカル資料 | 参照理由 |
| --- | --- | :---: | --- | --- |
| https://api.dart.dev/dart-isolate/Isolate/spawn.html | 公式 API リファレンス | `2026-11-19` | [dart_isolate_and_context_paging.md](./dart_isolate_and_context_paging.md) | AOT (`dart compile exe`) で利用可能な `Isolate.spawn`、`onError` / `onExit`、`errorsAreFatal` 仕様の確認 |
| https://api.dart.dev/dart-isolate/TransferableTypedData-class.html | 公式 API リファレンス | `2026-11-19` | [dart_isolate_and_context_paging.md](./dart_isolate_and_context_paging.md) | Isolate 間での大容量バイト列の O(1) 所有権移転仕様の確認 |
| https://api.dart.dev/dart-async/ZoneSpecification-class.html | 公式 API リファレンス | `2026-11-19` | [dart_isolate_and_context_paging.md](./dart_isolate_and_context_paging.md) | `print` 捕捉用 `ZoneSpecification` と、新規生成 `Isolate` が独立 Root Zone を持つ仕様の確認 |
| https://docs.ollama.com/context-length | 公式ドキュメント | `2026-11-19` | [dart_isolate_and_context_paging.md](./dart_isolate_and_context_paging.md) | Ollama の VRAM 容量別既定コンテキスト長（4k / 32k / 256k）、`OLLAMA_CONTEXT_LENGTH`、実効窓確認方法の確認 |
| https://github.com/ollama/ollama/blob/main/docs/api.md | 公式 API 仕様 | `2026-11-19` | [dart_isolate_and_context_paging.md](./dart_isolate_and_context_paging.md) | Ollama `POST /api/show`（`model_info`, `parameters`）および `GET /api/ps`（`context_length`）のフィールド仕様確認 |
| https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties | 公式 API 仕様 | `2026-11-19` | [dart_isolate_and_context_paging.md](./dart_isolate_and_context_paging.md) | OpenRouter `GET /api/v1/models` の `context_length` および `top_provider.max_completion_tokens` スキーマ確認 |
| https://openrouter.ai/docs/guides/overview/models | 公式ドキュメント | `2026-11-19` | [dart_isolate_and_context_paging.md](./dart_isolate_and_context_paging.md) | OpenRouter モデルカタログおよびコンテキスト上限の扱い確認 |
| https://docs.ollama.com/capabilities/web-search | 公式ドキュメント | `2026-11-19` | [web_research_ssrf_and_skills.md](./web_research_ssrf_and_skills.md) | Ollama 公式 `POST https://ollama.com/api/web_search` / `POST https://ollama.com/api/web_fetch` と `OLLAMA_API_KEY` Bearer 認証仕様の確認 |
| https://api-dashboard.search.brave.com/app/documentation/web-search/get-started | 公式ドキュメント | `2026-11-19` | [web_research_ssrf_and_skills.md](./web_research_ssrf_and_skills.md) | 代替候補 Brave Search API のエンドポイントと `X-Subscription-Token` 認証要件の確認 |
| https://docs.tavily.com/documentation/api-reference/endpoint/search | 公式 API 仕様 | `2026-11-19` | [web_research_ssrf_and_skills.md](./web_research_ssrf_and_skills.md) | 代替候補 Tavily Search API のエンドポイントと Bearer 認証要件の確認 |
| https://api.dart.dev/dart-io/HttpClient/connectionFactory.html | 公式 API リファレンス | `2026-11-19` | [web_research_ssrf_and_skills.md](./web_research_ssrf_and_skills.md) | `HttpClient.connectionFactory` による検証済み公開 IP ピン留め（DNS Rebinding 防止）仕様の確認 |
| https://api.dart.dev/dart-io/SecureSocket/secure.html | 公式 API リファレンス | `2026-11-19` | [web_research_ssrf_and_skills.md](./web_research_ssrf_and_skills.md) | 検証済み IP への生 TCP ソケット上で元ホスト名の TLS SNI・X.509 証明書検証を維持する `SecureSocket.secure` 仕様の確認 |
| https://pub.dev/packages/yaml | 公式パッケージ仕様 | `2026-11-19` | [web_research_ssrf_and_skills.md](./web_research_ssrf_and_skills.md) | `SKILL.md` フロントマター解析用 pure-Dart `package:yaml` の仕様確認 |
| https://pub.dev/packages/html | 公式パッケージ仕様 | `2026-11-19` | [web_research_ssrf_and_skills.md](./web_research_ssrf_and_skills.md) | HTML5 DOM 解析・ノイズ要素除去用 pure-Dart `package:html` の仕様確認 |
| https://pub.dev/packages/html2md | パッケージ仕様 | `2026-11-19` | [web_research_ssrf_and_skills.md](./web_research_ssrf_and_skills.md) | pure-Dart HTML→Markdown 変換ライブラリの仕様・オプション確認 |

## 6. Stage 3：Jujutsu (`jj`) 複数ワークスペース・競合解消・MCP (Model Context Protocol)

| 出典 URL | 出典種別 | 確認日 | 関連ローカル資料 | 参照理由 |
| --- | --- | :---: | --- | --- |
| https://docs.jj-vcs.dev/latest/working-copy/ | 公式ドキュメント | `2026-11-20` | [jj_workspace_merge_and_stacked.md](./jj_workspace_merge_and_stacked.md) | `jj workspace` の複数ワーキングコピー構造および `stale working copy` / `update-stale` 仕様の確認 |
| https://docs.jj-vcs.dev/latest/conflicts/ | 公式ドキュメント | `2026-11-20` | [jj_workspace_merge_and_stacked.md](./jj_workspace_merge_and_stacked.md) | First-Class Conflicts の木構造保持・コンフリクトマーカー形式・競合解消フロー仕様の確認 |
| https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle | 公式プロトコル仕様 | `2026-11-20` | [mcp_and_supervisor_signals.md](./mcp_and_supervisor_signals.md) | MCP ハンドシェイク（`initialize` → `notifications/initialized`）・バージョン交渉・終了規則の確認 |
| https://modelcontextprotocol.io/specification/2025-11-25/basic/transports | 公式プロトコル仕様 | `2026-11-20` | [mcp_and_supervisor_signals.md](./mcp_and_supervisor_signals.md) | MCP `stdio`（UTF-8 NDJSON）および `Streamable HTTP`（`MCP-Protocol-Version` / `Mcp-Session-Id` / SSE）仕様の確認 |
| https://modelcontextprotocol.io/specification/2025-11-25/server/tools | 公式プロトコル仕様 | `2026-11-20` | [mcp_and_supervisor_signals.md](./mcp_and_supervisor_signals.md) | MCP `tools/list`（`cursor` ページネーション）および `tools/call`（`CallToolResult` / `isError`）スキーマの確認 |
| https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning | 公式プロトコル仕様 | `2026-11-20` | [mcp_and_supervisor_signals.md](./mcp_and_supervisor_signals.md) | MCP Modern (`2026-07-28`) と Legacy (`2025-11-25` 以前) の Dual-era 互換性マトリクス確認 |
| https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio | 公式プロトコル仕様 | `2026-11-20` | [mcp_and_supervisor_signals.md](./mcp_and_supervisor_signals.md) | Windows での `stdio` MCP サーバー終了手順（`stdin` EOF + Win32 Job Objects / `TerminateProcess`）の確認 |

## 7. 新規 LLM プロバイダ（OpenAI / Google AI Studio / Nous Portal / llama.cpp / Strata）

| 出典 URL | 出典種別 | 確認日 | 関連ローカル資料 | 参照理由 |
| --- | --- | :---: | --- | --- |
| https://platform.openai.com/docs/api-reference/chat | 公式 API リファレンス | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | OpenAI `POST /v1/chat/completions`、`stream_options.include_usage`、`max_completion_tokens` 仕様の確認 |
| https://platform.openai.com/docs/api-reference/models | 公式 API リファレンス | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | OpenAI `GET /v1/models` のレスポンススキーマ（capability フィールドなし・非チャットモデル混在）の確認 |
| https://platform.openai.com/docs/guides/reasoning | 公式ドキュメント | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | Reasoning モデル（o1/o3/gpt-5 等）の `max_completion_tokens`, `temperature`, `reasoning_effort`, `developer` ロール制約の確認 |
| https://platform.openai.com/docs/guides/prompt-caching | 公式ドキュメント | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | OpenAI 自動 Prefix キャッシュと `usage.prompt_tokens_details.cached_tokens` の仕様確認 |
| https://ai.google.dev/api/generate-content | 公式 API リファレンス | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | Gemini ネイティブ REST `:streamGenerateContent?alt=sse`、`x-goog-api-key` ヘッダ、Tool Calling 仕様の確認 |
| https://ai.google.dev/api/models | 公式 API リファレンス | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | Gemini `GET /v1beta/models` の `inputTokenLimit`, `outputTokenLimit`, `supportedGenerationMethods` 仕様確認 |
| https://ai.google.dev/gemini-api/docs/openai | 公式ドキュメント | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | Gemini OpenAI 互換エンドポイント（`/v1beta/openai/`）、Bearer 認証、`extra_content` / `cached_tokens` 挙動の確認 |
| https://ai.google.dev/gemini-api/docs/thought-signatures | 公式ドキュメント | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | `thoughtSignature`（ネイティブ）および `extra_content.google.thought_signature`（OpenAI 互換）のマルチターン必須エコーバック要件の確認 |
| https://ai.google.dev/gemini-api/docs/caching | 公式ドキュメント | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | Gemini 暗黙的・明示的コンテキストキャッシュと `usageMetadata.cachedContentTokenCount` の確認 |
| https://portal.nousresearch.com/ | 公式ポータル | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | Nous Research Portal（API キー発行、`inference-api.nousresearch.com/v1` の起点）の確認 |
| https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md | 公式ドキュメント | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | `llama-server` の `/v1/models` (`meta.n_ctx_train`)、`/props` (`default_generation_settings.n_ctx`)、`timings.cache_n` / `cached_tokens` 仕様の確認 |
| https://stratallm.org/ | 公式ドキュメント | `2026-11-21` | [llm_providers_extended.md](./llm_providers_extended.md) | Strata ローカル LLM サーバーの既定 URL（`http://127.0.0.1:8080/v1`）、OpenAI / Anthropic 互換エンドポイント、ダミー API キー接続の確認 |
