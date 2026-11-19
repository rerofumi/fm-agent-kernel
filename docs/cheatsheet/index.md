# Cheatsheet Index — 技術・環境調査および実測リファレンス

本ディレクトリは、設計・実装・検証の各担当が同じ外部仕様調査やローカル環境確認・試行錯誤を繰り返さずに済むよう、確認日・対象版・実測根拠・利用条件・未確認事項を整理した参照資料群である（製品要求や採用判断そのものは各プランの正本を参照すること）。

| トピック | 対象技術・版 | 確認日 | 知識の種類 | 読む場面 | 本文リンク |
| --- | --- | :---: | --- | --- | --- |
| Windows 11 環境・Dart SDK・Win32 Job Object FFI | Windows 11 (`26300`), Dart SDK (`^3.6.0` / `3.13.7`), `dart:ffi` / `package:win32`, `kernel32.dll` | `2026-11-19` | ローカル実測 + 外部一次資料 + 経験則 | 環境構築、Pub Workspaces 構成、`dart compile exe` 制約確認、`sys_exec` の Job Object 子孫プロセス強制終了 FFI 実装時 | [env_and_dart_windows.md](./env_and_dart_windows.md) |
| Jujutsu (`jj`) CLI・テンプレート・トランザクション制御 | `jj 0.46.0` (`7d382314f942`) | `2026-11-19` | ローカル隔離実測 + 外部一次資料 | `JjDriver` の初期化（`jj git init` 既定 colocated）、`--ignore-working-copy` / `--at-op`、JSON Lines パーステンプレート、非対話 `squash -u`・`op restore` 実装時 | [jujutsu_cli_046.md](./jujutsu_cli_046.md) |
| 3 LLM プロバイダ・KV キャッシュ監視・モデル切替互換性 | Local Ollama (`0.40.16` 実測), Ollama Cloud, OpenRouter API v1 | `2026-11-19` | ローカル＆クラウド実機 API 実測 + 外部一次資料 | `LlmDriver`（`/api/chat` vs `/v1/chat/completions` のキャッシュ統計差、`OllamaDriver` `/v1` 正規化）、OpenRouter Sticky Routing / `cache_control`、Canonical IR モデル切替射影の設計・実装・運用時 | [llm_providers_and_cache.md](./llm_providers_and_cache.md) |
| ACP (Agent Client Protocol) v1 仕様と拡張境界 | ACP v1 (`protocolVersion: 1`, JSON-RPC 2.0 over `stdio`) | `2026-11-19` | 外部一次資料 + 設計境界整理 | Step 1-3 の ACP サーバー、`session/request_permission` 承認ゲート、`session/set_config_option` モデル切替、`_meta` テレメトリ拡張、`acp_cli_client` 実装時 | [acp_protocol.md](./acp_protocol.md) |
| Dart 3.14 AOT `Isolate` 境界・`stdout` 純度・コンテキストページング | Dart SDK `3.14.1` (`dart compile exe`), `jj 0.46.0`, Ollama (`0.40.16` / Cloud), OpenRouter API v1 | `2026-11-19` | ローカル AOT 実測 + 実機 API 実測 + 外部一次資料 | Stage 2 Step 2-1/2-2 の `Isolate.spawn` 子プロセス・Zone 非継承 `print` 汚染防止、モデル別実効コンテキスト窓取得（`/api/ps` vs `/api/show`）、UTF-8 トークン推定、Clean Page `[STALE]` 判定設計・実装時 | [dart_isolate_and_context_paging.md](./dart_isolate_and_context_paging.md) |
| Web 調査ドライバ・`dart:io` SSRF 完全遮断・HTML 抽出・`SKILL.md` | Ollama Web Search API, `dart:io` (`HttpClient` / `SecureSocket`), `package:yaml` (`3.1.4`), `package:html` (`0.15.7`) | `2026-11-19` | 実機 API 実測 + ローカル AOT 実測 + 外部一次資料 | Stage 2 Step 2-3 の `sys_web_search`（既存 `OLLAMA_API_KEY` 対応）、`sys_web_fetch`（DNS Rebinding 防止・ローカル/LAN IP SSRF 遮断・Markdown 抽出）、無菌室 `WebResearcher`、`SKILL.md` フロントマター実装時 | [web_research_ssrf_and_skills.md](./web_research_ssrf_and_skills.md) |

## 関連索引
- 外部一次資料 URL 台帳: [link.md](./link.md)
