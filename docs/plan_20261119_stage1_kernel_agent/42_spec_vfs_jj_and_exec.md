# 42_spec_vfs_jj_and_exec.md — VFS 名前空間・探索/CAS 編集・JjDriver トランザクション・Win32 Job Object・Hook 仕様

関連文書:
- 全体構造・優先順位・副作用境界（正本）: [40_specification.md](./40_specification.md)
- 要求・受け入れ条件: [30_requirement.md](./30_requirement.md)（対象: `REQ-02`, `REQ-05`, `REQ-06`, `REQ-07`, `REQ-08`）
- 技術調査・実測根拠: [jujutsu_cli_046.md](../cheatsheet/jujutsu_cli_046.md), [env_and_dart_windows.md](../cheatsheet/env_and_dart_windows.md)

---

## 1. VFS プライベート名前空間とファイル探索・CAS 編集（`REQ-02`, `REQ-06`）

### 1.1 VFS プライベート名前空間と境界防御

D-011: VFS プライベート名前空間（/workspace）とパス境界防御

対応要求: `REQ-02`, `REQ-06`（副作用境界: `[D-003]`, エラー体系: `[D-004]`）

#### 配置パス
- `packages/agent_kernel/lib/src/vfs_namespace.dart`（仮想パス解決・保護パス検査）
- `packages/agent_drivers/lib/src/fs/host_fs_driver.dart`（実体ファイル I/O・シンボリックリンク検査・SHA-256 算出）

#### パス解決と遮断規則
1. **仮想マウント規則**:
   - Stage 1 では対象 `jj` リポジトリの実体ルートディレクトリ `workspaceHostRoot`（起動時に `Directory(root).resolveSymbolicLinksSync()` で正規化済み）を仮想パス `/workspace` へマウントする。
   - エージェントが渡す `path` 引数は `/workspace/<relPath>` または先頭 `/` なしの相対パス `<relPath>` を受理し、内部で単一の正規化仮想パス `/workspace/<relPath>` と対応ホストパスへ変換する。
2. **スコープ外アクセスの完全拒否（`SyscallErrorCode.eacces`）**:
   - `..` セグメントによる `/workspace` 上位への脱出（例: `/workspace/../secret.txt`, `../../Windows/win.ini`）、別ドライブ絶対パス（`C:\Windows\...`）、UNC パス（`\\server\share`）、NUL 文字混入パスはすべてファイル I/O 前に `EACCES`（`reason: "OUT_OF_WORKSPACE_SCOPE"`）で拒否する。
   - 既存パス（新規作成時は最深の既存親ディレクトリ）に対して `resolveSymbolicLinks()` を実行し、解決後の実パスが `workspaceHostRoot` 配下（Windows 大文字小文字非区別＋パス区切り境界一致）でない場合は、ジャンクション／シンボリックリンク脱出とみなして `EACCES` で拒否する。
3. **カーネル管理・VCS 内部領域および秘密設定ファイルの Read/Write 双方向保護**:
   - `/workspace/.jj`、`/workspace/.git`、`/workspace/.agent_os`（およびその配下すべて）、ならびに `/workspace/.env`・`/workspace/.env.*` に対する **`sys_read_lines`・保護パス直指定（`subpath` または保護領域を直接狙う `pattern`）の `sys_glob`/`sys_grep`・`sys_edit_block`・`sys_write_file` のすべて（Read / Write 双方）** を一律 `SyscallErrorCode.eacces`（`reason: "PROTECTED_INTERNAL_PATH"`）で拒否する。
   - `/workspace` 等の親ディレクトリを対象とする通常の `sys_glob` / `sys_grep` 走査では、`.jj/**`, `.git/**`, `.agent_os/**`, `.env`, `.env.*` を自動スキップし、エラー停止させずに秘匿・非干渉を両立する。

---

### 1.2 Read-Only ファイル探索システムコール（`REQ-02`）

D-012: Read-Only ファイル探索システムコール（sys_read_lines, sys_glob, sys_grep）

対応要求: `REQ-01`, `REQ-02`, `REQ-06`（I/O キャップ連携: `[D-006]`）

