# 計画書: `web_researcher` のコンテキスト溢れ防止・I/O キャップ修正・チャンク読み出し（`plan_20261121_web_research_cap_and_paging`）

- 進捗・状態正本: [90_status.md](90_status.md)
- プロセス区分: `Light`
- 計画版: `r1`

---

## 1. 目的・背景

実機 CLI テスト（セッション `sess_01_74fa` / Turn 1）において、Web 調査を委譲した Ring 3 子プロセス `web_researcher` 2 体（`pid=2`, `pid=3`）が、`sys_web_search` の結果を数回受け取っただけで `EDQUOT / CONTEXT_FRAME_EXCEEDED` により全滅する事象が発生した。結果として親の LeadAgent が回避策として `sys_exec("curl.exe ...")` を 20 回以上連打し、承認地獄および 64 syscall 上限超過を引き起こす根本原因となった。

監査ログと実装の調査により、以下の 3 点の原因が特定された。

1. **`OllamaWebSearchBackend` が各検索結果の `content` にページ全文（数百 KB〜2 MB）をそのまま返している**:
   - `packages/agent_drivers/lib/src/net/ollama_web_search_backend.dart`（L315-325）が API 応答の `content` を無制限のまま `WebSearchResultItem` に格納しており、1 回の `sys_web_search` が最大 2.1 MB（`17_sys_web_search.txt`）に達していた。
2. **`IoPayloadCapper` の `List` 向けキャップがバイト数を削れていないバグ**:
   - `packages/agent_kernel/lib/src/io_payload_capper.dart`（L223-247）は、`List<dynamic>` フィールドの総バイト数が `maxUtf8Bytes`（16 KB）を超えた際に `truncated = true` と `io_spill` 書き出しを行うものの、切り詰めが要素数（`headLines = 140`, `tailLines = 60`）基準のため、要素数が 5〜10 件の `results` は **1 バイトも削られず 2.1 MB 丸ごとコンテキストへ返却** されていた。
3. **`sys_web_fetch` に大きなページを少しずつ読む手段（チャンク／ページング）がない**:
   - `web_researcher` は `Workspace ⊕ Net` 隔離により `/workspace`（`sys_read_lines`）へアクセスできないため、長大な Web ページが `io_spill` へ退避されても後続部分を読むことができない。

本計画では、`Workspace ⊕ Net` 隔離を一切損なうことなく、**① `IoPayloadCapper` の `List` バイト上限修正**、**② `sys_web_search` のスニペット上限化**、**③ `sys_web_fetch` のインメモリキャッシュ＋行範囲チャンク読み出し（`startLine` / `endLine`）** を実装する。

---

## 2. 代表操作と成功結果

### 代表操作

1. LeadAgent から `sys_spawn(profile: "web_researcher", ...)` を起動し、巨大なページ本文を含む `sys_web_search` を複数回実行する。
2. `web_researcher` が検索結果のタイトル・URL・スニペットから対象 URL を選び、`sys_web_fetch(url: ...)` で先頭チャンクを取得し、続きが必要な場合に `sys_web_fetch(url: ..., startLine: ..., endLine: ...)` で後続行を段階的にスキャンして要約を返す。
3. 要素数が少ない巨大な `List` 出力に対して `IoPayloadCapper.capStructuredPayload` を適用し、返却 JSON の UTF-8 バイト数が上限内に収まることを確認する。

### 成功結果

- `IoPayloadCapper.capStructuredPayload` が `List` フィールド（要素数が `headLines` 未満であっても）の総 UTF-8 バイト数を確実に `config.maxUtf8Bytes` 近傍以内に収め、元データは従来どおり `io_spill` に保存する。
- `sys_web_search` の各検索結果 `content` がスニペット長（デフォルト `800` 文字）に制限され、1 回の検索でコンテキストを圧迫しない。
- `sys_web_fetch` が `startLine` / `endLine`（任意・1-based）を受け付け、同一 URL の再取得コストを避ける有界インメモリキャッシュ（SSRF 検証後）から高速にチャンク返却でき、`totalLines` / `startLine` / `endLine` / `hasMore` / `nextStartLine` を返す。
- `web_researcher` が `Workspace ⊕ Net` 隔離を維持したまま数百 KB 級のページをコンテキスト溢れせずに要約完走できる。
- `dart analyze` 0 件、全 4 パッケージ `dart test` 全 pass、E3 構造検査合格、全 3 `.exe` 再ビルドが成功する。

---

## 3. 範囲と対象外

### 今回対象

