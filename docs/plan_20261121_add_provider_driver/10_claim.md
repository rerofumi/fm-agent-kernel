# 10_claim.md — 要望・背景・当初の課題と仮説

関連文書:
- 入力要望: [01_wants.md](./01_wants.md)
- 利用場面・代表操作・範囲: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件・未決事項: [30_requirement.md](./30_requirement.md)
- 既存 LLM 仕様・知見: [llm_providers_and_cache.md](../cheatsheet/llm_providers_and_cache.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 当初の要望と背景

### 1.1 利用者が求めたこと（`01_wants.md` 原意）
Stage 1 で構築した `local-ollama` / `ollama-cloud` / `openrouter` の 3 プロバイダ対応・Canonical IR 毎ターン切替・ACP/CLI/Kanban 基盤に対し、日常利用と多様なモデル検証を広げるため以下の 2 軸の拡張を求める。

1. **LLM プロバイダの追加（4 種）**
   - **OpenAI API**
   - **Google AI Studio API (Gemini)**
   - **Nous Portal**
   - **OpenAI 互換 API（Local LLM 用：Strata、llama.cpp 等を想定）**
2. **モデルリストの改善**
   - デフォルト時は `/api/tags` 等の各プロバイダ API からモデル一覧を取得し、**起動時に 1 回取得してキャッシュ** する。
   - **`.agent_os/models.json`** により表示・利用するモデルリストを制御できるようにし、以下のパラメータを持たせる：
     - プロバイダごとの `enable` フラグ（使う／使わない）。なお **API キー環境変数が設定されていないときは `false` 扱い** とする。
     - **自動リスト取得フラグ**（`false` のときはこのファイルに書かれているリストのモデルのみ表示されて使える）。
     - **モデルリストのマニュアル記載**（OpenRouter 等はモデル数が多すぎるため、使うものだけを手動記載して運用できるようにする）。

### 1.2 現行実装の課題（基準 commit `72483b3ca1175d276b398bc9f4a4567b84ffc263`）
1. **対応プロバイダが 3 種に固定されている**:
   - `LlmProviderId`（`packages/agent_kernel/lib/src/llm_driver.dart`）が `local-ollama` / `ollama-cloud` / `openrouter` のみであり、OpenAI・Google AI Studio・Nous Portal・汎用ローカル OpenAI 互換サーバ（Strata / llama.cpp 等）を直接利用できない。
2. **ACP / CLI / Kanban のモデル一覧がハードコード固定である**:
   - `AcpServer.defaultModelCatalog`（`packages/agent_acp/lib/src/acp_server.dart`）が 6 個の固定モデル定義になっており、ローカルの Ollama に導入した新モデルが自動反映されず、逆に API キー未設定のクラウドプロバイダも一覧に表示されてしまう。
   - 一方で OpenRouter のような巨大カタログを毎回・無制限に展開すると、CLI の `/models` や Kanban UI のプルダウンが過密になり実用的でない。

---

## 2. 対象利用者

- **主対象者**: `agent_os_daemon`（ACP サーバー）、`acp_cli_client`（CLI クライアント）、および Kanban UI を通じて複数のローカル・クラウド LLM を毎ターン切り替えながら開発作業を行う **開発者本人**。

---

## 3. 当初の仮説と不確実性

1. **ワイヤプロトコルとモデル一覧 API の差異（技術調査 A）**:
   - OpenAI・OpenAI 互換（Strata / llama.cpp）は `/v1/chat/completions`（SSE）および `/v1/models` 系で統一できる見込みだが、Google AI Studio（ネイティブ Gemini API vs OpenAI 互換エンドポイント）および Nous Portal（公式エンドポイント・認証・モデル一覧 API・Tool Call / Reasoning 仕様）は一次資料の確認が必要。
2. **プロバイダ識別子・`.agent_os/models.json` 制限境界・ローカル互換設定（利用者判断 B）**:
   - `<providerId>/<modelName>` 形式のプロバイダ識別子名（例: `google` vs `gemini`、`nous-portal` vs `nous`、`openai-compat` vs `local-openai`）、自動取得 `false` 時のリスト外モデル手打ち可否、OpenAI 互換の単一/複数エンドポイント要否などは利用者合意が必要。