| システムコール | 入力引数 | 正常時出力フィールド | 異常系・境界条件 |
| :--- | :--- | :--- | :--- |
| **`sys_read_lines`** | `path: String`<br>`startLine: int?` (既定 `1`, 1始まり)<br>`endLine: int?` (1始まり閉区間、省略時は `startLine + 199`) | `path` (`/workspace/...`),<br>`sha256` (**ファイル全体**の生バイト SHA-256 hex 小文字 64 文字),<br>`totalLines` (`int`),<br>`startLine` (`int`),<br>`endLine` (`int`),<br>`content` (指定行範囲の原文スライス；行番号装飾を混ぜず `sys_edit_block` の `oldBlock` にそのまま利用可能とする) | - スコープ外または `[D-011]` 保護パス（`.jj`, `.git`, `.agent_os` 配下および `.env`, `.env.*`）指定: `EACCES`<br>- 未存在: `ENOENT`<br>- ディレクトリ指定、`startLine < 1`、`endLine < startLine`: `EINVAL`<br>- NUL バイトを含むバイナリまたは UTF-8 デコード不能: `EINVAL` (`BINARY_FILE`)<br>- `startLine > totalLines`（空ファイル時は `totalLines: 0, content: ""`）: 空文字列と `totalLines`, `sha256` を返却<br>- 大幅範囲指定時は `[D-006]` が `content` をキャップしつつ `sha256` と `totalLines` は保持 |
| **`sys_glob`** | `pattern: String` (例: `"lib/**/*.dart"`)<br>`subpath: String?` (既定 `"/workspace"`) | `basePath`, `matches: List<String>` (辞書順ソート済み仮想パス一覧), `totalCount: int` | - スコープ外または `[D-011]` 保護パス直指定（`subpath` や `pattern` が保護領域を直接指す場合）: `EACCES`<br>- 親走査時は `.jj/**`, `.git/**`, `.agent_os/**`, `.env`, `.env.*` を常時自動スキップ<br>- 結果件数が上限超過時は `[D-006]` でサマリ化 |
| **`sys_grep`** | `pattern: String`<br>`subpath: String?`<br>`isRegex: bool` (既定 `false`)<br>`caseSensitive: bool` (既定 `true`)<br>`includeGlob: String?` | `matches: List<{path, line, text}>` (`line` は 1 始まり行番号), `totalMatches: int` | - スコープ外または `[D-011]` 保護パス直指定: `EACCES`<br>- 不正正規表現（`isRegex: true` 時）: `EINVAL`<br>- バイナリファイルおよび `.jj/**`, `.git/**`, `.agent_os/**`, `.env`, `.env.*` は自動スキップ<br>- 大量一致時は `[D-006]` により上限件数・バイト数で強制キャップ |

---

### 1.3 CAS（SHA-256 ハッシュ照合）付きファイル編集システムコール（`REQ-06`）

D-013: CAS（SHA-256 照合）付きファイル編集システムコール（sys_edit_block, sys_write_file）

対応要求: `REQ-06`（関連判断: `OM-03`, トランザクション連動: `[D-003]`, `[D-015]`）

#### 1. `sys_edit_block`（既存ファイルの一意ブロック置換）
- **入力引数**:
  - `path: String`（必須）
  - `expectedSha256: String`（必須：直前の `sys_read_lines` または前回編集結果で得た 64 文字 hex SHA-256）
  - `oldBlock: String`（必須：非空文字列）
  - `newBlock: String`（必須：空文字列可＝削除）
- **厳密な検証・書き込み手順（失敗時は実ファイルを 1 バイトも変更しない）**:
  1. `[D-011]` でパス境界と保護領域を検査し、対象ファイルの存在を確認する（未存在なら `ENOENT`、`oldBlock.isEmpty` なら `EINVAL`）。
  2. 対象ファイルの生バイト列を読み取り `actualSha256` を計算する。`actualSha256 != expectedSha256.toLowerCase()` の場合は即座に **`SyscallErrorCode.econflict`（`reason: "CAS_HASH_MISMATCH"`、最新 `actualSha256` 添付）** を返して中断する。
  3. ファイルの改行コード（`\r\n` 優勢か `\n` か）を判定し、`oldBlock` の一致箇所数を数える（完全一致が 0 件で改行コード差のみがある場合はファイル側の改行コードへ正規化して再計数する）。
     - 一致数 `0` 件 → **`SyscallErrorCode.econflict`（`reason: "TARGET_BLOCK_NOT_FOUND"`）** で中断。
     - 一致数 `2` 件以上 → **`SyscallErrorCode.econflict`（`reason: "AMBIGUOUS_BLOCK_MATCH"`、一致件数を通知し前後の文脈行追加を促す）** で中断。
  4. `[D-015]` `JjDriver.ensureActiveTransaction()` を呼び、作業チェンジ `@` の分離が未完了なら先に確立する。
  5. 一時ファイル書込＋アトミック置換でファイルを更新し、更新後の生バイト列から `newSha256` を算出、続けて `[D-014]` の明示スナップショット同期を実行して `{path, previousSha256, newSha256}` を返す。