1. **`IoPayloadCapper` の `List` バイト上限修正**: `packages/agent_kernel/lib/src/io_payload_capper.dart`
2. **`sys_web_search` のスニペット上限化**: `packages/agent_drivers/lib/src/net/ollama_web_search_backend.dart`
3. **`sys_web_fetch` の行範囲チャンク読み出し＆有界インメモリキャッシュ**: `packages/agent_drivers/lib/src/net/web_fetch_driver.dart`
4. **`web_researcher` プロンプトのチャンク読み出しガイド追記**: `packages/agent_runtime/lib/src/prompts/agent_prompts.dart`
5. **単体・統合テスト追加および全 3 `.exe` 再ビルド**

### 対象外

- `web_researcher` への `/workspace` 読み書き権限付与（`Workspace ⊕ Net` 隔離は絶対維持）
- HTML パーサ・SSRF 防御（DNS pinning / Private IP 拒否 / リダイレクト検証）の緩和
- `sys_web_search` プロバイダ自体の差し替え
- LeadAgent 側のループ回数上限変更（`plan_20261121_loop_limit_improvements` で対応）
- `sys_exec` の承認シグネチャ変更（`plan_20261121_exec_approval_and_net_policy` で対応）

---

## 4. 要求と受け入れ条件

| ID | 要求・根拠 | 対象設計ID | 受け入れ条件 | 確認方法 / 証跡区分 |
| --- | --- | --- | --- | --- |
| REQ-01 | `IoPayloadCapper.capStructuredPayload` の `List` 分岐で、要素数が `headLines` 未満でも総 UTF-8 バイト数上限（`config.maxUtf8Bytes`）を確実に守る。根拠: 5〜10 件の巨大 JSON 要素が 2.1 MB そのまま通過していたバグの修正 | [D-001] | 要素数 `<= headLines` かつ各要素が巨大な `List`（例: 5 件 × 100 KB）を `capStructuredPayload` に渡した際、`truncated == true` となり、返却された `List` の JSON エンコード後 UTF-8 バイト数が `config.maxUtf8Bytes` 以下（または許容マージン内）に収まり、`spillPath` が記録されること。既存の `List<String>`（`sys_glob` / `sys_grep` 等）テストが全 pass すること | `io_payload_capper_test.dart` の新規ケース＋既存テスト全 pass / E1 |
| REQ-02 | `sys_web_search`（`OllamaWebSearchBackend`）の各検索結果 `content` をスニペット上限（デフォルト `800` 文字）に制限する。根拠: 検索一覧 API がページ全文を返すことによるコンテキスト浪費防止 | [D-002] | `OllamaWebSearchBackend` に `maxSnippetChars`（デフォルト `800`）を設け、`content` が超過した場合に末尾 `...` 付きで切り詰め、要素に `contentTruncated: true` および `originalContentChars` を付与すること。超過しない場合は既存フィールド構成を維持すること | `ssrf_and_web_drivers_test.dart` の単体テスト / E1 |
| REQ-03 | `sys_web_fetch` に `startLine` / `endLine`（任意・1-based）によるチャンク読み出しと、SSRF 検証後の有界インメモリキャッシュを追加する。根拠: `Workspace ⊕ Net` 隔離下で巨大 Web ページを分割スキャン可能にする | [D-003], [D-004] | `sys_web_fetch` のツールスキーマおよびバリデーションが任意の正整数 `startLine` / `endLine`（`startLine <= endLine`）を受け付けること。返却 JSON に `totalLines` / `startLine` / `endLine` / `hasMore` / `nextStartLine` が含まれ、デフォルト取得でも `endLine` 未指定時は適切なチャンク（例: 最大 200 行）を返し、後続チャンクを `startLine` 指定でキャッシュヒット取得できること。`web_researcher` プロンプトに分割読み出しガイドが追記されていること。SSRF 防御・`Workspace ⊕ Net` 隔離が不変であること | `ssrf_and_web_drivers_test.dart`・`web_researcher_isolation_test.dart`・`agent_prompts_test.dart` / E1 |
| REQ-04 | 静的解析・全テスト・E3 構造検査・全 3 `.exe` 再ビルドが合格する。根拠: 既存品質・配布物の 100% 維持 | [D-001]〜[D-005] | `dart analyze` 0 件、全 4 パッケージ `dart test` 全 pass（スキップなし）、`stage3_architecture_and_purity_test.dart` 合格、全 3 `.exe` 再ビルド・起動確認成功 | `dart analyze`、`dart test`、`dart compile exe`、E3 構造検査 / E1, E3 |

---

## 5. 変更設計・IF・後方互換・依存境界

