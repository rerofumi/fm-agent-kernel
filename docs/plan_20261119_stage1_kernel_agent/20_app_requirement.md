# 20_app_requirement.md — 利用場面・代表操作・対象環境・範囲定義

関連文書:
- 背景・構想: [10_claim.md](./10_claim.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 利用者像と基本利用スタイル

開発者（利用者）は、Windows 上の Jujutsu (`jj`) 管理下リポジトリを作業対象としてエージェントエンジンを起動し、自然言語プロンプトとスラッシュコマンド等（モデル切替・承認応答・ロールバック指示）を用いて以下の業務を行う。
- Step 1-1・1-2 の段階開発中は最小実行ハーネスからも検証でき、Step 1-3 到達時点では同梱の **簡易 ACP CLI クライアント（`acp_cli_client`）** から、単一実行ファイル化された **ACP サーバーエンジン（`.exe`）** へ JSON-RPC 2.0 over `stdio` で接続して対話利用する。

---

## 2. Step 別の利用場面・代表操作・前後の状態と成功結果

### 2.1 Step 1-1：Read-Only コードベース探索・毎ターンプロバイダ切替・監査/キャッシュ観測

| シナリオ | 代表的な入力・操作 | 操作前の状態（リポジトリ / プロセス / ログ） | 成功時の結果と操作後の状態 |
| :--- | :--- | :--- | :--- |
| **S1-1a: コードと `jj` 履歴の自律読解** | 利用者が「このリポジトリの構成と直近の変更内容を `jj` 履歴から説明して」と入力する。 | - **Repo**: 複数ファイルと過去コミット・差分が存在する `jj` リポジトリ（先頭 `op_id = op_0`）。<br>- **Process**: 単一 `LeadAgent`（Ring 2）が待機中。<br>- **Log**: セッション用の `syscalls.jsonl` / `llm_io.jsonl` が初期化済み。 | - エージェントが `SyscallGate` 経由で `sys_glob`, `sys_grep`, `sys_read_lines`, `sys_jj_status`, `sys_jj_log`, `sys_jj_diff` を自律発行し、事実に基づいた回答を返す。<br>- **Repo**: Read-Only 参照のため作業ツリーは不変であり、`jj op log` の先頭 `op_id` も汚れない。<br>- **Log**: `syscalls.jsonl` に全システムコールが当時の `jjChangeId` / `jjOpId` 付きで記録される。 |
| **S1-1b: 巨大ファイル・大量ヒット検索での I/O キャップ防御** | 利用者が 1 万行超のファイル読取や、リポジトリ全体で数千件ヒットする検索を伴う質問を入力する。 | - **Repo**: 1 万行以上のファイルや大量一致パターンを含む状態。<br>- **Process**: `LeadAgent` 実行中。 | - カーネルの **I/O 出力サイズ強制キャップ** が働き、先頭・末尾サマリと省略情報のみがエージェントへ返却される。<br>- **Process**: 1 ターンでコンテキスト窓溢れエラーにならず、エージェントは必要に応じて行範囲を絞った `sys_read_lines` 等で調査を継続・回答できる。 |
| **S1-1c: プロンプト毎のプロバイダ／モデル切替とキャッシュ監視** | 1 ターン目を `Local Ollama`、2 ターン目を `OpenRouter`、3 ターン目を `Local Ollama`（さらに `Ollama Cloud` を含む 3 プロバイダ）へ切り替えながら連続質問し、また同一モデルでも複数ターン連続対話する。 | - **Process**: Canonical IR にそれまでの対話・ツール履歴を保持中。<br>- **Log**: 前ターンまでの推論記録が存在。 | - **Process**: プロバイダを跨いでも履歴フォーマット不整合（State Spill / `400 Bad Request`）を起こさず、前ターンの文脈を踏まえて応答が継続する。<br>- **Log**: `llm_io.jsonl` に各プロバイダの実トークン統計が記録され、同一モデル連続ターン時には先頭 Prefix が維持されて **`cached_tokens`（キャッシュヒット率）の上昇** が数値で確認できる。 |

---

### 2.2 Step 1-2：`jj` トランザクション分離編集・Job Object テスト実行・誤爆防止 Hook

| シナリオ | 代表的な入力・操作 | 操作前の状態（リポジトリ / プロセス / ログ） | 成功時の結果と操作後の状態 |
| :--- | :--- | :--- | :--- |
| **S1-2a: 人間の未コミット変更を保護したコード編集** | 人間が手元でファイルを編集途中のまま、「関数 X にバリデーションを追加してテストを通して」と依頼する。 | - **Repo**: 人間の未コミット変更を含む現チェンジ（開始後 ` @-` になるチェンジ）が存在。開始時 `op_id = op_start`。<br>- **Process**: 単一 `LeadAgent`（Ring 2）。 | - タスク開始時に `JjDriver` が `op_start` を記録し、`jj new` でエージェント専用の新しい `@` チェンジを切る。<br>- エージェントが `sys_read_lines` で取得した SHA-256 ハッシュを用いて `sys_edit_block` / `sys_write_file`（CAS 照合）で安全に編集する。<br>- **Repo**: **人間の直前チェンジ（`@-`）は 1 バイトも変化せず完全に無傷** で保護される。 |
| **S1-2b: テスト失敗時の 1 発完全ロールバック** | エージェントが複数ファイルを書き換えて `sys_exec("dart test")` を実行したがテストが失敗し、ロールバック（`sys_tx_rollback`）を実行する。 | - **Repo**: `@` 上で複数ファイルが変更・追加された状態。<br>- **Process**: テスト失敗を検知。 | - `sys_tx_rollback`（内部の `jj op restore <op_start>` 等）1 発で、**Repo** のファイル内容・チェンジ構成がタスク開始前（`op_start` 時点）と完全一致する状態へ復元される。<br>- **Log**: ロールバック操作と前後の `jjOpId` が `syscalls.jsonl` に残る。 |
| **S1-2c: ハング・孫プロセス生成コマンドの強制終了** | 終わらないコマンドや孫プロセスを生成するスクリプトが `sys_exec` で起動され、タイムアウト時間を迎える。 | - **Process**: `sys_exec` が Windows Job Object 内で外部プロセスツリーを実行中。 | - タイムアウト到達時に Job Object ごと一括強制終了される。<br>- **Process / OS**: **孫プロセスを含む全子孫プロセスが OS 上に 1 つもゾンビ残留せず消滅** し、エージェントには構造化されたタイムアウト結果が返って制御が継続する。 |
| **S1-2d: 生 `git` / `jj` 手癖コマンドの遮断と自律修正** | LLM が手癖で `sys_exec("git status")` や `sys_exec("git diff")`（または生 `jj`）を実行しようとする。 | - **Process**: `LeadAgent` が `sys_exec` を要求。 | - 外部プロセス起動前に `beforeSyscall` の **Anti-Git-Habit Guard Hook** が即座に遮断し、`sys_jj_*` への誘導エラーを返す。<br>- 次のターンでエージェントが自律的に `sys_jj_status` / `sys_jj_diff` を呼び直して処理を続行し、その一連の遮断と再試行が `syscalls.jsonl` で確認できる。 |

---

### 2.3 Step 1-3：ACP サーバー分離・保護リング承認ゲート・単一 `.exe` 運用

| シナリオ | 代表的な入力・操作 | 操作前の状態（リポジトリ / プロセス / ログ） | 成功時の結果と操作後の状態 |
| :--- | :--- | :--- | :--- |
| **S1-3a: 簡易 CLI クライアントからの ACP 対話と `/model` 切替** | 利用者が `acp_cli_client` を起動してエンジン（ACP `stdio` サーバー）へ接続し、プロンプト送信や `/model` によるプロバイダ／モデル切替を行う。 | - **Process**: クライアントプロセスとエンジン `.exe` プロセスが `stdio` JSON-RPC 2.0 で接続済み。 | - クライアント画面上で思考ストリーム・実行中システムコール・`jj diff`・トークン/キャッシュ統計がリアルタイムに表示され、`/model` でターンごとに `Local Ollama` / `OpenRouter` / `Ollama Cloud` のモデルを軽快に切り替えられる。 |
| **S1-3b: Ring 2 承認ゲート（承認による確定 / 拒否による `EACCES` 防波堤）** | エージェントが作業チェンジでの編集を終えて最終 `squash` 確定（または要注意コマンド実行）を要求し、利用者がクライアント上で表示された `jj diff` やコマンド内容を見て **「承認」** または **「拒否」** を選ぶ。 | - **Repo**: エージェント専用 `@` 上に仮編集差分がある（確定前）。<br>- **Process**: `SyscallGate` の Ring 2 判定により PCB 状態が `WAITING_APPROVAL` で一時停止中。 | - **承認時**: 一時停止が解除されて `squash`（または対象コマンド）が実行され、変更が確定して完了応答が返る。<br>- **拒否時**: 対象操作は実行されず（副作用ゼロ）、カーネルが監査ログに拒否を記録して `EACCES` をエージェントへ返す。エージェントはクラッシュせず別案を検討するかロールバック／ユーザー確認へ移行する。 |
| **S1-3c: 単一ネイティブ `.exe` での完結動作（Stage 1 到達点）** | `dart compile exe` でビルドした実行ファイルを用いて、一連の「調査 → 分離編集 → テスト → ACP 承認/拒否/ロールバック」を実行する。 | - **Env**: Windows 上にビルド済み `.exe` と対象 `jj` リポジトリが存在。 | - Dart VM（`dart run`）を介さずネイティブ `.exe` 単体で ACP 通信・3 プロバイダ API・`JjDriver`・Win32 Job Object FFI の全機能がエラーなく完走する。 |

---

## 3. 対象環境

| 項目 | 対象仕様・前提 |
| :--- | :--- |
| **ホスト OS** | Windows（Win32 API `kernel32.dll` の Job Object をネイティブ利用） |
| **開発言語・ビルド形態** | Dart SDK（Pub Workspaces 構成可）、最終的に `dart compile exe` による Windows ネイティブ実行ファイル（`.exe`）化 |
| **対象 VCS 環境** | Jujutsu (`jj`) リポジトリ（ローカル導入済みの `jj` CLI を `JjDriver` から駆動） |
| **対象 LLM プロバイダ（実機検証対象）** | 以下の **3 プロバイダすべて** を対象とする（利用者合意済み）：<br>1. `Local Ollama`（例: `http://localhost:11434/v1/`、API キー不要）<br>2. `OpenRouter`（Bearer API キー環境変数経由）<br>3. `Ollama Cloud`（Bearer API キー環境変数経由） |
| **上位接続プロトコル** | ACP（Agent Client Protocol：JSON-RPC 2.0 over `stdio`）＋ 同梱の検証・日常操作用 `acp_cli_client` |

---

## 4. 今回の範囲（In-Scope）と省くもの（Out-of-Scope）

### 4.1 今回の範囲（In-Scope：Stage 1 = Step 1-1 〜 Step 1-3）
1. **最小防波堤カーネル骨格**: `agent_kernel` の外部非依存分離、単一 `LeadAgent`（Ring 2）の `PCB` 管理、`SyscallGate` 単一通過、I/O 出力サイズ強制キャップ。
2. **Read-Only 探索システムコール**: `/workspace` スコープ制限付きの `sys_read_lines`, `sys_glob`, `sys_grep` および非破壊 `JjDriver` 読取（`sys_jj_status`, `sys_jj_log`, `sys_jj_diff`）。
3. **Canonical IR と 3 プロバイダ対応 `LlmDriver`**: `Local Ollama`・`OpenRouter`・`Ollama Cloud` 対応、ターン毎のプロバイダ／モデル切替、Prefix 保持型の履歴構成。
4. **監査・テレメトリ基盤**: `syscalls.jsonl`（`jjChangeId` / `jjOpId` 紐付け）および `llm_io.jsonl`（トークン・`cached_tokens` 監視、秘密情報マスク）。
5. **`jj` 単一トランザクション編集とロールバック**: 開始時 `op_id` 記録、`jj new` 分離、CAS（SHA-256）付き `sys_edit_block` / `sys_write_file`、完了 `describe` / `squash`、失敗時 `sys_tx_rollback`（`jj op restore` / `jj abandon`）、および将来拡張を見据えた `JjDriver` 更新直列化境界。
6. **隔離コマンド実行と Hook**: Windows Job Object（`dart:ffi`）による `sys_exec`（タイムアウト時の子孫一括強制終了）および `beforeSyscall` Hook ＋ **Anti-Git-Habit Guard**（生 `git` / `jj` 遮断・誘導）。
7. **ACP 分離・承認ゲート・ネイティブ EXE 化**: ACP `stdio` サーバー、リアルタイム通知、Ring 2 承認ゲート（`WAITING_APPROVAL` / 拒否時 `EACCES`）、同梱 `acp_cli_client`、`dart compile exe` ビルド対応。

### 4.2 今回省くもの（Out-of-Scope：後続 Stage 2・Stage 3 等）
以下の要素は「1 ステップ 1 課題」の安全ロック方針および利用者合意に基づき、**今回の対象外** とする（カーネル境界のみ壊さないよう配慮し、機能実装・検証対象には含めない）。

- **Stage 2 領域（次回以降）**:
  - High Watermark 連動の Clean Page 自動スタブ退避ページャ・`STALE` 検知・`sys_mem_pagein`・小コンテキストモデル切替時の自動フレーム縮小（Step 2-1）
  - Dart `Isolate` によるマルチプロセス子エージェント生成（`sys_spawn` / `sys_wait`）、有界メールボックス IPC（`sys_send` / `sys_recv`）、ケーパビリティ減衰委譲、階層クオータ寄贈・回収（Step 2-2）
  - 外部 Web 検索／取得システムコール（`sys_web_search`, `sys_web_fetch`）、無菌室 `WebResearcher` プロセス、外部フォルダからの `SKILL.md` 動的マウント（Step 2-3）
- **Stage 3 領域（さらに後続）**:
  - `jj workspace add / forget` による並列ワークスペース払い出し（Step 3-1）
  - `jj new <c1> <c2>` 多親マージ（`sys_jj_merge`）と First-Class Conflicts 解消フロー（Step 3-2）
  - シグナル制御（`SIGSTOP` / `SIGCONT` 等）、Supervisor 自動再起動回復、Dirty Page Swap 要約退避、MCP クライアントドライバ（`sys_mcp_call`）、Stacked Changes カンバン管理（Step 3-3）
- **上位アプリケーション本体**:
  - GUI エディタ（Zed 等）自体の開発・改修、カンバン GUI やチャット Bot フロントエンド本体の実装。