#### 2. `sys_write_file`（新規ファイル作成／CAS 付き全体更新：`OM-03`）
- **入力引数**:
  - `path: String`（必須）
  - `content: String`（必須）
  - `expectedSha256: String?`（既存ファイル上書き時は必須、新規作成時は `null`）
  - `createOnly: bool`（任意、既定 `false`）
- **CAS 判定規則**:
  - **新規作成パス（`createOnly == true` または `expectedSha256 == null`）**: 対象ファイルが既に存在する場合は上書きせず **`SyscallErrorCode.eexist`（`reason: "FILE_ALREADY_EXISTS_READ_FIRST"`）** を返す。未存在の場合のみ `ensureActiveTransaction()` 後に親ディレクトリを生成して書き込み、`newSha256` を返す。
  - **既存更新パス（`expectedSha256 != null && !createOnly`）**: 対象ファイルが存在しなければ `ENOENT`、現在ファイルの SHA-256 が `expectedSha256` と不一致なら **`SyscallErrorCode.econflict`（`reason: "CAS_HASH_MISMATCH"`）** を返し、一致時のみ `ensureActiveTransaction()` → アトミック更新 → スナップショット同期 → `{path, previousSha256, newSha256, bytesWritten}` を返す。

---

## 2. `JjDriver` 直列化基盤・非破壊読取・CoW トランザクション制御（`REQ-02`, `REQ-05`）

### 2.1 `JjDriver` 基盤と非破壊読取システムコール

D-014: JjDriver 直列化基盤と非破壊読取システムコール（sys_jj_status, sys_jj_log, sys_jj_diff）

対応要求: `REQ-02`, `REQ-04`, `REQ-05`（関連課題: `A-01`, `A-02` 解決, 副作用境界: `[D-003]`）

#### 配置パス
- `packages/agent_drivers/lib/src/jj/jj_driver.dart`

#### `jj 0.46.0` プロセス起動・直列化・スナップショット整合規約
[jujutsu_cli_046.md](../cheatsheet/jujutsu_cli_046.md) の実測結果に基づき、以下のルールを厳守する：

1. **シェル非経由・非対話環境強制・終了コード判定**:
   - すべての `jj` 呼び出しは `Process.run(jjExecutable, args, workingDirectory: workspaceHostRoot, runInShell: false, environment: {...})` で実行する（`runInShell: true` は Windows `cmd.exe` のクォート破壊を招くため厳禁）。
   - 子プロセス環境変数に `JJ_EDITOR=cmd /c exit 1`、`EDITOR=cmd /c exit 1`、`GIT_TERMINAL_PROMPT=0` を常時注入し、万一の対話エディタ待ちハングを防止する。
   - `jj` は成功時でも `Working copy (@) now at: ...` 等を `stderr` に出すため、**成否は必ず `exitCode == 0` で判定**する（非ゼロ終了時は `SyscallErrorCode.eio` またはリポジトリ未初期化時 `einval`）。
   - テスト用リポジトリ等を新規初期化するヘルパーは廃止された `jj init` ではなく必ず `jj git init --colocate` を用い、`user.name` / `user.email` をリポジトリローカル設定する。
2. **単一非同期ミューテックス（`AsyncMutex`）による直列化**:
   - 更新系操作（`new`, `describe`, `squash`, `abandon`, `op restore`）およびワーキングコピーのスナップショット同期は、すべて `JjDriver` 内の単一 FIFO キュー（`AsyncMutex`）を通して直列実行し、Operation Head の分岐を防止する。
