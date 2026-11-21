# 計画書: `sys_exec` 承認シグネチャ粒度改善とネットワークコマンド誘導ポリシー（`plan_20261121_exec_approval_and_net_policy`）

- 進捗・状態正本: [90_status.md](90_status.md)
- プロセス区分: `Light`
- 計画版: `r1`

---

## 1. 目的・背景

実機 CLI テスト（セッション `sess_01_74fa` / Turn 4）において、LeadAgent が `sys_exec` 経由で `curl.exe -sL -o research/os_history/<topic>.json "https://en.wikipedia.org/..."` を 20 回以上連続実行した際、以下の 2 点の課題が顕在化した。

1. **`a`（`allow_always` / セッション許可）を選択しても毎回承認プロンプトが出る**:
   - `packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart`（L854-861）の `approvalSignatureBuilder` が `'$command\u0000${argsList.join('\u0000')}\u0000$workingDir'` という **引数全体の完全一致** になっているため、URL パスや出力ファイル名（`-o`）が 1 文字でも変わると別シグネチャ扱いになり、同一ホストからの連続取得でも毎回手動承認が必要になった。
2. **LeadAgent が `web_researcher` ではなく `sys_exec("curl.exe ...")` を直接叩くのを抑止・案内する仕組みが弱い**:
   - `LeadAgent` のシステムプロンプト（`AgentPrompts.leadStage2Instruction`）には `sys_web_search` / `sys_web_fetch` は `web_researcher` へ委譲する旨が書かれているが、`sys_exec` 経由の `curl` / `wget` / `Invoke-WebRequest` 直利用を避ける指示がない。
   - また、`SysExecClassifier`（`sys_exec_classifier.dart`）がネットワーク取得コマンドを一般コマンドと区別していないため、承認プレビュー上でも「外部ネットワーク通信であり、通常は `web_researcher` への委譲が推奨される」ことが見えない。

本計画では、**セキュリティ境界（シェルメタ文字の強制承認、POST/データ送信の厳格確認、ホスト跨ぎ禁止、`git`/`jj` 禁止、TTY 独占）を一切緩めることなく**、① 読み取り専用 HTTP 取得コマンドにおける **同一 origin（`scheme://host[:port]`）単位のセッション許可シグネチャ** と承認プレビュー上のスコープ明示、② `LeadAgent` プロンプトおよび `SysExecClassifier` における外部ネットワークコマンドの明示・`web_researcher` 誘導を実装する。

---

## 2. 代表操作と成功結果

### 代表操作

1. `sys_exec` で同一ホスト（例: `https://en.wikipedia.org/...`）に対する読み取り系 `curl` / `curl.exe` / `wget` が複数回発行された際、1 回目の承認プロンプトにセッション許可スコープ（例: `curl.exe (GET/read-only) -> https://en.wikipedia.org`）が表示され、`a`（`allow_always`）を選択すると、同一ホストへの後続読み取り取得は再承認なしで通過する。
2. 異なるホスト（例: `https://example.com/...`）、書き込み／送信系フラグ（`-d`, `--data`, `-F`, `-T`, `-X POST/PUT/DELETE` 等）、またはシェルメタ文字（`|`, `&&`, `;` 等）を含むコマンドではキャッシュが効かず、必ず再度ユーザー承認を求める。
3. 通常コマンド（例: `dart --version`, `python script.py`）の既存 `allow_always` 挙動および `git`/`jj` 拒否・Ring 3 TTY 独占が従来どおり動作する。

### 成功結果

- 同一 origin への読み取り系 `curl` / `wget` に対して `allow_always` がセッション内で有効に機能し、連続取得時の承認疲労が解消される。
- 異なる origin・データ送信系フラグ・複数 URL・シェルメタ文字付きコマンドに対しては、誤って広い許可が効かない（必ず完全一致シグネチャまたは再承認となる）。
- `ApprovalPreview` に `Session scope (allow_always): ...` が表示され、ユーザーが `a` を押したときに何が記憶されるか事前に確認できる。
- `LeadAgent` のシステムプロンプトおよび `SysExecClassifier` の分類理由が、外部 Web 取得は `web_researcher` へ委譲すべき旨を明示する。
- `dart analyze` 0 件、全 4 パッケージ `dart test` 全 pass、E3 構造検査合格、全 3 `.exe` 再ビルドが成功する。

---

## 3. 範囲と対象外

### 今回対象