### D-001: `IoPayloadCapper.capStructuredPayload` の `List` バイト上限保証（[REQ-01]）

`packages/agent_kernel/lib/src/io_payload_capper.dart`（L223-260）の `rawValue is List<dynamic>` 分岐を改修する。

1. まず従来どおり `joined` に対して `capText` を実行し、`truncated == true` の場合は `io_spill` 書き出しを行う。
2. `truncated == true` の場合、単に `headLines` / `tailLines` 件数で切るだけでなく、**`config.maxUtf8Bytes` のバイト予算内で収まるように 2 段階キャップ**を行う：
   - **Step A（要素内長大文字列の切り詰め）**: まず要素数を最大 `headLines + tailLines` 件に絞った上で、各要素が `Map` なら長大な `String` 値（例: 1 フィールドあたり `perItemByteBudget` 超過）を UTF-8 安全スライス＋`... [truncated]` で短縮し、`String` 要素なら 1 行あたり上限で短縮する。
   - **Step B（総バイト数の最終保証）**: 先頭から順に要素の JSON バイト長を積算し、累計が `config.maxUtf8Bytes` を超えた時点で残りを省略する（最低 1 件は短縮版で残す）。
   - `originalCount` / `omittedCount` / `originalBytes` / `omittedBytes` / `capNotice` / `spillPath` は従来どおり付与する。

### D-002: `OllamaWebSearchBackend` のスニペット上限化（[REQ-02]）

`packages/agent_drivers/lib/src/net/ollama_web_search_backend.dart` に以下を追加する。

- `OllamaWebSearchBackend` コンストラクタに `this.maxSnippetChars = 800`（`assert(maxSnippetChars > 0)`）を追加。
- `WebSearchResultItem` に `final bool contentTruncated;`（デフォルト `false`）および `final int? originalContentChars;` を追加。
- 検索結果パース時（L315-326）、`content.length > maxSnippetChars` の場合は `content.substring(0, maxSnippetChars) + '...'` に短縮し、`contentTruncated: true`、`originalContentChars: content.length` を記録する。
- `toJson()` では `contentTruncated == true` のときのみ `'contentTruncated': true` と `'originalContentChars': originalContentChars` を含め、短いスニペットでは既存 JSON 形式と完全互換を維持する。

### D-003: `WebFetchDriver` のチャンク読み出しと有界インメモリキャッシュ（[REQ-03]）

`packages/agent_drivers/lib/src/net/web_fetch_driver.dart` を以下のように拡張する。

1. **ツールスキーマ拡張（`buildWebFetchToolSchema`）**:
   - 既存必須引数 `url` に加え、任意引数 `startLine`（1-based 正整数、省略時 `1`）および `endLine`（1-based 正整数、省略時は `startLine + defaultChunkLines - 1`、デフォルト `defaultChunkLines = 200`）を追加する。
   - `validateArgs` で `startLine >= 1`、`endLine >= startLine` を検証し、不正値は `EINVAL`（`recoverable: true`）を返す。
2. **有界インメモリキャッシュ（`WebFetchDriver` 内）**:
   - SSRF 検証および本文抽出後の `(finalUrl, statusCode, contentType, title, List<String> lines, DateTime fetchedAtUtc)` を URL キーでキャッシュする（最大 `maxCacheEntries = 16`、TTL `5 分`、LRU で古いエントリを自動破棄）。
   - キャッシュヒット時も必ず `startLine` / `endLine` によるスライスのみ行い、ネットワーク再取得を避ける（`startLine == 1 && endLine == null` かつ TTL 内なら再利用、またはキャッシュヒット時も SSRF 検証済みの正規化 URL をキーとする）。
   - ディスク（`/workspace`）には一切書き込まないため、`Workspace ⊕ Net` 隔離を 100% 維持する。
3. **返却ペイロードのページングメタデータ**:
   - 既存フィールド（`url`, `finalUrl`, `statusCode`, `contentType`, `title`, `markdown`）を維持しつつ、以下を追加する：
     - `'totalLines'`: 抽出済み Markdown 全体の行数
     - `'startLine'`: 実際に返却した開始行（1-based）
     - `'endLine'`: 実際に返却した終了行（1-based）
     - `'hasMore'`: `endLine < totalLines`
     - `'nextStartLine'`: `hasMore ? endLine + 1 : null`
   - `startLine > totalLines`（かつ `totalLines > 0`）の場合は空の `markdown: ''`、`hasMore: false` を返し、クラッシュさせない。

### D-004: `web_researcher` プロンプト更新と後方互換（[REQ-03], [REQ-04]）

