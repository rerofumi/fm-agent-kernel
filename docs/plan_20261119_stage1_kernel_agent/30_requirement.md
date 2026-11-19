# 30_requirement.md — 要求一覧・受け入れ条件・検証範囲

関連文書:
- 背景・構想: [10_claim.md](./10_claim.md)
- 利用場面・対象環境・範囲境界: [20_app_requirement.md](./20_app_requirement.md)
- 設計仕様・優先順位・副作用境界（一元正本）: [40_specification.md](./40_specification.md)（および分割仕様 [42_spec_kernel_and_llm.md](./42_spec_kernel_and_llm.md) / [42_spec_vfs_jj_and_exec.md](./42_spec_vfs_jj_and_exec.md) / [42_spec_acp_and_packaging.md](./42_spec_acp_and_packaging.md)）
- 技術調査・実測根拠: [docs/cheatsheet/index.md](../cheatsheet/index.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 要求一覧（REQ-01 〜 REQ-11）

本計画の対象は `docs/02_development_step.md` の **Stage 1 全体（Step 1-1・Step 1-2・Step 1-3）** である。ID は本計画内で一意に採番し、優先順位・状態遷移・副作用許容境界の詳細定義は各 `対象設計` ID（`40_specification.md` / `42_spec_*.md`）を正本とする（仕様の二重定義は行わない）。

| ID | 要求・根拠・対象設計 | 受け入れ条件 | 確認方法 / 証跡区分 |
| :--- | :--- | :--- | :--- |
| **REQ-01** | **防波堤カーネル骨格（`SyscallGate` 単一通過・`PCB`/Ring 構造・モジュラー境界）と I/O 出力サイズ強制キャップ**<br>根拠: `01_idea.md`（カーネル＝システムコール層、モジュラー設計）、`02_development_step.md` Step 1-1（実装1・事象2）、`90_status.md`（シングルプロセス安全ロック＋Stage 2/3 拡張境界）<br>対象設計: `[D-001]`, `[D-002]`, `[D-004]`, `[D-005]`, `[D-006]` | 1. **カーネル分離と単一通過**: コアカーネル（Ring 0：`agent_kernel`）が `[D-001]` の依存分離境界を満たし、単一 `LeadAgent`（Ring 2）からの全システムコール（ファイル・VCS・推論・外部実行）が `[D-002]` `SyscallGate.invoke` と `[D-005]` `PCB` を経由して調停されること。<br>2. **シングルプロセス安全ロックとクオータ保護**: Stage 1 では `[D-005]` により子プロセス生成がロックされ、クオータ超過時も `[D-004]` の構造化エラーで安全に阻止されること。<br>3. **I/O キャップ正常・境界・異常系（事象 1-1-2）**: `[D-006]` の上限以内の出力は欠損なく返却され、1 万行超の巨大ファイル読取や大量ヒット検索など上限を超える出力では、構造化メタ情報を保持したまま先頭・末尾サマリ＋省略通知へ置換（全文は退避保存）され、1 ターンでコンテキスト溢れや異常終了を起こさず後続推論を継続できること。 | - **`E3`**: `packages/agent_kernel` に `[D-001]` 禁止依存（`http`, `ffi`, `win32`, `mirrors`, 上位パッケージ）がゼロであり、全システムコールが `SyscallGate.invoke` 単一通過であることを確認。<br>- **`E1`**: `sys_spawn` の `EPERM` ロック・クオータ超過時の `EDQUOT`・`[D-006]` 上限ちょうど（`200` 行 / `16,384` byte）の無改変返却・超過時の UTF-8 文字境界保護＋`.agent_os/io_spill/` 全文退避＋構造化メタ（`sha256`, `totalLines`, `exitCode`）保持を自動テストで確認。<br>- **`E2`**: 中盤（省略領域）に正解がある 1 万行超ファイルと大量ヒット検索から、エージェントが `sys_read_lines(startLine, endLine)` で範囲を絞り直して正答完走することを実機観測。 |
| **REQ-02** | **Read-Only ファイル探索システムコールと `JjDriver` 非破壊読取によるリポジトリ自律読解**<br>根拠: `02_development_step.md` Step 1-1（実装3・事象1）、`03_vfs_drivers_and_modularity.md` §3.2〜3.3<br>対象設計: `[D-003]`, `[D-004]`, `[D-011]`, `[D-012]`, `[D-014]` | 1. **ファイル探索**: `/workspace` 名前空間に対する `[D-012]` `sys_read_lines`（行範囲読取および CAS 用 SHA-256 ハッシュ取得）、`sys_glob`、`sys_grep` が正確に動作すること。<br>2. **スコープ外・保護領域・異常入力防御**: `[D-003]`・`[D-011]` の保護内部パス（`.jj`, `.git`, `.agent_os`, `.env*`）および `/workspace` スコープ外アクセス（ジャンクション脱出含む）、未存在パス、不正行番号指定に対し、例外クラッシュせず `[D-004]` の構造化エラー（`EACCES` / `ENOENT` / `EINVAL`）を返すこと。<br>3. **`JjDriver` 非破壊読取**: `[D-003]`・`[D-014]` に従い、`sys_jj_status`, `sys_jj_log`, `sys_jj_diff` が Read-Only 探索時や履歴参照時にワーキングコピーのスナップショット副作用を起こさず（実行前後で `jj op log` 先頭 `op_id` が完全不変）、かつ作業チェンジ編集中は最新差分と整合して取得できること。<br>4. **リポジトリ自律読解（事象 1-1-1）**: エージェントがリポジトリ内のコードと `jj log` / `jj diff` を自律的に読み解き、設計や変更内容の質問に事実通り回答できること。 | - **`E1`**: `.jj` / `.git` / `.agent_os` / `.env*` に対する Read/Write 双方の直指定 `EACCES`（`PROTECTED_INTERNAL_PATH`）と全体 `glob` / `grep` からの自動除外、`../`・絶対パス・Windows ジャンクション脱出を含むスコープ外 `EACCES`、不正引数 `EINVAL`、および**未スナップショット変更が存在する状態**での `TxState.readOnly` 読取前後で `jj op log` 先頭 `op_id` が完全不変であることを自動テストで確認。<br>- **`E2`**: 未スナップショット変更を含む実 `jj` リポジトリへコード内容と `jj log` / `jj diff` の質問を与え、自律ツール呼び出しによる正答と前後での `jj op log` 先頭 `op_id` 完全不変を実機観測。 |
| **REQ-03** | **Canonical IR と 3 LLM プロバイダ（`Local Ollama`・`OpenRouter`・`Ollama Cloud`）対応および毎ターン切替**<br>根拠: `01_idea.md`（プロンプト毎のプロバイダ・モデル切替、3プロバイダ）、`02_development_step.md` Step 1-1（実装2・事象3）、`90_status.md`（3プロバイダすべての実機 API 動作確認合意）<br>対象設計: `[D-002]`, `[D-004]`, `[D-007]`, `[D-008]`, `[D-009]` | 1. **Canonical IR とモデル解決優先順位**: 会話・思考・システムコール要求/結果が `[D-007]` の Prefix 保持 Canonical IR で保持され、`[D-002]` §2.1(2) のモデル優先順位契約に従ってターン境界でモデルが決定・射影されること。<br>2. **3 プロバイダすべての実機動作（合意事項）**: `[D-008]`・`[D-009]` により `local-ollama`（API キー不要）・`openrouter`・`ollama-cloud` の **3 プロバイダすべて** で実機 API 推論およびシステムコール（Tool Call）往復が正常完了すること。<br>3. **ターン毎プロバイダ切替（事象 1-1-3）**: 同一セッション内で 3 プロバイダを跨いで毎ターン切り替えても、State Spill（`400 Bad Request` や履歴破損）を起こさず前ターンの文脈を引き継いで応答できること。<br>4. **通信異常系と秘密保護**: API キー未設定・接続失敗・不正モデル指定時に未捕捉例外で落ちず構造化エラー（`EPROVIDER` / `EINVAL`）を返し、`[D-004]` に従い API キー実値をログ・エラー・画面出力へ一切露出させないこと。 | - **`E1`**: `[D-007]` 射影（9 文字英数字 `tool_call_id` ペア変換、同一モデル時のみ `rawReasoningDetails` 保持・異モデル時剥離）、`[D-002]` モデル 4 段優先順位（1 ターン `_meta["fm_agent_os/modelOverride"]` 適用後に次ターンで元のセッション選択モデルへ戻ること）、`OLLAMA_HOST=0.0.0.0` 正規化（`[D-008]`）、OpenRouter Sticky Routing & `anthropic/*` `cache_control` 射影（`[D-009]`）、API キー未設定時 `EPROVIDER`、秘密 `"<REDACTED>"` 置換を自動テストで確認。<br>- **`E2`**（前提 `P-1`・`P-2`）: 3 プロバイダすべての実 Tool Call 往復、および同一セッション内 `local-ollama` → `openrouter` → `ollama-cloud` → `local-ollama` 連続切替（`400 Bad Request` ゼロ・文脈継承）を実機観測。 |
| **REQ-04** | **`strace` 相当システムコール監査ログ（`syscalls.jsonl`：`jjOpId` 紐付け）と API 入出力・KV キャッシュ監視ログ（`llm_io.jsonl`）**<br>根拠: `01_idea.md`（監査ログ、API入出力・キャッシュヒット監視）、`02_development_step.md` Step 1-1（実装4・事象4）、`03_vfs_drivers_and_modularity.md` §3.5<br>対象設計: `[D-002]`, `[D-003]`, `[D-004]`, `[D-010]`, `[D-014]` | 1. **`syscalls.jsonl` 完全記録とロールバック耐性**: `[D-002]` Stage 8・`[D-010]` に従い全終了経路のシステムコールが `jjChangeId` / `jjOpId` 付きで記録され、非 null の `jjOpId` が実在 Operation と一致し、`[D-003]` によりリポジトリを汚さずロールバック後もログが保全されること。<br>2. **`llm_io.jsonl` 監視記録**: 3 プロバイダすべての推論について、`[D-010]` スキーマでトークン・キャッシュ統計（未返却時は `cachedTokens: null`）と応答時間が記録され、`[D-004]` により秘密情報が一切露出しないこと。<br>3. **連続ターンでのキャッシュヒット上昇（事象 1-1-4）**: キャッシュ統計返却対応プロバイダ／モデルにおいて、同一モデルで連続ターン実行した際、`llm_io.jsonl` 上でトークン消費量とともに **`cachedTokens`（および `cacheHitRate`）の上昇** が数値で確認できること。 | - **`E1`**: 全終了経路（正常・拒否・Hook 遮断・引数不正・例外）での `syscalls.jsonl` 出力、`cachedTokens: null` 許容スキーマ、および `[D-004]` 秘密マスクを自動テストで確認。<br>- **`E2`**（前提 `P-1`・`P-2`）: 全非 null `jjOpId` の `jj op show` 実在一致、`sys_tx_rollback`（`jj op restore`）後も `.agent_os/logs/` が消えず `jj status` にも出ないこと、および最小キャッシュ閾値（固定 Prefix `>= 2,048` tokens）を満たす同一モデル連続ターン（`local-ollama` `/api/chat` ストリーム、および `openrouter` 対応モデル）で 1 ターン目→2 ターン目の `cachedTokens`・`cacheHitRate` が数値上昇することを実機観測。 |
| **REQ-05** | **`JjDriver` トランザクション制御（開始時 `op_id` 記録・`jj new` 作業分離・`describe`/`squash` 確定・`jj op restore` 完全ロールバック）**<br>根拠: `02_development_step.md` Step 1-2（実装1・事象1・事象2）、`03_vfs_drivers_and_modularity.md` §3.1〜3.3<br>対象設計: `[D-003]`, `[D-014]`, `[D-015]` | 1. **直列化境界と作業チェンジ分離（事象 1-2-1）**: `[D-003]`・`[D-014]`・`[D-015]` に従いリポジトリ更新を直列化し、開始 `baseOpId` を記録して `jj new` で作業チェンジ（`@`）を分離する。人間が未コミット（未スナップショット）変更を持っている状態で依頼しても、**人間の直前チェンジ（`@-`）の内容・差分が 1 バイトも汚れない** こと。<br>2. **1 発完全ロールバック（事象 1-2-2）**: エージェントが複数ファイルを編集・追加して `dart test` 等に失敗した際、`sys_tx_rollback`（`jj op restore`）1 回でファイルツリーおよびチェンジ状態が開始前へ 100% バイト一致で巻き戻ること。<br>3. **非対話確定と異常系保護**: `sys_tx_describe` / `sys_tx_squash` が対話エディタ待ちハングなく確定でき、セッション開始前や未記録 `op_id` への不正復元要求は `EACCES` で安全に拒否されること。 | - **`E1` / `E2`**: 人間の未スナップショット変更がある状態からの変更分離・`@` 編集後も `@-` 全ファイルが SHA-256 バイト完全一致すること、`sys_tx_rollback` 1 回で新規ファイル消滅＋既存ファイル 100% バイト一致復元すること、`@-` と `@` 双方に非空 description がある状態での `sys_tx_squash`（`-u` / `-m`）非対話成功、およびセッション開始前／未記録 `op_id` 指定時の `EACCES` 拒否を自動テスト（`E1`）と実 `jj` リポジトリ観測（`E2`）で確認。 |
| **REQ-06** | **CAS（読み取り時 SHA-256 ハッシュ照合）付き編集システムコール（`sys_edit_block`, `sys_write_file`）**<br>根拠: `02_development_step.md` Step 1-2（実装2）、`05_three_walls_and_step_plan.md` §5.2 段階A<br>対象設計: `[D-004]`, `[D-011]`, `[D-012]`, `[D-013]` | 1. **CAS 一致時の安全編集**: `[D-013]` に従い、`sys_edit_block`（一意ブロック置換）および `sys_write_file`（既存全体更新、または未存在確認付き新規作成）が事前読取 SHA-256 ハッシュ一致確認の上で書き込み・スナップショット同期を行い、更新後の新 SHA-256 ハッシュを返すこと。<br>2. **競合・誤操作の完全拒否と無変更保証**: ① 読取後のファイル変化による SHA-256 不一致（`ECONFLICT`）、② 未読既存ファイルへの新規扱い上書き（`EEXIST`）、③ `oldBlock` 0 件一致または複数重複一致（`ECONFLICT`）、④ 保護パス／スコープ外指定（`EACCES`）の全失敗時に、対象ファイルとリポジトリ状態を一切変更せず構造化エラーを返し、再読取から編集回復できること。 | - **`E1` / `E2`**: CAS 一致編集成功と直後 `sys_jj_diff` 反映、ハッシュ不一致 `ECONFLICT`・未読既存ファイル書込 `EEXIST`・`oldBlock` 0 件/重複一致 `ECONFLICT`・保護/スコープ外 `EACCES` の**全失敗ケースで対象ファイル SHA-256 と `jjOpId` が不変**であること、および `ECONFLICT` からの再読取回復を自動テスト（`E1`）と実エージェント観測（`E2`）で確認。 |
| **REQ-07** | **Windows Job Object（Win32 FFI）を用いた外部コマンド隔離実行 `sys_exec` と子孫プロセス一括強制終了**<br>根拠: `01_idea.md`（Windows Native DLL 活用）、`02_development_step.md` Step 1-2（実装3・事象3）、`01_kernel_and_process_architecture.md` §1.2 第2層<br>対象設計: `[D-006]`, `[D-016]` | 1. **Win32 Job Object 隔離実行**: `[D-016]` に従い Win32 `kernel32.dll` Job Object を用いて `/workspace` 内で外部コマンドを実行し（子プロセス環境へ API キーを漏洩させず、短命コマンドの終了レースも安全に処理）、終了コードおよび `[D-006]` キャップ適用済み標準出力・標準エラーを取得できること。<br>2. **タイムアウト・中断時の子孫一括終了（事象 1-2-3）**: 無限待機コマンドや子・孫プロセスを生成するスクリプトを `sys_exec` させた際、タイムアウト到達時およびキャンセル時に Job Object ごと強制終了され、**親プロセスだけでなく孫プロセスを含む全子孫プロセスが OS 上にゾンビ残留せず 0 件になる** こと。 | - **`E3`**: `[D-016]` の 144 byte 非 `@Packed` 構造体（offset 16 = `0x2000`、`BREAKAWAY_OK` 無し）FFI 実装と、子プロセス環境変数からの API キー除外をコード構造確認。<br>- **`E1` / `E2`**: 短命コマンドのレース誤エラーなし、および子・孫 PID を標準出力へ即時出力して待機するスクリプトのタイムアウト／キャンセル直後に OS プロセス照会で親・孫ともに生存 0 件であることを自動テスト（`E1`）と実機観測（`E2`）で確認。 |
| **REQ-08** | **`beforeSyscall` Hook 機構と Anti-Git-Habit Guard（生 `git` / `jj` 遮断と `sys_jj_*` への自律誘導）**<br>根拠: `01_idea.md`（フックのプラグイン化）、`02_development_step.md` Step 1-2（実装4・事象4）、`03_vfs_drivers_and_modularity.md` §3.4<br>対象設計: `[D-002]`, `[D-017]` | 1. **承認前 Hook インターセプト基盤**: `[D-002]`（Stage 3 → Stage 4 順序）および `[D-017]` に従い、Ring 2 承認ゲートや外部プロセス起動の前にシステムコールを検査・遮断しガイドエラーを返せること。<br>2. **生 VCS コマンド遮断と自律修正（事象 1-2-4）**: `sys_exec` で生の `git` や生の `jj`（単体・連結・パイプ・シェルラッパー経由を含む対象パターン）を実行しようとした際、承認ダイアログを出さず外部プロセス未起動のまま `HOOK_BLOCKED`（`EPERM`）と誘導メッセージを返し、エージェントが同一ターン次ステップで自律的に `sys_jj_status` / `sys_jj_diff` 等を使い直す様子が `syscalls.jsonl` で確認できること。 | - **`E1`**: 単体・連結・パイプ・シェルラッパー経由の生 `git` / `jj` が **`ApprovalHandler` 呼び出し 0 回（`[D-002]` Stage 3→4 順序の外部証明）・外部プロセス未起動** のまま `HOOK_BLOCKED`（`EPERM`）となり、`dart test test/git_helper_test.dart` は誤遮断されないことを自動テストで確認。<br>- **`E2`**: 生 `git` 試行遮断（承認プロンプト未発火）→追加人間入力なしに同一ターン次ステップで `sys_jj_status` / `sys_jj_diff` へ自律切替する `syscalls.jsonl` 証跡を実機観測。 |
| **REQ-09** | **ACP（JSON-RPC 2.0 over `stdio`）サーバー分離・リアルタイム通知・簡易 CLI クライアント（`acp_cli_client`）**<br>根拠: `01_idea.md`（ACP による上位 UI 分離、簡易 ACP クライアント、モデル切替 UX）、`02_development_step.md` Step 1-3（実装1・実装3・事象1）<br>対象設計: `[D-018]`, `[D-019]`, `[D-021]` | 1. **ACP `stdio` サーバー純度保護**: `[D-018]` に従いエンジン本体が ACP v1（NDJSON over `stdio`）サーバーとして動作し、`stdout` に非プロトコル出力を一切混入させずにセッション管理・プロンプト応答を行えること。<br>2. **リアルタイム状態通知**: `[D-019]`（ACP Extensibility 準拠）に従い、思考ストリーム、発行中システムコール、`jj diff`、およびトークン／キャッシュ統計がリアルタイム通知されること。<br>3. **簡易 CLI クライアント操作（事象 1-3-1）**: 同梱 `[D-021]` `acp_cli_client` から接続し、対話送信、ストリーム表示、`/status`、`/rollback`、および `/model` による 3 プロバイダ切替が軽快に行えること。<br>4. **プロトコル異常系**: 不正 JSON や未知メソッド受信時にクラッシュせず規定 JSON-RPC エラーを返して継続し、`stdin` EOF 時にクリーン終了すること。 | - **`E1`**: 内部 `print()` 退避により `stdout` 全行が 100% 有効な JSON-RPC NDJSON であること、標準オブジェクト直下に未知キー 0 個で固有統計が `_meta["fm_agent_os/..."]` にあること、不正 JSON `-32700` 継続・未知メソッド `-32601`・`stdin` EOF 終了を自動テストで確認。<br>- **`E2`**: `acp_cli_client` 接続対話・ストリーム表示・`/status`・`/rollback`・`/model` 3 プロバイダ切替を実機観測。 |
| **REQ-10** | **保護リング（Ring 2）の承認ゲート（`WAITING_APPROVAL` 一時停止・ACP 承認確認・拒否時 `EACCES` 防波堤）**<br>根拠: `01_idea.md`（保護リングとユーザー許可確認、危険操作の防波堤）、`02_development_step.md` Step 1-3（実装2・事象2）、`01_kernel_and_process_architecture.md` §1.4<br>対象設計: `[D-002]`, `[D-003]`, `[D-004]`, `[D-016]`, `[D-020]` | 1. **Ring 2 ポリシー選別と一時停止**: `[D-002]` §2.3 の選別規則に従い、Read 系・作業チェンジ仮編集・定型安全検証コマンドは即時実行される一方、`sys_tx_squash` および非定型 `sys_exec` では `[D-020]` により実行前に `WAITING_APPROVAL` で確実に一時停止（`[D-003]` 承認前副作用ゼロ）し、ACP クライアントへ `jj diff` やコマンド内容を添えて承認確認を要求すること。<br>2. **承認・拒否・キャンセルの防波堤挙動（事象 1-3-2）**: **承認時は処理が再開・完遂** し、**拒否時は副作用ゼロのまま `DENIED_BY_USER` 監査記録と `EACCES` を返してエージェントがクラッシュせず代替提案またはロールバックへ移行** し、待機中キャンセル時は副作用ゼロで中断すること。 | - **`E1`**: `[D-002]` §2.3 の即時許可 5 条件境界（`dart format` フラグ無し等が `WAITING_APPROVAL` になることを含む）、一時停止中および `reject_once` 拒否前後で `@-`・`@` `commit_id` と作業ファイル SHA-256 が完全不変かつ `DENIED_BY_USER` / `EACCES` 記録、`session/cancel` で副作用ゼロ中断することを自動テストで確認。<br>- **`E2`**: `acp_cli_client` 上での ①承認→確定完了と、②拒否→副作用ゼロ `EACCES`→代替提案/ロールバック移行の双方を実機観測。 |
| **REQ-11** | **`dart compile exe` による単一ネイティブ実行ファイル化と Stage 1 通し完走**<br>根拠: `01_idea.md`（Dart で Windows exe にビルド）、`02_development_step.md` Step 1-3（事象3：Stage 1 到達点）、`04_feasibility_and_roadmap.md` §4.1〜4.2<br>対象設計: `[D-001]`, `[D-021]`, `[D-022]` | 1. **ネイティブ EXE ビルドと SDK 非依存起動**: `[D-022]` に従いエンジン本体（`agent_os_daemon.exe`）および同梱クライアント（`acp_cli_client.exe`）が `dart compile exe` でエラーなくビルドでき、Dart SDK 非存在環境でも単体起動・ACP ハンドシェイクできること。<br>2. **Stage 1 到達点の統合動作（事象 1-3-3）**: コンパイル済み両 `.exe` バイナリ同士の接続により、「リポジトリ読解 → モデル切替 → `jj new` 分離編集（`@-` 保護） → Job Object 経由 `dart test` → `jj diff` 提示と Ring 2 承認 `squash`（およびロールバック）」が AOT 実行時エラーなく完走すること。 | - **`E1`**（前提 `P-1`）: `dart analyze` + `dart compile exe`（`agent_os_daemon.exe` & `acp_cli_client.exe`）成功、および **`PATH` から `dart-sdk\bin` を除外した子プロセス環境での起動・ACP ハンドシェイク成功** を自動確認。<br>- **`E2`**（前提 `P-1`・`P-2`）: 最新ソースからビルドし `env_manifest.md` と照合した両 `.exe` による Stage 1 通しシナリオ完走を実機観測。 |

---

## 2. `docs/02_development_step.md`（Stage 1）との網羅性トレーサビリティ表

Step 1-1〜1-3 の全実装項目および全確認事象（計 11 項目＋3 プロバイダ実機確認合意）と `REQ-01`〜`REQ-11` の対応は以下の通りであり、漏れはない。

| Step | 原典の「実装するもの」 / 「確認できる事象」 | 対応 REQ |
| :--- | :--- | :--- |
| **Step 1-1** | 実装: `SyscallGate` 単一通過点 ＋ I/O 出力サイズ強制キャップ | `REQ-01` |
| **Step 1-1** | 実装: Canonical IR ＋ `LlmDriver`（`Local Ollama` / `OpenRouter` / `Ollama Cloud`） | `REQ-03` |
| **Step 1-1** | 実装: Read-Only Syscall（`sys_read_lines`, `sys_glob`, `sys_grep`）＋ `JjDriver` 読取系（`sys_jj_status`, `sys_jj_log`, `sys_jj_diff`） | `REQ-02` |
| **Step 1-1** | 実装: `syscalls.jsonl`（`jjOpId` 紐付け）＋ `llm_io.jsonl`（キャッシュ監視） | `REQ-04` |
| **Step 1-1** | **事象 1-1-1**: コードと `jj log` / `jj diff` を自律読解し質問に回答 | `REQ-02` |
| **Step 1-1** | **事象 1-1-2**: 1万行巨大ファイル・大量検索で I/O キャップが働きコンテキスト一撃死しない | `REQ-01` |
| **Step 1-1** | **事象 1-1-3**: `Local Ollama` ⇄ `OpenRouter` 等の毎ターン切替で履歴維持（＋**3プロバイダ全実機確認**） | `REQ-03` |
| **Step 1-1** | **事象 1-1-4**: `llm_io.jsonl` で同一モデル連続ターン時のトークン量と `cached_tokens` 上昇を確認 | `REQ-04` |
| **Step 1-2** | 実装: `JjDriver` トランザクション制御（`op_id` 記録、`jj new`、`abandon`/`op restore`、`describe`/`squash`） | `REQ-05` |
| **Step 1-2** | 実装: CAS（SHA-256 ハッシュ照合）付き編集（`sys_edit_block`, `sys_write_file`） | `REQ-06` |
| **Step 1-2** | 実装: Windows Job Object（Win32 FFI）外部コマンド実行 `sys_exec` | `REQ-07` |
| **Step 1-2** | 実装: `beforeSyscall` Hook 機構 ＋ Anti-Git-Habit Guard | `REQ-08` |
| **Step 1-2** | **事象 1-2-1**: 人間の未コミット変更状態で依頼しても新 `@` が切られ ` @-` が 1 バイトも汚れない | `REQ-05` |
| **Step 1-2** | **事象 1-2-2**: コード書換→`dart test` 失敗時に `sys_tx_rollback`（`jj op restore`）1 発で完全復元 | `REQ-05` |
| **Step 1-2** | **事象 1-2-3**: 終わらないコマンドや孫プロセス生成スクリプトがタイムアウト時にゾンビゼロで一括終了 | `REQ-07` |
| **Step 1-2** | **事象 1-2-4**: 生 `git status`/`git diff` 等を Hook が即遮断し次ターンで `sys_jj_*` を使い直す監査ログ確認 | `REQ-08` |
| **Step 1-3** | 実装: ACP（JSON-RPC 2.0 over `stdio`）サーバー化 ＋ 簡易 CLI クライアント（`acp_cli_client`） | `REQ-09` |
| **Step 1-3** | 実装: Ring 2 承認ゲート（`WAITING_APPROVAL` 一時停止・ACP 承認確認） | `REQ-10` |
| **Step 1-3** | 実装: 思考・実行中 Syscall・`jj diff`・トークン/キャッシュ統計のリアルタイム通知 | `REQ-09` |
| **Step 1-3** | **事象 1-3-1**: `acp_cli_client` から接続しプロンプト送信と `/model` 切替が軽快に行える | `REQ-09` |
| **Step 1-3** | **事象 1-3-2**: 確定や要注意コマンド直前で一時停止し、承認→進行、拒否→`EACCES`→別案/ロールバック | `REQ-10` |
| **Step 1-3** | **事象 1-3-3（到達点）**: `dart compile exe` で単一実行ファイル化できる実用 `jj` シングルエージェント完成 | `REQ-11` |

---

## 3. 適用制約・非機能要求・検証範囲の方針

### 3.1 適用されるアーキテクチャ・セキュリティ制約
1. **シングルプロセス安全ロックと拡張境界の両立**: Stage 1 ではエージェントプロセスを単一の `LeadAgent` に固定するが、Stage 2/3 で破壊的改修を生まないよう `[D-001]`〜`[D-007]` の境界を最初から守る。
2. **秘密情報の絶対非露出**: `OPENROUTER_API_KEY` や `OLLAMA_API_KEY` 等の秘密情報の実値そのものは、ソースコード、コミット物、`syscalls.jsonl`、`llm_io.jsonl`、標準出力／エラー出力、子プロセス環境変数（`sys_exec`）、計画・証跡文書のいずれにも露出させてはならない（`[D-004]`, `[D-016]`）。
3. **AOT コンパイル適合**: `dart:mirrors` や AOT 非対応のビルドフックに依存せず、`dart compile exe` で完結動作する設計とする（`[D-022]`）。

### 3.2 非機能の追加要求について（数値目標の新設禁止）
- 本計画はプロトタイピングによる実用シングルエージェント確立を目的としており、利用者から応答レイテンシ目標（秒数 SLO）、スループット、テストカバレッジ率等の数値的な非機能改善要求は提示されていないため、**合意にない性能数値目標や品質水準は新設しない**。
- なお、コンテキスト溢れを防ぐ **I/O 出力サイズ強制キャップ（REQ-01）** および暴走プロセスを防ぐ **コマンドタイムアウト強制終了（REQ-07）** は、防波堤カーネルの機能要求そのものとして検証する。

### 3.3 検証範囲・試験環境分離・開始前提条件（`P-1` / `P-2`）
- **実施する検証**:
  - `E1`（自動テスト・ビルド確認）: 各 REQ の正常系・優先順位境界・副作用ゼロ境界・異常系および `dart analyze` + `dart compile exe` を自動テストで検証する。
  - `E2`（実機操作・実行観測）: モックではなく、**実機の 3 プロバイダ（`local-ollama`・`openrouter`・`ollama-cloud`）**、**隔離した実 `jj` リポジトリ**、および **ビルド済み `.exe`（`agent_os_daemon.exe` ＋ `acp_cli_client.exe`）** を用いて全確認事象を観測し、ログ・リポジトリ状態の証跡を残す。
  - `E3`（実装構造確認）: `[D-001]` パッケージ依存分離および `[D-016]` Win32 Job Object FFI 構造・秘密除外を照合する。
- **試験環境分離・汚染防止・成果物鮮度規則**:
  1. **一時 `jj` リポジトリ fixture 分離**: `E1` / `E2` のテスト対象リポジトリは OS 一時ディレクトリまたは `.planworks/` 配下にテスト単位で `jj git init --colocate` により分離作成・破棄し、本製品リポジトリ（`fm-agent-os-2` 本体）や `docs/` を一切汚染しないこと。
  2. **環境変数非汚染とプロセス回収**: テスト用の環境変数（API キー有無や `OLLAMA_HOST` 等）はプロセスのグローバル環境を書き換えず注入マップで渡してテスト間汚染を防ぎ、外部プロセス・デーモンを起動する全テストは `tearDown` で生成 PID の残留ゼロを確認すること。
  3. **`.exe` 鮮度照合**: `REQ-11` 等の `E2` 実機検証で使用する `.exe` バイナリは最新ソース版からビルドされたものであることを `env_manifest.md` と独立照合すること。
- **実行開始前提条件（`P-1` / `P-2`）と未充足時の扱い**:
  - **`P-1`（Dart SDK `>=3.10.0` 導入）**: 実装ワークスペース構築および全 `E1` / `E2` 実行の開始前提とする（確認手順は `40_specification.md` §3.2 参照）。
  - **`P-2`（`OPENROUTER_API_KEY` / `OLLAMA_API_KEY` の設定）**: クラウド 2 プロバイダを含む実機検証（`REQ-03`・`REQ-04`・`REQ-09`・`REQ-11` の `E2`）の実行開始前提とする。**`P-1` または `P-2` が未設定で対象確認を実行できない場合は、決して `EX` や `pass` に丸めず、`blocked`（工程結果）および `unverified`（Acceptance）として報告・待機する**。
- **検証の対象外**:
  - Stage 2・Stage 3 の機能群（40 ターン超の Clean Page 自動スタブ退避ページング、`Isolate` 子プロセス並列調査、`sys_web_*`、`jj workspace` 並列編集、First-Class Conflicts 多親マージ等）。
  - 性能ベンチマーク・高負荷耐久試験、および外部サードパーティ製 GUI エディタ（Zed 等）を用いた手動 GUI 受け入れ試験（ACP 接続検証は同梱 `acp_cli_client` を正本とする）。

---

## 4. 「おまかせ」合意に基づく細部解釈（`90_status.md` 同期済み：`OM-01` 〜 `OM-08`）

利用者合意済みの「おまかせ」方針に従い、既存文書の要求を一切縮小せず段階的に両立させるため以下の解釈を採用する。

| 判断ID | 論点・選択肢 | 採用解釈 | 理由 | 残る制約・否認時の扱い |
| :--- | :--- | :--- | :--- | :--- |
| **`OM-01`** | Stage 1 のプロセス構造（①PCBなし直呼び / ②単一 `LeadAgent` の `PCB`・`Ring 2`・`SyscallGate` 単一通過＋子生成ロック / ③`Isolate` 並列まで実装） | **②を採用** | Stage 1 のシングルプロセス安全ロックと Stage 2/3 拡張境界の双方を損なわず両立するため | 子プロセス生成（`sys_spawn` 等）は Stage 2 までロックする |
| **`OM-02`** | コンテキスト構造（①先頭に動的情報を混ぜる / ②不変 System 先頭＋追記履歴＋末尾動的情報の Prefix 保持順序で構成） | **②を採用** | Step 1-1 事象4（連続ターンでの `cached_tokens` 上昇）を達成し KV キャッシュ破壊を防ぐため | 自動 Clean Page スタブ退避・フレーム縮小は Stage 2（Step 2-1）の対象とする |
| **`OM-03`** | `sys_write_file` の CAS 条件（①無条件上書き / ②既存更新時は `expectedSha256` 必須、新規作成時は未存在確認必須） | **②を採用** | 未読の既存ファイルを誤って丸ごと上書き破壊する事故を防ぎ CAS 要件を貫徹するため | 既存ファイルの `sys_write_file` 更新には事前読取ハッシュが必要 |
| **`OM-04`** | Ring 2 承認ゲート対象（①`squash` のみ / ②仮編集・全テストも毎回承認 / ③Read・`@` 仮編集・事前許可の定型安全テストは即時許可、最終 `squash` と一般/外部影響 `sys_exec` を `ASK_USER`） | **③を採用** | `01_kernel` §1.4 と `02_development_step.md` Step 1-2/1-3 の記述を矛盾なく両立するため | 定型安全コマンドの具体的判定規則は `40_specification.md` `[D-002]` §2.3 に定義済み |
| **`OM-05`** | `dart compile exe` 対象（①エンジンのみ / ②エンジンと `acp_cli_client` 双方を `.exe` 化して別プロセス `stdio` 接続可能にする） | **②を採用** | Dart VM 非依存のネイティブバイナリ同士で ACP 分離通信と Stage 1 到達点を完結実証できるため | Stage 1 のドライバ・ツール・Hook はコンパイル時登録（`[D-022]`）とする |
| **`OM-06`** | 3 プロバイダでの `cached_tokens` 検証（①非対応モデルでも `>0` 必須 / ②3 プロバイダ全実機疎通・切替・記録を必須とし、`cached_tokens` 上昇はキャッシュ統計返却対応プロバイダ/モデル条件で実測） | **②を採用** | 外部 API 仕様差とエンジンの Prefix 保持機能を切り分け、3 プロバイダ合意と事象 1-1-4 を両立するため | 各プロバイダの統計フィールド仕様は `PT-01` 実測（`A-03`）に基づき確定済み |
| **`OM-07`** | Ollama（Local / Cloud）ドライバの API 選択（①OpenAI 互換 `/v1/chat/completions` に統一 / ②Ollama Local・Cloud はネイティブ `/api/chat`、OpenRouter は `/v1/chat/completions` を採用） | **②を採用** | `PT-01` 実測で Ollama `0.40.16` の `/v1/chat/completions` は `stream: true` 時に `cached_tokens` が常に `0` となる一方、ネイティブ `/api/chat` はストリーム＋Tool Call でも `prompt_eval_cached_count` を正確に返すため | Canonical IR は共通に保ち、`OllamaDriver`（`[D-008]`）と `OpenRouterDriver`（`[D-009]`）でワイヤ変換を分離する |
| **`OM-08`** | ACP プロトコル実装範囲と拡張方式（①独自 JSON-RPC 定義 / ②ACP v1 公式仕様準拠＋標準 `session/set_config_option` でモデル切替＋`_meta["fm_agent_os/..."]` / `_fm_agent_os/...` で固有統計・ロールバック拡張） | **②を採用** | ACP 公式 Extensibility 規約（ルート直下の未知フィールド禁止）を守りつつ、一般 ACP クライアント互換と `acp_cli_client` の全機能を両立できるため | 標準オブジェクト直下に独自フィールドを追加しない（`[D-018]`, `[D-019]`） |

---

## 5. 初回技術確認項目（`A-01`〜`A-05`）の解消結果と残る実行前提条件

初版策定時に抽出した技術調査項目（分類 A）および利用者判断項目（分類 B）はすべて以下の通り解消・確定済みであり、**未解決の要求曖昧さは 0 件** である。

| 項目ID | 当初の確認論点 | 調査・実測および設計による確定結果 | 参照先・残る実行前提 |
| :--- | :--- | :--- | :--- |
| **`A-01`** | ローカル Dart SDK と `jj` CLI 構文・非対話オプション | `jj 0.46.0` を本機実測し、`jj git init --colocate`、カスタム JSON Lines `-T`（`conflict`/`empty` 補完）、非対話 `squash -u`/`-m`、`op restore` を確定。Dart SDK は未導入のため開始前提 `P-1` としてゲート化。 | `docs/cheatsheet/jujutsu_cli_046.md`, `[D-014]`, `[D-015]`, `[D-022]` / **前提 `P-1`** |
| **`A-02`** | `jj` の `--ignore-working-copy` と編集後スナップショット整合 | `TxState.readOnly` 中は `--ignore-working-copy` で `op_id` 不変を保証し、初回変更時に `baseOpId` スナップショット＋`jj new` 分離、変更直後に単一ミューテックス内で明示スナップショット同期を行う契約で確定。 | `40_specification.md` `[D-003]`, `[D-014]`, `[D-015]` |
| **`A-03`** | 3 プロバイダ API 仕様・環境変数・キャッシュ統計フィールド | Local Ollama `0.40.16` 実測により `/api/chat`（`prompt_eval_cached_count`）を採用、OpenRouter は `/api/v1/chat/completions`（Sticky Routing + Claude `cache_control` + `cached_tokens`）で確定。クラウド 2 種の API キー設定を開始前提 `P-2` として明記。 | `docs/cheatsheet/llm_providers_and_cache.md`, `[D-008]`, `[D-009]`, `[D-010]`, `OM-07` / **前提 `P-2`** |
| **`A-04`** | ACP メソッド・モデル切替・固有統計スキーマ | ACP v1（`protocolVersion: 1`）準拠、`session/set_config_option(configId: "model")`、`_meta["fm_agent_os/..."]` テレメトリ格納、`_fm_agent_os/tx_rollback` で確定。 | `docs/cheatsheet/acp_protocol.md`, `[D-018]`〜`[D-021]`, `OM-08` |
| **`A-05`** | Win32 Job Object FFI とネスト環境・AOT 適合性 | Windows 11 64-bit 実測により `kernel32.dll` 144 byte 構造体（offset 16 = `0x2000`、Build Hooks 不要）でネスト Job 下でも親・子・孫プロセス残留 0 件となることを確認済み。 | `docs/cheatsheet/env_and_dart_windows.md`, `[D-016]`, `[D-022]` |
| **分類 B** | 利用者の製品判断待ち事項 | **該当なし（0 件）**（Stage 1 範囲、3 プロバイダ実機確認、および細部おまかせ判断がすべて合意済み）。 | `90_status.md` |
