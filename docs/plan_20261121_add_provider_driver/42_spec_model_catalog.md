# 42_spec_model_catalog.md — `.agent_os/models.json`・`ModelCatalogService`・ACP/CLI/Kanban 統合 詳細設計

関連文書:
- 全体仕様: [40_specification.md](./40_specification.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- プロバイダ・ドライバ設計: [42_spec_providers.md](./42_spec_providers.md)

---

## 1. `.agent_os/models.json` スキーマ・探索・VFS 保護

D-406: `.agent_os/models.json` スキーマ・探索優先順位・構文エラー／不在時フォールバック・VFS 保護（[REQ-03], [REQ-04]）

### 1.1 JSON スキーマ仕様

```json
{
  "providers": {
    "local-ollama": {
      "enable": true,
      "autoFetch": true,
      "models": ["gemma4:12b", "qwen3.8:27b"]
    },
    "openrouter": {
      "enable": true,
      "autoFetch": false,
      "models": [
        "anthropic/claude-sonnet-4",
        "openai/gpt-4.1"
      ]
    },
    "openai-compat": {
      "enable": true,
      "autoFetch": true,
      "baseUrl": "http://127.0.0.1:8080/v1",
      "models": []
    }
  }
}
```

| フィールド | 型 | 既定値 | 説明 |
| :--- | :--- | :--- | :--- |
| `providers` | `Map<String, Object>` | `{}` | キーは `LlmProviderId.id`（`local-ollama`, `ollama-cloud`, `openrouter`, `openai`, `gemini`, `nous-portal`, `openai-compat`）。 |
| `providers.<id>.enable` | `bool` | `true` | `false` の場合、API キー／URL 有無にかかわらず完全に無効化する。 |
| `providers.<id>.autoFetch` | `bool` | `true` | `false` の場合、起動時のモデル一覧 API 呼び出しを抑止し、`models` のみを許可する。 |
| `providers.<id>.models` | `List<String>` | `[]` | 手動モデルリスト。原則 `<modelName>` を記載する（例: OpenRouter では `"anthropic/claude-sonnet-4"`）。誤って `"<providerId>/<modelName>"` と記載された場合は、先頭が `${provider.id}/` に完全一致するときのみプレフィックスを除去して正規化する。 |
| `providers.<id>.baseUrl` | `String?` | `null` | 主に `openai-compat` のベース URL 指定用（他プロバイダでも任意上書き可）。 |

### 1.2 探索優先順位と異常系・VFS 保護

1. **探索優先順位（`B-04`）**:
   - 優先 1: `<sessionCwd>/.agent_os/models.json`（`sessionCwd` が非空かつファイルが存在する場合）
   - 優先 2: `<Directory.current>/.agent_os/models.json`（優先 1 が存在しない場合）
   - 不在時: 設定ファイルなしとして「全プロバイダ `enable: true`, `autoFetch: true`, `models: []`」の既定設定を返す。
2. **異常系（クラッシュ防止）**:
   - JSON 構文エラー・ルートがオブジェクトでない・`providers` がオブジェクトでない場合：例外でプロセスを落とさず、ロード結果（`ModelsConfigLoadResult`）に警告メッセージを記録し、安全な既定設定へフォールバックする（`providers.<id>` 個別の型不正も当該プロバイダのみ警告付きでスキップ）。
   - 未知のプロバイダキー：警告を記録して無視し、他の既知プロバイダのパースを継続する。
3. **VFS 保護維持**:
   - `VfsNamespace`（`packages/agent_kernel/lib/src/vfs_namespace.dart`）の `.agent_os` 保護（`PROTECTED_INTERNAL_PATH` / `EACCES`）により、`.agent_os/models.json` も自動的にエージェントのファイルツール（`sys_fs_read`, `sys_fs_write`, `sys_fs_glob`, `sys_fs_grep` 等）から遮断される。

---

## 2. 有効化判定・`ModelPolicy` 利用制限・マージ規則

D-407: プロバイダ有効化判定テーブルと `ModelPolicy`（[REQ-03], [REQ-04]）

### 2.1 プロバイダ有効化判定テーブル

`ModelsConfig` と `LlmEnvLoader` を組み合わせて、各プロバイダの有効性 `isEnabled` を決定する。

| プロバイダ | `models.json` `enable` | 必須キー / URL 条件 | 最終判定 (`isEnabled`) |
| :--- | :--- | :--- | :--- |
| 全プロバイダ共通 | `false` | （不問） | **`false`（無効）** |
| `local-ollama` | `true`（または省略） | 不要 | **`true`（有効）** |
| `ollama-cloud` | `true`（または省略） | `OLLAMA_API_KEY` 非空 | 非空なら `true`、未設定なら **`false`** |
| `openrouter` | `true`（または省略） | `OPENROUTER_API_KEY` 非空 | 非空なら `true`、未設定なら **`false`** |
| `openai` | `true`（または省略） | `OPENAI_API_KEY` 非空 | 非空なら `true`、未設定なら **`false`** |
| `gemini` | `true`（または省略） | `GEMINI_API_KEY` または `GOOGLE_API_KEY` 非空 | いずれか非空なら `true`、未設定なら **`false`** |
| `nous-portal` | `true`（または省略） | `NOUS_API_KEY` 非空 | 非空なら `true`、未設定なら **`false`** |
| `openai-compat` | `true`（または省略） | `OPENAI_COMPAT_BASE_URL`（環境変数/.env）または `models.json` `baseUrl` または CLI 上書きが非空（`OPENAI_COMPAT_API_KEY` は任意） | いずれか非空なら `true`、未設定なら **`false`** |

### 2.2 `ModelPolicy` による利用制限（`EINVAL` 拒否）とマージ規則

`ModelPolicy`（`packages/agent_drivers/lib/src/llm/models_config.dart`）は以下の契約を提供する：

1. **利用可否検証 (`SyscallError? validateModel(ModelIdentifier model)`)**:
   - 対象プロバイダの `isEnabled == false` → `SyscallError(code: SyscallErrorCode.einval, reason: 'PROVIDER_DISABLED', message: 'Provider "${model.provider.id}" is disabled or missing credentials/baseUrl.')`
   - 対象プロバイダが `autoFetch == false` かつ `manualModels`（正規化済み `modelName` 集合）に `model.modelName` が含まれない → `SyscallError(code: SyscallErrorCode.einval, reason: 'MODEL_NOT_ALLOWED', message: 'Model "${model.canonicalId}" is not in the configured models list for "${model.provider.id}".')`
   - 上記以外 → `null`（許可）。
2. **`autoFetch: true` + 手動リスト併記時のマージ順序（`B-03`）**:
   - `manualModels` の各要素を先頭に配置し、続けて `autoFetch` で取得したモデル一覧から `canonicalId` が重複しない要素のみを追加する（重複排除マージ）。
   - これにより、利用者が明示的に記載したモデルが一覧の上位に現れつつ、重複エントリを排除できる。
3. **`ModelPolicy.validateModel` を適用する全境界（一貫した `EINVAL` 拒否）**:
   - `bin/agent_os_daemon.dart` / `acp_cli_runner.dart` / `kanban_cli_runner.dart` の `--model` 検証（不許可時は終了コード `64` + `stderr` 出力）。
   - `AcpServer._onSessionNew`（`startupModel` 検証）および `_onSetConfigOption`（`session/set_config_option` → `JsonRpcErrorCodes.invalidParams`）。
   - `AcpServer._onSessionPrompt` の `_meta["fm_agent_os/modelOverride"]`（不許可時は `JsonRpcErrorCodes.invalidParams`）。
   - `ModelResolver.setSessionModel` / `ModelResolver.resolveForTurn`（`ModelPolicy? policy` を任意注入し、設定時は `EINVAL` 返却）。

---

## 3. 既定起動モデル無効時のエラー停止フロー

D-408: 既定起動モデル（`local-ollama/gemma4:12b`）無効・リスト外時のエラー停止フロー（[REQ-04]）

`B-04` の合意に基づき、既定モデル `local-ollama/gemma4:12b` が無効またはリスト外になった場合の自動フォールバックを禁止する。

1. `startupModel`（`--model`）が指定されている場合：
   - `ModelPolicy.validateModel(parsedStartupModel)` を実行し、失敗したら即座にエラー終了（CLI/デーモンでは終了コード `64`、`session/new` では `JsonRpcErrorCodes.invalidParams`）。
2. `startupModel` が**未指定**の場合：
   - 既定モデル `ModelIdentifier.parse('local-ollama/gemma4:12b')` に対して `ModelPolicy.validateModel` を実行する。
   - もし `local-ollama` が `enable: false`、または `local-ollama` が `autoFetch: false` で `models` に `gemma4:12b` が含まれない場合、**他の有効モデルへ自動切替せず**、以下のエラーで停止する：
     - `Default startup model "local-ollama/gemma4:12b" is disabled or excluded by .agent_os/models.json. Specify an allowed model via --model <providerId>/<modelName>.`
   - 検証タイミング：`agent_os_daemon.dart` / `acp_cli_runner.dart` の起動時（`Directory.current` 基準で事前確認可能）および `AcpServer._onSessionNew`（`sessionCwd` 基準の `ModelPolicy` 構築時）。

---

## 4. `ModelCatalogService`（起動時 1 回モデル一覧取得＆キャッシュ）

D-409: `ModelCatalogService` 起動時 1 回並列フェッチ・メモリキャッシュ・部分障害耐性・非チャットモデル除外（[REQ-02]）

### 4.1 ライフサイクルと 1 回取得・メモリキャッシュ保証

- `ModelCatalogService`（`packages/agent_drivers/lib/src/llm/model_catalog_service.dart`）はプロセス起動あたり 1 インスタンスとして `AcpServer`（および必要に応じて `KernelBootstrap` 周辺）で保持する。
- **1 回取得保証**:
  - 内部に `final Map<LlmProviderId, List<CatalogModelEntry>> _fetchedCache` と `final Set<LlmProviderId> _attemptedProviders`（または `Future<void>? _initialFetchFuture` による単一フライト制御）を保持する。
  - 初回呼び出し（デーモン起動時または初回 `session/new`）で、`isEnabled && autoFetch` を満たす全プロバイダに対して並列にモデル一覧 API を呼び出し、結果を `_fetchedCache` へ保存する。
  - 2 回目以降の `session/new` や一覧照会では `_attemptedProviders` に記録済みのプロバイダについて外部 HTTP API を**一切再呼び出ししない**（`Future` メモ化により同時並列 `session/new` でも 1 回のみ実行）。
  - 異なる `sessionCwd` の `.agent_os/models.json` が使われた場合も、ネットワーク再取得は行わず、キャッシュ済み `_fetchedCache` に対して該当 `ModelPolicy` の `enable` / `autoFetch` / `models` マージをインメモリで適用する。

### 4.2 並列フェッチ・タイムアウト・部分障害耐性

- 各プロバイダの取得は `Future.wait` で並列実行し、個別に `try / catch` とタイムアウトで保護する：
  - ローカル系（`local-ollama`, `openai-compat`）: `3 秒`
  - クラウド系（`ollama-cloud`, `openrouter`, `openai`, `gemini`, `nous-portal`）: `5 秒`
- いずれかのプロバイダがタイムアウト・接続拒否・HTTP エラー・JSON パースエラーを起こしても例外を上位へ伝播させず、警告ログ（`SecretRedactor` 適用済み）のみ記録して空リスト扱いとし、他プロバイダおよび手動 `models` リストの返却を継続する。

### 4.3 各プロバイダのモデル一覧 API と非チャットモデル除外ルール

| プロバイダ | エンドポイント / 認証 | 非チャットモデル除外ルール |
| :--- | :--- | :--- |
| **`local-ollama`** | `GET <ollamaRoot>/api/tags`（認証なし） | `models[]` 各要素で `capabilities`（`List`）が存在する場合は `"completion"` を含むもののみ採用（`embeddinggemma` 等を除外）。`capabilities` 欠落時は名前に `embed` を含むものを除外。 |
| **`ollama-cloud`** | `GET <cloudRoot>/api/tags`（`OLLAMA_API_KEY` Bearer 任意付与） | 同上（`"completion"` 含有で `clef:27b` 等の非チャットモデルを除外）。 |
| **`openrouter`** | `GET <openRouterBase>/models`（`OPENROUTER_API_KEY` Bearer 付与） | `data[]` 各要素で `architecture.output_modalities`（`List`）が存在する場合は `"text"` を含むもののみ採用。 |
| **`openai`** | `GET <openAiBase>/models`（`OPENAI_API_KEY` Bearer 付与） | `data[].id` に対し非チャットプレフィックス／パターン（プレフィックス: `whisper-`, `tts-`, `dall-e-`, `text-embedding-`, `embedding-`, `omni-moderation-`, `text-moderation-`, `babbage-`, `davinci-`, `gpt-image-`, `chatgpt-image-`, `sora-`, `gpt-audio`, `gpt-live-`、および部分一致／末尾: `-tts`, `-realtime`, `-transcribe`）を除外（実機 101 件検証の取りこぼし `gpt-4o-mini-tts*`, `gpt-audio*`, `gpt-realtime`, `gpt-live-*` 対応）。 |
| **`gemini`** | `GET <geminiBase>/v1beta/models`（`x-goog-api-key` ヘッダ） | `models[]` 各要素で `supportedGenerationMethods`（`List`）に `"generateContent"` を含むもののみ採用（実機 50 件中 `gemini-embedding-001` を除外し 49 件抽出を確認）。`name` の先頭 `"models/"` を除去して `modelName` とする。※補足: `"generateContent"` 対応モデル内にも音声/画像/音楽生成系（`*-tts`, `*-image*`, `nano-banana*`, `lyria-*`, `*-transcribe`, `deep-research-*` 等）が残存するため、必要に応じて ID パターン除外または `.agent_os/models.json` で手動制御する。 |
| **`nous-portal`** | `GET <nousBase>/models`（`NOUS_API_KEY` Bearer 付与） | `data[]` 各要素で OpenRouter 互換の `architecture.output_modalities`（`List`）が存在する場合は `"text"` を含むもののみ採用し、かつ `:batch` サフィックスを除外する（実機 415 件中 `baai/bge-m3`, `intfloat/e5-*`, `mongodb/voyage-*` 等名前に `embed` を含まない埋め込み 39 件および `:batch` モデルを除外）。`architecture.output_modalities` 欠落時は名前に `embed` / `rerank` を含むものを除外。 |
| **`openai-compat`** | `GET <compatBase>/models`（`OPENAI_COMPAT_API_KEY` 設定時のみ Bearer 付与） | `data[].id` を採用（名前に `embed` / `rerank` を含むもののみ除外）。 |

---

## 5. `AcpServer`・`acp_cli_runner`・`KanbanAcpBridge` 統合インターフェース

D-410: `AcpServer`・`acp_cli_runner`・`KanbanAcpBridge` 統合インターフェース（[REQ-02], [REQ-04]）

1. **`AcpServer`（`packages/agent_acp/lib/src/acp_server.dart`）**:
   - 固定定数 `defaultModelCatalog` のみの返却を廃止する（`defaultModelCatalog` 定数自体は後方互換テスト参照用に残してもよいが、`session/new` の `initialCatalog` には使わない）。
   - `AcpServerConfig` に任意 DI 用の `ModelCatalogService? modelCatalogService`（未指定時はデフォルト生成）および `ModelPolicy? modelPolicy`（テスト時の明示ポリシー注入用。未指定時は `_onSessionNew` 内で `sessionCwd` の `LlmEnvLoader` + `ModelsConfigLoader` から生成）を追加する。
   - `_onSessionNew` にて、有効な `ModelPolicy`（注入済みまたは `sessionCwd` から構築）を用いて `ModelCatalogService.resolveOptions(policy)` から `List<AcpModelOption>` を取得し、`_AcpSession` の `initialCatalog` に渡す。
   - **既存テストとの両立（`RV-001` 対応）**: 本番の `ModelPolicy` では API キー未設定の `openrouter` を無効（`EINVAL`）とする契約を維持したまま、既存の `packages/agent_acp/test/acp_server_test.dart`（`OPENROUTER_API_KEY` 未設定で `fakeOpenRouter` モックドライバを使う `modelOverride` テスト）では `AcpServerConfig(modelPolicy: ...)` により `openrouter` を有効化したテスト用ポリシーを注入する（またはダミーキーを設定する）ことで両立させる。
   - 無効プロバイダのモデルが `configOptions` に混入しないよう、`ensureModelInOptions` は `policy.validateModel` 通過済みモデルに対してのみ呼ばれる。
2. **`acp_cli_runner`（`packages/agent_acp/lib/src/cli/acp_cli_runner.dart`）**:
   - 既存の `session/new` レスポンスの `configOptions` 取り込み（`state.updateConfigOptions`）および `/models` / `/model` コマンドは `configOptions` をそのまま表示・送信する構造のため、サーバー側の動的カタログ反映により自動的に全有効モデルが表示・選択可能になる。
   - CLI 起動時の `--model` 形式検証に加え、`session/set_config_option` で `Invalid params`（`EINVAL`）が返った場合はエラーメッセージを明確に表示して終了する既存挙動を維持・確認する。
3. **`KanbanAcpBridge` / `KanbanServer`（`packages/agent_acp/lib/src/kanban/kanban_acp_bridge.dart`）**:
   - `KanbanAcpBridge` は `session/new` の `configOptions` から `_availableModels` を構築し、`availableModels` として Kanban UI へ配信しているため、`AcpServer` 側の統合により Kanban UI にも自動的に反映される。

---

## 6. 確認手順（REQ-02, REQ-03, REQ-04, REQ-05 向け）

1. **`.agent_os/models.json` パーサ・優先順位・有効化・VFS 保護テスト（E1）**:
   - `<sessionCwd>/.agent_os/models.json` vs `<Directory.current>/.agent_os/models.json` の優先順位確認。
   - `enable: false` 時の無効化、API キー未設定時の `false` 扱い、`openai-compat` の `baseUrl` 有無による有効/無効切替。
   - ファイル不在時のフォールバック、JSON 構文不正・未知キー時の非クラッシュ警告動作。
   - `VfsNamespace` 経由の `.agent_os/models.json` 読み書きが `EACCES`（`PROTECTED_INTERNAL_PATH`）で拒否されること。
2. **`ModelCatalogService` と利用制限テスト（E1）**:
   - モック HTTP サーバーに対し、複数回 `session/new` を実行しても `/api/tags`・`/models` への HTTP リクエストが**起動時 1 回のみ**であることを確認。
   - 非チャットモデル除外（Ollama `capabilities` 無し `embeddinggemma`・`clef:27b`、Gemini `embedContent` のみ `gemini-embedding-001`、OpenRouter 非 `text`、OpenAI `whisper-1` / `text-embedding-3-small` / `gpt-4o-mini-tts` / `gpt-audio` / `gpt-realtime` / `gpt-live-1`、Nous Portal `architecture.output_modalities` 非 `"text"` の `baai/bge-m3` 等および `:batch` サフィックス）を確認。
   - 一部プロバイダのタイムアウト・500 エラー時も、他プロバイダおよび手動リストが `configOptions` に返却されることを確認。
   - `autoFetch: false` 時にモックサーバーへの `/models` 呼出が **0 回** であること、手動リストのみ `configOptions` に現れること、リスト外モデル指定（`session/set_config_option`, `_meta["fm_agent_os/modelOverride"]`, `--model`）が `EINVAL` / `Invalid params` で拒否されることを確認。
   - `autoFetch: true` + 手動リスト併記時の重複排除マージを確認。
   - 既定モデル（`local-ollama/gemma4:12b`）無効・リスト外かつ `--model` 未指定時のエラー停止を確認。
3. **既存回帰・AOT ビルド確認（E1, REQ-05）**:
   - `dart analyze`（全パッケージエラーゼロ）。
   - `dart test`（既存全テスト + 新規テストパス）。
   - `dart compile exe`（`agent_os_daemon.exe`, `acp_cli_client.exe` 等のビルド成功）。
4. **CLI `/models`・切替実機確認（E2, REQ-02）**:
   - 利用可能なプロバイダ（Local Ollama 等）環境で `acp_cli_client` を起動し、`/models` に動的取得結果が表示され `/model` で切替できることを観測。