- `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` の `ProcessProfileId.webResearcher` プロンプトに、簡潔なチャンク読み出しガイドを 1 行追記する：
  - `When sys_web_fetch returns hasMore: true, read subsequent sections incrementally with startLine/endLine rather than requesting everything at once.`
- `agent_prompts_test.dart` の期待値も同期更新する。
- `sys_web_fetch` に `startLine` / `endLine` を省略して呼ぶ既存呼び出し元・既存テストは、`200` 行以内のページであれば `markdown` がそのまま全量返却され後方互換を維持する。

### D-005: 依存境界・検証戦略（[REQ-04]）

- 新規外部 pub 依存の追加なし。`agent_kernel`（`IoPayloadCapper`）は `agent_drivers` に依存しない。
- 新規テスト項目：
  1. `io_payload_capper_test.dart`: 要素数 5 件・各 50 KB の `List<Map>` が `maxUtf8Bytes` 以内に収まり `spillPath` が生成されること。
  2. `ssrf_and_web_drivers_test.dart`:
     - `OllamaWebSearchBackend` で 2,000 文字の `content` が 800 文字＋`...` に切り詰められ `contentTruncated: true` が付くこと。
     - `WebFetchDriver` で 500 行のページを `startLine`/`endLine` で分割取得でき、2 回目以降はキャッシュヒット（HTTP モック呼び出し 1 回のみ）すること、および不正 `startLine`/`endLine` が `EINVAL` になること。
  3. `web_researcher_isolation_test.dart`: 既存隔離テスト全 pass ＋ 大容量検索結果でも `web_researcher` が `CONTEXT_FRAME_EXCEEDED` にならないこと。

---

## 6. 変更対象ファイル一覧と確認手順

### 変更対象ファイル一覧

| 種別 | ファイルパス | 変更内容 |
| --- | --- | --- |
| 更新 | `packages/agent_kernel/lib/src/io_payload_capper.dart` | `capStructuredPayload` の `List` 分岐に総バイト数上限キャップを実装（`omittedBytes` は実返却 `sliced` JSON バイト差分から算出） |
| 更新 | `packages/agent_kernel/lib/src/web_driver.dart` | `WebSearchResultItem` に `contentTruncated` / `originalContentChars` 追加（後方互換維持） |
| 更新 | `packages/agent_drivers/lib/src/net/ollama_web_search_backend.dart` | `maxSnippetChars`（デフォルト `800`）による検索結果 `content` スニペット制限 |
| 更新 | `packages/agent_drivers/lib/src/net/web_fetch_driver.dart` | `startLine` / `endLine` ページング引数、有界インメモリ LRU キャッシュ（TTL 内任意行範囲ヒット）、ページングメタデータ追加 |
| 更新 | `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` | `webResearcher` プロンプトにチャンク読み出しガイド追記 |
| 更新 | `packages/agent_kernel/test/io_payload_capper_test.dart` | 巨大 `List<Map>` バイトキャップ検証テスト追加 |
| 更新 | `packages/agent_drivers/test/ssrf_and_web_drivers_test.dart` | スニペット制限・チャンク読み出し・キャッシュヒット・引数バリデーションテスト追加 |
| 更新 | `packages/agent_runtime/test/agent_prompts_test.dart` | `webResearcher` プロンプト更新の期待値同期 |

### 確認手順

1. **静的解析**: `mise exec -- dart analyze`（0 件確認）
2. **全パッケージテスト**: `mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp`（全 pass・スキップ 0 件）
3. **E3 構造検査・全 3 `.exe` 再ビルド**: 3 `.exe` 再ビルドおよび `stage3_architecture_and_purity_test.dart` 合格確認

---

## 7. レビュー所見・変更履歴（notes）

### レビュー所見

- **レビュー担当 / 判定**: `fm-dev-reviewer` (`PT-02`) / **`ready`**（Critical: `0` 件 / Must-fix: `1` 件 / Suggest: `2` 件）
- **環境宣言照合（`env_manifest.md`）**: Git commit `c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8`、製品ツリー差分 `0` 件、`plan.md` 実サイズ `16762` bytes・SHA-256、テストファイル数 `42` 件をすべて独立照合で一致確認済み。
- **Must-fix（1 件）**:
  1. **[M-01] Section 6 `変更対象ファイル一覧` への `web_driver.dart` 追記漏れ**: `D-002` で拡張する `WebSearchResultItem`（`contentTruncated` / `originalContentChars` 追加）は `ollama_web_search_backend.dart` ではなく `packages/agent_kernel/lib/src/web_driver.dart`（L5-23）に定義されているため、Section 6 の変更対象一覧に `packages/agent_kernel/lib/src/web_driver.dart` を含めること（`agent_kernel` の E3 純粋性・依存境界への影響なし）。