1. **`SysExecClassifier` のネットワーク取得コマンド識別と安全な `approvalSignature` 生成**:
   - `packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart`
   - `packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart`
2. **`ApprovalPreview` へのセッション許可スコープ表示**:
   - `packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart`
3. **`LeadAgent` プロンプトへの `curl`/`wget` 直利用抑止ガイド追記**:
   - `packages/agent_runtime/lib/src/prompts/agent_prompts.dart`
4. **単体・統合テスト追加および全 3 `.exe` 再ビルド**

### 対象外

- `curl` / `wget` の `sys_exec` 実行そのものの全面禁止（ローカルファイルへの直接ダウンロード等、ユーザーが明示承認したい正当ケースを残すため）
- ACP プロトコル `session/request_permission` のオプション種別（`allow_once` / `allow_always` / `reject_once`）の拡張・変更
- 任意の汎用コマンドに対するワイルドカード／正規表現ベースの許可ルール設定ファイル新設
- `web_researcher` の I/O キャップ・ページング修正（`plan_20261121_web_research_cap_and_paging` で対応）

---

## 4. 要求と受け入れ条件

| ID | 要求・根拠 | 対象設計ID | 受け入れ条件 | 確認方法 / 証跡区分 |
| --- | --- | --- | --- | --- |
| REQ-01 | 読み取り専用 `curl` / `wget` の `allow_always` シグネチャを、安全な条件を満たす場合のみ **実行ファイル＋同一 origin（`scheme://host[:port]`）＋`workingDir`** 単位にする。根拠: 同一ホストからの連続取得で毎回承認が発生する UX 問題の解消とセキュリティ境界の両立 | [D-001] | シェルメタ文字なし・単一 `http`/`https` URL・送信/破壊系フラグ（`-d`/`--data*`/`-F`/`--form*`/`-T`/`--upload-file`/`-X`/`--request` で GET/HEAD 以外等）なしの `curl`/`curl.exe`/`wget`/`wget.exe` について、同一 origin かつ異なるパス／`-o` 出力先でも同一の `approvalSignature` を生成すること。異なる origin・送信系フラグあり・複数 URL・シェルメタ文字ありの場合は完全一致シグネチャへフォールバックすること | `sys_exec` 単体テストおよび `acp_server_test.dart` の `allow_always` テスト / E1 |
| REQ-02 | `sys_exec` の `ApprovalPreview` に、外部ネットワークコマンドである旨の分類理由と `allow_always` 選択時の許可スコープを表示する。根拠: ユーザーがセッション許可の範囲を明示的に把握できるようにするため | [D-002] | `SysExecClassifier` が `curl` / `wget` / `Invoke-WebRequest` / `iwr` 等の外部ネットワーク取得コマンドを専用理由（例: `EXTERNAL_NETWORK_COMMAND`）で `RingDecision.askUser` 分類し、`ApprovalPreview` 本文に `Session allow_always scope:` を含めること | `sys_exec` 分類・プレビュー単体テスト / E1 |
| REQ-03 | `LeadAgent` プロンプトに、`sys_exec` 経由の `curl`/`wget` 等での直接 Web 取得を避け `web_researcher` へ委譲するルールを追記する。根拠: `Workspace ⊕ Net` 隔離の原則徹底 | [D-003] | `AgentPrompts.leadStage2Instruction`（ルール 10）に `curl` / `wget` / `Invoke-WebRequest` を `sys_exec` で直接使わず `web_researcher` を使う旨が明記され、`agent_prompts_test.dart` が pass すること | `agent_prompts_test.dart` / E1 |
| REQ-04 | 既存の `sys_exec` セキュリティ制約（`git`/`jj` 拒否、シェルメタ文字強制承認、既存 `allow_always` 完全一致テスト、Ring 3 TTY 独占）、静的解析、全テスト、E3 構造検査、全 3 `.exe` 再ビルドが合格する。根拠: 既存セキュリティ・品質の 100% 維持 | [D-001]〜[D-004] | `dart analyze` 0 件、全 4 パッケージ `dart test` 全 pass（スキップなし）、`stage3_architecture_and_purity_test.dart` 合格、全 3 `.exe` 再ビルド・起動確認成功 | `dart analyze`、`dart test`、`dart compile exe`、E3 構造検査 / E1, E3 |

---

## 5. 変更設計・IF・後方互換・依存境界

### D-001: 安全な origin 単位 `approvalSignature` ビルダー（[REQ-01]）

`packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart` に、正規化済みコマンドから `approvalSignature` と人間可読な `scopeDescription` を計算する純粋関数 `SysExecApprovalScope.build(...)` を追加し、`win32_job_exec_driver.dart` の `approvalSignatureBuilder` および `approvalPreviewBuilder` から共通利用する。

1. **origin 単位キャッシュの適用条件（すべて満たす場合のみ）**:
   - `hadShellMeta == false`（パイプ・リダイレクト・コマンド連結・環境変数展開なし）
   - 実行ファイルのベース名（小文字、`.exe` 除去）が `curl` または `wget`
   - 送信・変更系オプションを含まない：
     - `curl`: `-d`, `--data`, `--data-raw`, `--data-binary`, `--data-urlencode`, `--json`, `-F`, `--form`, `--form-string`, `-T`, `--upload-file`, `-K`, `--config`, `-X`/`--request`（値が `GET`/`HEAD` 以外の場合）
     - `wget`: `--post-data`, `--post-file`, `--method`（`GET`/`HEAD` 以外）, `--body-data`, `--body-file`, `-i`, `--input-file`
   - 引数中から抽出される `http://` または `https://` URL が **ちょうど 1 個** で、`Uri.tryParse` が有効な `scheme` と `host` を持つ（さらに `localhost` / プライベート IP リテラル等は origin 単位キャッシュ対象外とし完全一致フォールバックとする）
2. **生成されるシグネチャ**:
   - 条件を満たす場合：
     - `signature`: `'exec:net_read:$exeBase\u0000$origin\u0000$workingDir'`（例: `'exec:net_read:curl\u0000https://en.wikipedia.org\u0000/workspace'`）
     - `scopeDescription`: `'Read-only $exeBase requests to $origin (in $workingDir)'`
   - 条件を満たさない場合（汎用コマンド・送信系・複数 URL・シェルメタ文字等）：
     - `signature`: 現行どおり `'$command\u0000${argsList.join('\u0000')}\u0000$workingDir'`（完全一致、100% 後方互換）
     - `scopeDescription`: `'Exact command in $workingDir'`

### D-002: `SysExecClassifier` の外部ネットワークコマンド識別と `ApprovalPreview` 明示（[REQ-02]）

- `sys_exec_classifier.dart` で `curl`, `wget`, `invoke-webrequest`, `iwr`, `invoke-restmethod`, `irm` 等を識別した場合、引き続き `RingDecision.askUser` を返しつつ、分類理由を `'EXTERNAL_NETWORK_COMMAND: Direct network command via sys_exec (prefer delegating web lookup to web_researcher).'` とする。
- `win32_job_exec_driver.dart` の `approvalPreviewBuilder`（L832-852）で `SysExecApprovalScope.build(...)` を呼び出し、プレビュー本文に `Session allow_always scope: ${scope.scopeDescription}` を追記し、`metadata['approvalScope']` にも格納する。

### D-003: `LeadAgent` プロンプトの `curl`/`wget` 直利用抑止ガイド（[REQ-03]）

- `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` の `leadStage2Instruction` ルール 10 に以下を 1 文追記する：
  - `Do NOT bypass this isolation by invoking curl, wget, or Invoke-WebRequest directly via sys_exec unless the user explicitly asks to download a raw file into /workspace.`
- `agent_prompts_test.dart` の期待値を同期更新する。

### D-004: 後方互換・依存境界・検証戦略（[REQ-04]）

- 新規外部 pub 依存の追加なし。`ApprovalGate`（`agent_kernel`）のインターフェース変更なし（既存の `approvalSignature` 文字列キャッシュ機構をそのまま活用）。
- 新規テスト項目：
  1. `sys_exec` 単体テスト（`packages/agent_drivers/test/win32_job_exec_test.dart` 等）：
     - `curl.exe -sL -o a.json https://en.wikipedia.org/page1` と `curl.exe -sL -o b.json https://en.wikipedia.org/page2` が同一 `approvalSignature` を生成すること。
     - 異なるホスト（`https://example.com/...`）、`-d "secret"` 付き、`-X POST` 付き、パイプ `|` 付き、`http://127.0.0.1/...` がすべて別シグネチャ（完全一致フォールバック）になること。
     - `ApprovalPreview` に `Session allow_always scope:` と `EXTERNAL_NETWORK_COMMAND` が含まれること。
  2. `packages/agent_acp/test/acp_server_test.dart`：
     - 同一 origin の `curl` 2 回目が `allow_always` キャッシュで再承認不要になること（既存 `dart --version` テストと併存）。