3. **`--ignore-working-copy` と明示スナップショット同期の使い分け（`[D-003]` 実装）**:
   - `TxState.readOnly` 中の全読取、および過去リビジョン指定（`rev != "@"`）・`--at-op <opId>` 指定時は、必ず `--ignore-working-copy` を付与する。これにより `op_id` は 1 つも進まない。
   - `TxState.active` 中は、`sys_edit_block` / `sys_write_file` / `sys_exec` の直後にミューテックス内で `syncWorkingCopySnapshot()`（`jj op log --no-graph --limit 1 -T "self.id()"` を `--ignore-working-copy` 無しで実行）を呼び、最新スナップショットの `jjOpId` と `@` の `jjChangeId` をキャッシュ更新する。
4. **カスタム JSON Lines テンプレート（`conflict` / `empty` 欠落問題の回避）**:
   - `jj 0.46.0` 組み込みの `json(self)` は `Commit` の `conflict` と `empty` を出力しないため、`sys_jj_log` およびチェンジ状態取得には以下の実測確認済み `-T` テンプレートを使用する：
     ```text
     "{\"change_id\":" ++ json(change_id.short(12)) ++ ",\"change_id_full\":" ++ json(change_id) ++ ",\"commit_id\":" ++ json(commit_id) ++ ",\"parents\":" ++ json(parents.map(|c| c.commit_id())) ++ ",\"conflict\":" ++ json(conflict) ++ ",\"empty\":" ++ json(empty) ++ ",\"description\":" ++ json(description) ++ "}\n"
     ```
5. **提供する読取システムコール**:
   - `sys_jj_status({atOp: String?})`: 現在の `@` と親 `@-` のメタ情報（上記テンプレート）＋ 変更ファイル一覧（`jj diff --summary`）＋ 現在 `jjOpId` を返す。
   - `sys_jj_log({revset: String = "::@ | @-", limit: int = 20, atOp: String?})`: 上記 JSON Lines をパースした構造化コミット配列を返す。
   - `sys_jj_diff({rev: String = "@", paths: List<String>?, atOp: String?})`: `jj diff --git -r <rev>` の統合 Diff テキスト（`[D-006]` キャップ適用対象）を返す。

---

### 2.2 CoW トランザクション制御システムコール（`REQ-05`）

D-015: JjDriver CoW トランザクション制御（作業チェンジ分離・確定 squash・完全ロールバック）

対応要求: `REQ-05`, `REQ-10`（副作用境界: `[D-003]`, Ring 2 承認連携: `[D-002]`, `[D-020]`）

#### トランザクション状態モデル（`JjTxContext`）
- `TxState.readOnly`: セッション初期状態。作業チェンジ未分離（`op_id` 不変）。
- `TxState.active`: `baseOpId`（128文字 hex）、`parentChangeId`（保護対象の人間チェンジ `@-`）、`workingChangeId`（エージェント作業チェンジ `@`）を保持。

#### トランザクション操作仕様
1. **作業チェンジ分離（`ensureActiveTransaction` / `sys_tx_begin`）**:
   - `TxState.readOnly` の状態で初回変更操作（`sys_edit_block`, `sys_write_file`, `sys_exec`）または明示システムコール `sys_tx_begin({description: String?})` が呼ばれた際、単一ミューテックス内で以下を原子的に実行する（既に `TxState.active` の場合は冪等に現在の `JjTxContext` を返す）：
     1. `/workspace/.agent_os/.gitignore`（`*\n`）の存在を確認・保証する。
     2. `jj op log --no-graph --limit 1 -T "self.id()"`（`--ignore-working-copy` **なし**）を実行し、人間の未コミット編集を当時のチェンジへ確実にスナップショットした直後の `op_id` を **`baseOpId`（`op_start`）** としてセッション許可リストへ記録する。
     3. 当時の `@` の `change_id` を `parentChangeId` として記録し、`jj new -m "<description ?? 'agent-os: working change'>"` を実行する。これにより人間の作業は不変の親 `@-` となり、新しい空の `@`（`workingChangeId`）が切られる。