- **Suggest（2 件）**:
  1. **[S-01] `D-001` の `omittedBytes` 算出**: `List` 2 段階キャップ後の `omittedBytes` / `capNotice` は `capText(joined)` の値ではなく、実際に返却する `sliced` の JSON バイト長との差分から算出すること。
  2. **[S-02] `D-003` のキャッシュヒット条件**: キャッシュヒット判定は `startLine == 1 && endLine == null` に限定せず、正規化 URL が TTL 内にキャッシュにあれば任意の `startLine` / `endLine` 呼び出しで再利用すること。
- **後方互換性・E3 純粋性確認**: `WebSearchResultItem` のオプション引数デフォルト値・`toJson()` 条件付き出力、`WebFetchDriver.fetch` の任意引数追加、`IoPayloadCapper` の既存 `List<String>` / `Map` テスト（`ssrf_and_web_drivers_test.dart` L898-914 含む）との互換性、および `PinnedHttpWebFetchTransport` / `AgentPrompts` の E3 構造検査への抵触がないことを確認済み。

### 独立受け入れ判定（fm-dev-acceptance / IT-02）

- **判定**: **`PASS`**（Critical: `0` 件 / Must-fix: `0` 件 / Suggest: `0` 件）
- **要求別判定**:
  - **`REQ-01`（`PASS`）**: `packages/agent_kernel/lib/src/io_payload_capper.dart` の `List` 2 段階キャップ（Step A 要素内フィールド予算化＋Step B UTF-8 JSON バイト積算、`S-01` による実返却 `sliced` 差分の `omittedBytes` / `omittedCount` 算出）および `io_payload_capper_test.dart` / `step1_1_integration_test.dart` の検証を確認。
  - **`REQ-02`（`PASS`）**: `packages/agent_kernel/lib/src/web_driver.dart`（`M-01` 反映済み）の `WebSearchResultItem` オプション拡張と条件付き `toJson()`、`packages/agent_drivers/lib/src/net/ollama_web_search_backend.dart` の `maxSnippetChars = 800` 切り詰め、および `ssrf_and_web_drivers_test.dart` の単体テストを確認。
  - **`REQ-03`（`PASS`）**: `packages/agent_drivers/lib/src/net/web_fetch_driver.dart` の `startLine`/`endLine` ページング・`EINVAL` バリデーション・有界 LRU+TTL キャッシュ（`maxCacheEntries = 16`, `cacheTtl = 5m`, `S-02` 任意行範囲ヒット）・SSRF/隔離維持、`packages/agent_runtime/lib/src/prompts/agent_prompts.dart` の 1 行ガイド追記、`agent_prompts_test.dart` / `ssrf_and_web_drivers_test.dart` を確認。
  - **`REQ-04`（`PASS`）**: 独立再実行にて以下を確認：
    - `mise exec -- dart analyze`: `No issues found!`（`0` 件）
    - `mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp`（`OPENROUTER_API_KEY` クリア状態）: `42` テストファイル・`247` テストケース全 pass（スキップ `0` 件）
    - `mise exec -- dart test packages/agent_acp/test/stage3_architecture_and_purity_test.dart`: `8/8` 全 pass
    - `pubspec.yaml` / `packages/*/pubspec.yaml` 差分 `0` 件
- **`env_manifest.md` 成果物独立照合（全 3 `.exe` 一致）**:
  - `build/agent_os_daemon.exe`: `10089472` bytes / `b7b8317b512677e5701c46e2075e358a8510a1c4f6c1bc546a0ebe9798211f30`
  - `build/acp_cli_client.exe`: `6837248` bytes / `ceacde62d5f0874d0eea00836531ae2d3b2fd8cf53b2e8371d9233d9ba8a6de5`
  - `build/acp_kanban_app.exe`: `7175168` bytes / `e69dcc3ce534933d75bee05bf504960f9bf88639c164d2ec5272c0ae050e6612`

### 変更履歴

| 版 | 日付 | 変更内容 | 担当 |
| --- | --- | --- | --- |
| `r1` | 2026-11-21 | 初版作成（Light プラン） | Antigravity |
| `r2` | 2026-11-21 | `PT-02` レビュー指摘反映（`M-01`: `web_driver.dart` 追記、`S-01`: `omittedBytes` 実差分算出、`S-02`: キャッシュヒット条件明確化） | Antigravity |