---

## 6. 変更対象ファイル一覧と確認手順

### 変更対象ファイル一覧

| 種別 | ファイルパス | 変更内容 |
| --- | --- | --- |
| 更新 | `packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart` | `SysExecApprovalScope.build` 新設、外部ネットワークコマンド分類理由追加 |
| 更新 | `packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart` | `approvalSignatureBuilder` と `approvalPreviewBuilder` を `SysExecApprovalScope` 連動へ更新 |
| 更新 | `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` | `leadStage2Instruction` ルール 10 に `curl`/`wget` 直利用抑止の 1 文追記 |
| 更新 | `packages/agent_drivers/test/win32_job_exec_test.dart`（または関連テスト） | origin 単位シグネチャ・送信系/異ホスト/メタ文字/attached・equals 形式/private IP フォールバック・プレビュー表示テスト追加 |
| 更新 | `packages/agent_acp/test/acp_server_test.dart` | 同一 origin の `curl` 2 回目が `allow_always` キャッシュで再承認不要になる統合テスト追加 |
| 更新 | `packages/agent_runtime/test/agent_prompts_test.dart` | `leadStage2Instruction` 期待値同期 |

### 確認手順

1. **静的解析**: `mise exec -- dart analyze`（0 件確認）
2. **全パッケージテスト**: `mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp`（全 pass・スキップ 0 件）
3. **E3 構造検査・全 3 `.exe` 再ビルド**: 3 `.exe` 再ビルドおよび `stage3_architecture_and_purity_test.dart` 合格確認

---

## 7. レビュー所見・変更履歴（notes）

### レビュー所見

- **レビュー担当 / 工程**: `fm-dev-reviewer`（`PT-02`） / 2026-11-21
- **判定**: **`ready`**（Critical: `0`, Must-fix: `2`, Suggest: `3`）
- **対象ファイル突合結果**:
  - `packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart`、`win32_job_exec_driver.dart`（`normalizeRawArgs`, `approvalPreviewBuilder`, `approvalSignatureBuilder`）、`packages/agent_runtime/lib/src/prompts/agent_prompts.dart`、`agent_prompts_test.dart`、`win32_job_exec_test.dart`、`acp_server_test.dart` を確認。後方互換性（既存 `allow_always`・`NON_ALLOWLISTED_EXECUTABLE` 等）および E3 純粋性（`agent_kernel` 非変更、`agent_prompts.dart` の純粋 Dart 維持）に矛盾なし。
