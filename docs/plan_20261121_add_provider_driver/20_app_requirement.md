# 20_app_requirement.md — 利用場面・代表操作・対象環境・範囲定義

関連文書:
- 背景・要望: [10_claim.md](./10_claim.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 利用者像と基本利用スタイル

開発者（利用者）は、Windows 上の作業リポジトリで `agent_os_daemon`（および `acp_cli_client` / Kanban UI）を起動し、環境変数または `.agent_os/.env` に各プロバイダの API キーやベース URL を設定したうえで、`.agent_os/models.json` による表示・利用モデルの制御と、プロンプト毎・セッション毎のモデル切替を行う。

---

## 2. 現行動作と変更後の比較・代表シナリオ

### 2.1 現行動作と変更後の対比

| 項目 | 現行動作（commit `72483b3`） | 変更後の期待動作 |
| :--- | :--- | :--- |
| **対応プロバイダ** | `local-ollama`, `ollama-cloud`, `openrouter` の 3 種のみ。 | 上記 3 種に加え、**`openai`**（OpenAI API）、**`gemini`**（Google AI Studio API）、**`nous-portal`**（Nous Portal）、**`openai-compat`**（OpenAI 互換 API: Local LLM 用）の計 7 プロバイダに対応。 |
| **起動時モデル一覧** | `AcpServer.defaultModelCatalog` の固定 6 モデルを常に返却。 | 有効なプロバイダから起動時に 1 回モデル一覧を取得してキャッシュし、ACP `session/new` / `configOptions`・CLI `/models`・Kanban へ反映。 |
| **API キー未設定プロバイダ** | 一覧には表示され、選択して推論すると `EPROVIDER` になる。 | `.agent_os/models.json` で `enable: true` 相当であっても API キー未設定時は `false` 扱いとなり、一覧に表示されず無効化される。 |
| **OpenRouter 等の多モデル制御** | 固定 2 モデルのみ表示（自動取得なし）。 | `.agent_os/models.json` で `autoFetch: false` + 手動リストを記載することで、指定モデルのみを表示・利用可能にできる。 |

### 2.2 代表的な利用場面と成功時の結果

| シナリオ | 代表的な入力・操作 | 操作前の状態 | 成功時の結果と操作後の状態 |
| :--- | :--- | :--- | :--- |
| **S-01: 新規 4 プロバイダでの推論・Tool Call・毎ターン切替** | 利用者が `acp_cli_client` または Kanban UI から `/model` 等で OpenAI / Google AI Studio / Nous Portal / OpenAI 互換 (Local LLM) のモデルへ切り替え、リポジトリ読解等のプロンプトを送信する。 | - 対象 API キーまたはローカル互換エンドポイントが設定済み。<br>- 同一セッションの Canonical IR に既存会話履歴がある。 | - 新規 4 プロバイダで Tool Call を含む推論が正常完了し、`llm_io.jsonl` に記録される（API キーは `SecretRedactor` により `<REDACTED>` 保護）。<br>- 既存 3 プロバイダと新規 4 プロバイダを跨いで毎ターン切り替えても State Spill（`400 Bad Request` 等）を起こさず文脈を引き継ぐ。 |
| **S-02: デフォルト状態での起動時 1 回取得＆キャッシュ** | `.agent_os/models.json` を置かない（または `autoFetch` 既定有効）状態で `agent_os_daemon` を起動し、`/models` や `session/new`（複数セッション含む）を実行する。 | - Local Ollama が起動済み（例: `gemma4:12b` 等を保持）。<br>- API キー未設定のクラウドプロバイダがある。 | - 起動時に 1 回だけ `/api/tags` 等からモデル一覧を取得してメモリキャッシュし、以降の `session/new` / `/models` では再フェッチせずキャッシュ結果を返す。<br>- API キー未設定プロバイダは `false` 扱いで一覧から除外される。 |
| **S-03: `.agent_os/models.json` による `enable` / `autoFetch: false` / 手動リスト運用** | 利用者が `.agent_os/models.json` に「OpenRouter は `enable: true`, `autoFetch: false`, 手動リスト 2 件」「特定プロバイダは `enable: false`」と記載し、起動して `/models` や `/model` を操作する。 | - `OPENROUTER_API_KEY` 設定済み。<br>- `.agent_os/models.json` が配置済み。 | - `enable: false` のプロバイダは API キー設定済みでも表示・利用されない。<br>- `autoFetch: false` の OpenRouter は外部 `/models` を取得せず、記載された 2 モデルのみが CLI `/models`・Kanban UI に表示されて利用でき、リスト外モデルの指定は `EINVAL` で拒否される。 |

---

## 3. 対象環境

| 項目 | 対象仕様・前提 |
| :--- | :--- |
| **ホスト OS** | Windows（既存と同一） |
| **言語・ビルド形態** | Dart SDK、最終的に `dart compile exe` による Windows ネイティブ実行ファイル（`agent_os_daemon.exe`, `acp_cli_client.exe`, `acp_kanban_app.exe` 等）で動作すること |
| **設定・秘密管理** | プロセス環境変数、`LlmEnvLoader`（`.agent_os/.env`）、`.agent_os/models.json`（いずれも VFS `PROTECTED_INTERNAL_PATH` によりエージェントからの直接読み書きを遮断） |
| **上位接続** | ACP (`stdio` JSON-RPC 2.0)、`acp_cli_client`、Kanban Web UI |

---

## 4. 今回の範囲と対象外

### 4.1 範囲内
- 4 新規 LLM プロバイダ（OpenAI API / Google AI Studio API / Nous Portal / OpenAI 互換 API）の識別子・ドライバ・ルータ・コンテキスト長解決・環境変数ロード対応。
- 起動時 1 回モデル一覧取得＆キャッシュ機構の実装と、`AcpServer`（`session/new`, `session/set_config_option`）・CLI・Kanban UI への統合。
- `.agent_os/models.json` パーサと設定反映（`enable`、API キー未設定時 `false` 扱い、自動取得フラグ、手動リスト）。
- 既存 3 プロバイダおよび Canonical IR・`SecretRedactor`・既存テストの回帰維持。

### 4.2 対象外（今回行わないこと）
- 実行中の定期自動ポーリングやファイルウォッチャによるモデル一覧の動的再取得（要望は「起動時に 1 回取得＆キャッシュ」）。
- 永続的なディスクキャッシュ（再起動を跨ぐモデル一覧キャッシュ）※起動時 1 回取得＆メモリキャッシュで要件を満たすため。
- 各プロバイダの推論パラメータ（温度や Reasoning Effort 等の個別高度な UI 設定追加）。
- 性能数値目標（応答秒数 SLO 等）や不要な品質水準の新設。