2. **説明文の更新（`sys_tx_describe`）**:
   - **Stage 2 事前検査**: `TxState != TxState.active`（作業チェンジ未分離、または直前の `squash`/`rollback` 完了直後）の場合は、Stage 5 `jj` 操作へ一切進まず Stage 2 で即座に **`SyscallErrorCode.econflict`（`reason: "NO_ACTIVE_TRANSACTION"`）** を返して拒否し、人間の未分離チェンジ `@` の説明文上書きを 100% 阻止する。
   - `TxState.active` の場合のみ Ring 2 判定 `ALLOW` としてミューテックス内で `jj describe -m <message>` を実行する（`-m` 必須）。
3. **親チェンジへの変更確定統合（`sys_tx_squash`）**:
   - **Stage 2 事前検査**: `TxState != TxState.active`（作業チェンジ未分離、または直前の `squash`/`rollback` 完了直後）の場合は、Stage 4 承認ゲートや Stage 5 `jj` 操作へ一切進まず Stage 2 で即座に **`SyscallErrorCode.econflict`（`reason: "NO_ACTIVE_TRANSACTION"`）** を返して拒否し、人間の未分離チェンジ `@` が親 `@-` へ誤統合される事故を 100% 阻止する。
   - **Ring 2 判定**: `TxState.active` の場合は **`ASK_USER` 必須**（`[D-002]` §2.3）。
   - **Stage 4 承認要求プレビューの完全非破壊生成（`--ignore-working-copy`）**: `SyscallDefinition.approvalPreviewBuilder` として配線された `JjDriver.buildSquashApprovalPreview()` は、**`--ignore-working-copy` 付きの完全非破壊読取のみ**（`jj diff --git -r @ --ignore-working-copy`、`jj diff --summary -r @ --ignore-working-copy`、および変更各ファイルの `jj file show -r @- <path> --ignore-working-copy` / `jj file show -r @ <path> --ignore-working-copy`）を用いて `ApprovalRequest` 用のファイル別新旧 `diff` ブロックと統合 Diff サマリを構築する（エージェントの全編集・`sys_exec` は完了直後にスナップショット同期済みのため最新状態が取得でき、かつ承認待機中や拒否時に `op_id`・`@-`/`@` の `commit_id`・作業ファイル SHA-256 は 1 ビットも変化しない）。
   - **Stage 5 確定統合実行（承認完了後のみ）**: 利用者が承認（`allow_once` / `allow_always`）して Stage 5 に入った後でのみ、単一ミューテックス内で最終スナップショット同期および以下の非対話 `squash` を実行する（**対話エディタ起動によるハングを防ぐためフラグなし `jj squash` は絶対禁止**）：
     - 引数 `message` 指定あり → `jj squash -m <message>`
     - 引数 `message` 省略時 → `jj squash -u`（`--use-destination-message`: 親 `@-` の説明文を維持）
   - 完了後、`TxState` を `TxState.readOnly` へ戻し（次の別タスク編集時には再び新しい `baseOpId` と `jj new` が切られる）、確定後の `jjOpId` を返す。`reject_once` または `session/cancel` 時は Stage 5 が一切実行されないため、`@-`・`@` の `commit_id`、`op_id`、作業ファイル SHA-256 のすべてが完全不変であり（`[D-003]`・`REQ-10` と完全一致）、拒否時は `EACCES`（`DENIED_BY_USER`）を返す。
4. **1 発完全ロールバック（`sys_tx_rollback`）**:
   - 引数: `targetOpId: String?`（省略時は現在アクティブな `baseOpId`、または直近セッション記録の `baseOpId`）。
   - **異常系・境界防御**: `targetOpId` が空（一度もトランザクションが開始されていない）、または当該セッションで記録された正当なチェックポイント `op_id` 集合に含まれない任意・過去の `op_id` である場合は、セッション開始前の人間履歴を誤消去しないよう **`SyscallErrorCode.eacces`（`reason: "INVALID_OR_PRE_SESSION_OP_ID"`）** で拒否する。
   - **復元実行**: ミューテックス内で `jj op restore <targetOpId>` を実行し、`TxState` を `TxState.readOnly` へ戻す。これにより `@` 上の編集変更と新規追加ファイルは完全に破棄され、`baseOpId` 時点のチェンジ・ファイル内容とバイト単位で 100% 一致する状態へ巻き戻る（`.agent_os/logs/` は除外済みのため監査履歴は保持される）。

---