- **指摘事項**:
  - **[M-01] Section 6 `変更対象ファイル一覧` の記載漏れ**: `D-004` / `REQ-01` に含まれる `packages/agent_acp/test/acp_server_test.dart`（同一 origin `curl` の 2 回目 `allow_always` キャッシュ統合テスト）が Section 6 の表に未記載のため追加すること。
  - **[M-02] オプション密着表記・特殊引数のフォールバック網羅（`D-001`）**: `curl` の `-XPOST`・`--request=POST`・`--data=...`・`--json=...`・`-dfoo`・大文字小文字混在（`-X post`）・末尾値なし `-X`・`--url=...`・`--next`、および URL 内 `userInfo`（`https://user:pass@host`）やパス区切り付き実行ファイル（`command` に `/` または `\` を含む場合）は、すべて安全側（完全一致シグネチャへのフォールバック）に倒すこと。
  - **[S-01] `localhost` / プライベート IP 判定の網羅性（`D-001`）**: `127.0.0.1` / `localhost` 単体だけでなく、`*.localhost`、`localhost.`、`127.0.0.0/8`、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`169.254.0.0/16`、`0.0.0.0`、IPv6 `::1`・`fc00::/7`・`fe80::/10` を `InternetAddress.tryParse(uri.host)` 等で網羅的に除外すること。
  - **[S-02] `SysExecApprovalScope.build` の引数正規化契約と `hadShellMeta` 導出**: `SyscallGate` 経由では Stage 1 `normalizeRawArgs` 済みだが、`SysExecApprovalScope.build` 内でも `SysExecCommandNormalizer.containsShellMetacharacters` を再評価（または `List<String>? args` 時に正規化）し、単体呼び出しや `args: null` + メタ文字時でも安全にフォールバックさせること。
  - **[S-03] プレビュー文言統一と基準テスト件数注記**: Section 2 の `Session scope (allow_always):` を `REQ-02`/`D-002` の `Session allow_always scope:` に揃えること。また Plan B・Plan A 適用済みのため現時点の基準テスト数は `42 files / 252 tests`（`env_manifest.md` 初版の `244` から +8）である。

### 独立受け入れ判定（fm-dev-acceptance / IT-02）

- **受け入れ担当 / 工程**: `fm-dev-acceptance`（`IT-02`） / 2026-11-21
- **判定**: **`PASS`**（Critical: `0`, Blocking: `0`）
- **要求別検証結果**:
  - **REQ-01（`SysExecApprovalScope.build` / `allow_always` origin 単位シグネチャ）**: 合格。`sys_exec_classifier.dart` の `SysExecApprovalScope.build` および `win32_job_exec_driver.dart` の `approvalSignatureBuilder` を確認。シェルメタ文字なし・単一 `http`/`https` URL・送信/変更系オプションなし・非プライベートホストの `curl`/`wget` のみ `exec:net_read:<exeBase>\u0000<origin>\u0000<workingDir>` を生成し、異なる origin・送信/変更系フラグ（`M-02`: `-XPOST` / `--request=POST` / `--data=` / `--json=` / `-dfoo` / 末尾 `-X` / `--url` / `--next` / `-:` / `userInfo` / パス修飾 exe）・`localhost`・プライベート/リンクローカル/ループバック IPv4/IPv6（`S-01`）・シェルメタ文字（`S-02`）はすべて完全一致シグネチャへフォールバックすることを確認。`win32_job_exec_test.dart` および `acp_server_test.dart`（`M-01` 反映済み・同一 origin `curl` 2 回目 `permCount == 1`）で検証済み。
  - **REQ-02（`EXTERNAL_NETWORK_COMMAND` 分類と `ApprovalPreview` スコープ表示）**: 合格。`SysExecClassifier` が `curl` / `wget` / `invoke-webrequest` / `iwr` / `invoke-restmethod` / `irm` を `RingDecision.askUser` + `EXTERNAL_NETWORK_COMMAND: Direct network command via sys_exec (prefer delegating web lookup to web_researcher).` で分類し、`win32_job_exec_driver.dart` の `approvalPreviewBuilder` が `Session allow_always scope: ${scope.scopeDescription}` と `metadata['approvalScope']` を出力することをコードおよび `win32_job_exec_test.dart` で確認（注: Section 2 成功結果の `Session scope (allow_always):` 表記のみ `r1` 残存だが、実装・`REQ-02`・`D-002`・テストは `Session allow_always scope:` で統一済み）。
  - **REQ-03（`LeadAgent` プロンプト誘導）**: 合格。`agent_prompts.dart` の `leadStage2Instruction` ルール 10 に `curl` / `wget` / `Invoke-WebRequest` 直利用抑止の 1 文が追記され、`agent_prompts_test.dart` の期待値と一致していることを確認。
  - **REQ-04（静的解析・全テスト・E3 純粋性・成果物照合）**: 合格。
    - `mise exec -- dart analyze`: `No issues found!`（0 件）
    - `mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp`（`OPENROUTER_API_KEY` 解除下）: `256` テスト全 pass・スキップ `0` 件（`stage3_architecture_and_purity_test.dart` 合格含む）
    - `env_manifest.md` 再ビルド済み 3 `.exe` 独立照合（実バイトサイズ / SHA-256 完全一致）:
      - `build/agent_os_daemon.exe`: `10111488` bytes / `51AC9912B6651EE674BAF6510A2E3F28E1B94C5DE507A23DBDDC50E8B4EBF92F`
      - `build/acp_cli_client.exe`: `6854144` bytes / `4163BFD44B53182257C865677D66B9133F01787FCBFD66558A61838CAFCB0085`
      - `build/acp_kanban_app.exe`: `7175168` bytes / `6644ACDAC68FB9132ED5A22207BDF7BDCB590658232EB17EB3B5B0DF0EE77A53`

### 変更履歴

| 版 | 日付 | 変更内容 | 担当 |
| --- | --- | --- | --- |
| `r1` | 2026-11-21 | 初版作成（Light プラン） | Antigravity |
| `r2` | 2026-11-21 | `PT-02` レビュー指摘反映（`M-01`: `acp_server_test.dart` 追記、`M-02`: attached/equals・`--url`/`--next`・`userInfo`・パス修飾 exe の厳格フォールバック、`S-01..S-03` 反映） | Antigravity |