## 3. Windows Job Object FFI による外部コマンド隔離実行 `sys_exec`（`REQ-07`）

D-016: Windows Job Object FFI 隔離コマンド実行ドライバ（sys_exec）

対応要求: `REQ-07`, `REQ-10`（関連課題: `A-05` 解決, Ring 2 選別規則: `[D-002]` §2.3, I/O キャップ: `[D-006]`）

#### 配置パス
- `packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart`
- `packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart`（`40_specification.md` §2.3 の即時許可 5 条件判定器）

#### 入力・出力スキーマと事前正規化・環境変数サニタイズ
- **入力**: `command: String`（必須）、`args: List<String>?`（任意）、`workingDir: String?`（既定 `"/workspace"`）、`timeoutMs: int?`（既定 `60000`、有効範囲 `100..300000`）。
- **単一文字列コマンドの正規化（`args` 省略時）**: LLM が `{command: "dart test test/foo_test.dart", args: null}` のように `args` 省略で空白区切りコマンド文字列を渡した場合、シェルメタ文字（`&`, `|`, `;`, `>`, `<`, `` ` ``, `$()`, `%`, `\r`, `\n`）を含まなければ、クォート対応の空白分割により実行ファイル名 `exe` と引数配列 `resolvedArgs` へ確定正規化してから Stage 3 Hook（`[D-017]`）・Stage 4 `SysExecClassifier`（`40_specification.md` §2.3）・Stage 5 `Process.start(exe, resolvedArgs, runInShell: false)` へ渡す。
- **子プロセス環境変数の秘密除外**: `Win32JobExecDriver` は子プロセス起動時に `includeParentEnvironment: false` とし、`Platform.environment` から `OPENROUTER_API_KEY`・`OLLAMA_API_KEY` および `*_API_KEY`・`*_SECRET`・`*_TOKEN`（大文字小文字非区別）を除去したサニタイズ済み環境変数マップのみを渡す。これにより外部コマンド（環境変数ダンプやテストスクリプト等）経由での API キー漏洩を防止する。
- **出力（正常・非ゼロ終了ともに構造化値として返却）**: `{exitCode: int, stdout: String, stderr: String, timedOut: bool, durationMs: int, truncatedStdout: bool, truncatedStderr: bool}`。タイムアウト到達時はプロセスツリー強制終了後に `SyscallErrorCode.etimedout`（詳細に途中までのキャップ済み `stdout`/`stderr` を添付）を返す。

#### Win32 `kernel32.dll` FFI レイアウトと強制終了ライフサイクル
[env_and_dart_windows.md](../cheatsheet/env_and_dart_windows.md) §3〜§4 の 64-bit Windows 実測結果に従い、`DynamicLibrary.open('kernel32.dll')`（Build Hooks 不要、`dart compile exe` 完全対応）を用いて以下の手順で実行する：

1. **144 バイト `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` 構造体（`@Packed` 禁止）**:
   - `calloc<Uint8>(144)`（ゼロ初期化済み 144 バイト確保、または自然 8 バイトアライメントの `Struct`）を確保し、オフセット **`16` バイト目**（`BasicLimitInformation.LimitFlags`、`Uint32`）に **`0x00002000`（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）のみ** を書き込む。
   - **`JOB_OBJECT_LIMIT_BREAKAWAY_OK (0x00000800)` は絶対に設定しない**（子孫プロセスの Job 脱獄を禁止）。
2. **Job 作成とプロセス割り当てシーケンス**:
   1. `[D-015]` `ensureActiveTransaction()` で作業チェンジ分離を保証する。
   2. `hJob = CreateJobObjectW(nullptr, nullptr)` → `0` なら `EIO`。
   3. `SetInformationJobObject(hJob, 9, pExtendedInfo, 144)` → `0`（失敗、例 `ERROR_BAD_LENGTH`）なら `CloseHandle(hJob)` して `EIO`。
   4. `Process.start(exe, resolvedArgs, workingDirectory: hostWorkingDir, environment: sanitizedEnv, includeParentEnvironment: false, runInShell: false)` で子プロセスを起動する（※`ASK_USER` 承認済みのシェル構文コマンドを実行する場合も、`dart:io` の不透明な `runInShell: true` は使わず `powershell.exe -NoProfile -NonInteractive -Command <cmd>` を `runInShell: false` で直接起動してルート PID を確実に捕捉する）。
   5. **`Process.start` 完了直後（ストリーム待機に入る前）に同期 FFI で即座に** `hProc = OpenProcess(0x0101, 0, process.pid)`（`PROCESS_SET_QUOTA | PROCESS_TERMINATE`）→ `AssignProcessToJobObject(hJob, hProc)` → `CloseHandle(hProc)` を実行する。
   6. **瞬時終了プロセスのレースハンドリング**: 超短命コマンドが `OpenProcess` または `AssignProcessToJobObject` の時点で既に終了していた場合、Win32 エラー（`ERROR_INVALID_PARAMETER (87)` または `ERROR_ACCESS_DENIED (5)`）が返りうる。この場合は `process.exitCode` が即座に解決済みかを検査し、終了済みであれば正常回収、生存中にもかかわらず割当失敗した場合のみ `process.kill()` + `CloseHandle(hJob)` して `EIO` とする。
3. **タイムアウト・キャンセル・正常終了時の確実な一括回収**:
   - `timeoutMs` タイマー発火または `session/cancel` シグナル受信時は、`TerminateJobObject(hJob, 137)` を呼び出して親プロセス・子プロセス・孫プロセス（例: `powershell` → `ping` 等）を OS カーネルレベルで即座に全滅させる。
   - 正常終了・異常終了を問わず、`finally` ブロックで必ず `CloseHandle(hJob)`（`KILL_ON_JOB_CLOSE` により裏で残ったバックグラウンド孫プロセスも自動強制終了）と `calloc.free(pExtendedInfo)`、および `JjDriver.syncWorkingCopySnapshot()` を実行する。

---

## 4. `beforeSyscall` Hook 機構と Anti-Git-Habit Guard（`REQ-08`）

D-017: Syscall Hook プラグイン機構と Anti-Git-Habit Guard

対応要求: `REQ-08`（パイプライン位置: `[D-002]` Stage 3 — Ring 2 承認ゲートより前）

#### 配置パス
- `packages/agent_kernel/lib/src/syscall_hook.dart`（`SyscallHook`, `HookDecision` 抽象）
- `packages/agent_drivers/lib/src/hooks/anti_git_habit_guard_hook.dart`（具象ガード実装）

#### インターフェースと検査アルゴリズム
1. **`SyscallHook` 契約**:
   - `Future<HookBeforeResult> beforeSyscall(SyscallHookContext ctx)`: `HookAllow()` または `HookBlock(reason, message, hint)` を返す。`HookBlock` が返された場合、`SyscallGate` は Stage 4（承認ゲート）および Stage 5（ドライバ）を一切呼ばず、`SyscallErrorCode.eperm`（`reason: "HOOK_BLOCKED"`）を生成して Stage 8（`syscalls.jsonl` へ `"decision": "HOOK_BLOCKED"` を記録）へ直行する。
2. **`AntiGitHabitGuardHook` の遮断パターン**:
   - 対象システムコール: `sys_exec`。
   - 検査ロジック（複合シェル・ラッパー対応のコマンドレキサ）:
     1. `command` と `args` を走査し、シェル連結・パイプ・置換境界（`&&`, `||`, `;`, `|`, `&`, `\r`, `\n`, `` ` ``, `$(`）ごとにサブコマンド列へ分割する。
     2. 各サブコマンドの先頭トークンがシェルラッパー（`cmd`, `cmd.exe`, `powershell`, `powershell.exe`, `pwsh`, `pwsh.exe`, `sh`, `bash`）およびその実行フラグ（`/c`, `/k`, `-c`, `-Command` 等）や環境変数代入である場合は、内側の実効コマンド文字列を再帰的に展開して先頭実行ファイル名を抽出する。
     3. 抽出した先頭実行ファイルのベース名（パス区切り除去・小文字化・拡張子 `.exe`/`.cmd`/`.bat` 除去）が **`git`** または **`jj`** に一致した場合、即座に `HookBlock` を返す（※引数側の単なるファイルパス、例 `dart test test/git_helper_test.dart` は先頭実行ファイルが `dart` であるため誤遮断しない）。
   - **返却する誘導エラーメッセージ（LLM 自律修正用）**:
     ```text
     [HOOK_BLOCKED: AntiGitHabitGuard] Raw 'git' / 'jj' CLI execution via sys_exec is prohibited in this Jujutsu (jj) managed kernel. Use dedicated kernel syscalls instead: sys_jj_status, sys_jj_log, sys_jj_diff (for inspection), or sys_tx_begin, sys_tx_describe, sys_tx_squash, sys_tx_rollback (for change management).
     ```

---

## 5. 対象 REQ との確認・検証マッピング（`tester` 引き渡し情報）

| REQ | 対象設計ID | 検証種別と必須確認シナリオ |
| :--- | :--- | :--- |
| **`REQ-02`** | `[D-003]`, `[D-004]`, `[D-011]`, `[D-012]`, `[D-014]` | - **`E1`**: `../`・絶対パス・ジャンクション脱出・保護領域（`.jj`/`.git`/`.agent_os`/`.env`）への Read/直指定アクセス `EACCES` テスト（および親走査 `sys_glob`/`sys_grep` での自動スキップ確認）、不正行番号 `EINVAL`、未スナップショット変更があるリポジトリでの `sys_jj_status`/`log`/`diff` 実行前後の `op_id` 完全一致テスト。<br>- **`E2`**: 実 `jj` リポジトリへの質問で `sys_glob`/`sys_grep`/`sys_read_lines`/`sys_jj_log`/`sys_jj_diff` を自律実行して正答し、`jj op log` の先頭 `op_id` が変化しないこと。 |
| **`REQ-05`** | `[D-003]`, `[D-014]`, `[D-015]` | - **`E1`**: 人間の未スナップショット編集がある状態での `ensureActiveTransaction` → `@` 編集後も `@-` が無傷であること、`TxState.readOnly`（未分離および `squash`/`rollback` 直後）での `sys_tx_describe`/`sys_tx_squash` Stage 2 即時 `ECONFLICT`（`NO_ACTIVE_TRANSACTION`）拒否、`sys_tx_rollback` 後の全ファイルバイト完全一致と新規ファイル消去、セッション開始前 `op_id` 指定時の `EACCES` 拒否、`sys_tx_squash` 非対話完了テスト。<br>- **`E2`**: 未コミット変更を持つ実 `jj` リポジトリでエージェント編集→`dart test` 失敗→`sys_tx_rollback` 1 発で開始前と完全一致すること。 |
| **`REQ-06`** | `[D-004]`, `[D-011]`, `[D-012]`, `[D-013]` | - **`E1`**: `sys_edit_block` 正常置換、CAS ハッシュ不一致 `ECONFLICT`、対象ブロック 0 件/2 件重複 `ECONFLICT`、`sys_write_file` 未読既存ファイル上書き `EEXIST`、スコープ外および保護パス書込 `EACCES` の自動テスト（失敗ケースすべてで元ファイル無変更を確認）。<br>- **`E2`**: 実エージェントが `sys_read_lines` の `sha256` を用いて編集成功するログとハッシュ不一致時の安全拒否観測。 |
| **`REQ-07`** | `[D-006]`, `[D-016]` | - **`E3`**: 144 byte `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`（offset 16 = `0x2000`、`BREAKAWAY_OK` 無し）FFI 実装確認。<br>- **`E1` / `E2`**: 子プロセスからさらに孫プロセス（長時間待機プロセス）を生成し PID を出力するスクリプトを短い `timeoutMs` で `sys_exec` し、`ETIMEDOUT` 返却直後に親・孫ともに OS 上の生存プロセスが 0 件であること（併せて `args: null` 単一文字列正規化と子プロセス環境変数からの `*_API_KEY` 除外を `E1` で確認）。 |
| **`REQ-08`** | `[D-002]`, `[D-017]` | - **`E1`**: `git status`, `jj log`, `echo ok && git diff`, `powershell -c "jj squash"`, `cmd /c git checkout .` がすべて承認ゲート到達前に `HOOK_BLOCKED`（`EPERM`）となり、`dart test test/git_util_test.dart` は通過する自動テスト。<br>- **`E2`**: 実エージェントが生 `git` 実行を試みてブロックされた直後のターンで自律的に `sys_jj_status` / `sys_jj_diff` へ切り替える一連の `syscalls.jsonl` 証跡観測。 |
