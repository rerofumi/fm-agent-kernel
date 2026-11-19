# Jujutsu (`jj 0.46.0`) CLI 仕様・テンプレート・トランザクション実測

- **確認日**: `2026-11-19`
- **対象版**: `jj 0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f`（Windows 11 Pro 64-bit）
- **確認方法**: `.planworks\pt01_smoke\` 配下の隔離テストリポジトリでの実機実行（確認後クリーンアップ済み）および公式ドキュメント（`https://docs.jj-vcs.dev/latest/`）照合

---

## 1. ローカルで確認した実行結果（`JjDriver` 必須コマンド群）

### 1.1 リポジトリ初期化（`jj init` 廃止と `jj git init` 既定 colocated 化）

| コマンド | 終了コード | 実測挙動・生成ディレクトリ |
| --- | :---: | --- |
| `jj init` | **`2` (失敗)** | **`error: unrecognized subcommand 'init'`**。`jj 0.46.0` では `jj init` サブコマンドは存在しない。必ず `jj git init` を使用する。 |
| `jj git init` | `0` | **`.jj` と `.git` の両方がルートに生成される（Colocated がデフォルト）**。`jj git init --help` でも `--colocate` が既定（`git.colocate = false` 設定時を除く）であることを確認。 |
| `jj git init --colocate` | `0` | 明示的に Colocated（`.jj` + `.git` 同居）を強制する。ユーザの `~/.jjconfig.toml` 設定に左右されず一貫した挙動を得るなら明示指定が安全。 |
| `jj git init --no-colocate` | `0` | `.git` を `.jj/repo/store/git` 内部に隠蔽する非 Colocated 構成（生 `git` コマンドがルートで誤作動しなくなる利点がある一方、外部 IDE の Git 表示は効かなくなる）。 |

### 1.2 読取系での `--ignore-working-copy` と `--at-op <op_id>`

| 検証項目 | 実行コマンド | 実測結果 |
| --- | --- | --- |
| 未スナップショット編集がある状態での `--ignore-working-copy` | ファイル変更直後に `jj status --ignore-working-copy` | 終了コード `0`。ワーキングコピーのスナップショット処理が走らず、**実行前後で `op_id` が完全に同一（不変）** であることを確認。`jj log`, `jj diff`, `jj file show` でも同様に有効。 |
| タイムトラベル参照 `--at-op <op_id>` | `jj --at-op <older_op_id> status` / `log` / `diff --git` | すべて終了コード `0` で過去 Operation 時点の状態を返す。さらに未追跡の dirty ファイルが存在する状態で `--ignore-working-copy` を省略して `--at-op` を実行しても、**ワーキングコピーのスナップショットは誘発されず現在 `op_id` が進まない**ことを確認。 |
| 特定リビジョンのファイル原本取得 | `jj file show -r <rev> --ignore-working-copy <path>` | 終了コード `0`。指定リビジョン（`@-` や過去 `commit_id`）のファイル内容を標準出力へそのまま出力する。 |

### 1.3 機械可読テンプレート（`-T`）の重要仕様と実測結果

#### A. 現在 Operation ID（`op_id`）を確実に 1 行（改行なし／あり）で取得するコマンド
- **スナップショットを伴わず現在の `op_id`（128文字 hex フルID）を取得**:
  ```text
  jj op log --no-graph --limit 1 --ignore-working-copy -T "self.id()"
  ```
  - 短縮 ID（12文字）でよい場合は `self.id().short(12)`。
  - **タスク開始時チェックポイント（直前の人間作業を確実にスナップショットしてから `op_id` を記録したい場合）** は `--ignore-working-copy` を**外して** `jj op log --no-graph --limit 1 -T "self.id()"` を 1 回呼ぶと、自動スナップショット実行後の最新 `op_id` が返る。
- **`Operation` に対する `json(self)`**:
  ```text
  jj op log --no-graph --limit 1 --ignore-working-copy -T "json(self) ++ \"\n\""
  ```
  - 出力実測例（`exit=0`）:
    ```json
    {"id":"de3a916ace23...","parents":["94a11485..."],"time":{"start":"2026-11-19T15:19:18.234+09:00","end":"2026-11-19T15:19:18.249+09:00"},"description":"new empty commit","hostname":"...","username":"...","is_snapshot":false,"workspace_name":"default","attributes":{"args":"jj new ..."}}
    ```

#### B. 【重要注意】`Commit` に対する `json(self)` には `conflict` と `empty` が含まれない！
- コンフリクト状態かつ空のコミット `@` に対して `jj log --no-graph -r @ -T 'json(self) ++ "\n"'` を実測した結果（`exit=0`）:
  ```json
  {"commit_id":"ac9cbdea6c7596cb2470c6383912484ffc09d646","parents":["05a12fc9...","34ed8280..."],"change_id":"vnzyzqllrmrmwkrnxxxpqqmkkummnzox","description":"merge AB\n","author":{...},"committer":{...}}
  ```
  - 上記の通り、組み込みの `json(self)` シリアライザは `commit_id`, `parents`, `change_id`, `description`, `author`, `committer` のみを出力し、**`conflict`（競合有無）と `empty`（空コミットか否か）を含まない**。
- **解決策（実測確認済み JSON Lines テンプレート）**: 個別プロパティに `json(...)` 関数を適用して 1 行 1 JSON オブジェクトを組み立てる以下のテンプレート式を使うと、エスケープも完全に安全な JSON Lines が得られる（`exit=0` 確認済み）:
  ```text
  "{\"change_id\":" ++ json(change_id.short(12)) ++ ",\"change_id_full\":" ++ json(change_id) ++ ",\"commit_id\":" ++ json(commit_id) ++ ",\"parents\":" ++ json(parents.map(|c| c.commit_id())) ++ ",\"conflict\":" ++ json(conflict) ++ ",\"empty\":" ++ json(empty) ++ ",\"description\":" ++ json(description) ++ "}\n"
  ```
  - コンフリクトコミットでの実測出力:
    ```json
    {"change_id":"vnzyzqllrmrm","change_id_full":"vnzyzqllrmrmwkrnxxxpqqmkkummnzox","commit_id":"ac9cbdea6c7596cb2470c6383912484ffc09d646","conflict":true,"empty":true,"description":"merge AB\n"}
    ```

### 1.4 トランザクション操作・非対話フラグの罠（実測結果）

| 操作 | コマンドと必須フラグ | 終了コード | 実測で確認した挙動・注意点 |
| --- | --- | :---: | --- |
| 作業チェンジ分離 | `jj new -m "<msg>"` | `0` | 人間が未スナップショットのファイル編集を持ったまま実行しても、先に当時の `@` が自動スナップショットされて不変の親 `@-` となり、新しい空の `@` が切られる。以降 `@` でファイルを書き換え・追加しても **`@-` の `commit_id` と内容は 1 バイトも変化しない**ことを確認。 |
| 説明文の更新 | `jj describe -m "<msg>"` | `0` | `-m`（`--message`）を必ず付けること（省略すると対話エディタが開く）。 |
| **変更の親統合 (`squash`)** | **`jj squash -u`** または **`jj squash -m "<msg>"`** | `0` | **【重大な罠】`@` と `@-` の両方に非空の description がある状態でフラグなしの `jj squash` を呼ぶと、`jj` が説明文結合のために対話エディタ（`JJ_EDITOR`）を起動しようとし、ヘッドレス実行ではハングまたは `exit=1` (`Failed to edit description`) になることを実測確認した。** `JjDriver` では必ず `-u`（`--use-destination-message`：親の説明を維持）または `-m "<combined>"` を明示指定し、念のため環境変数 `JJ_EDITOR=cmd /c exit 1` 等で万一の対話待ちハングを防止すること。 |
| 作業チェンジ破棄 | `jj abandon`（または `jj abandon <rev>`） | `0` | 対象チェンジの変更と追加ファイルが破棄され、新しい空の `@` が親の上に作られる。 |
| 完全ロールバック | `jj op restore <op_id>` | `0` | 追加された新規ファイルは削除され、編集された既存ファイルは開始前と **バイト配列レベルで 100% 一致（`byte-identical=True`）** して復元されることを実測確認。なお `op restore` 自体も新しい Operation として Op-Log に記録されるため「ロールバックの取り消し」も可能。 |
| 多親マージと競合 | `jj new <revA> <revB> -m "..."` | **`0`** | 同一ファイルの同一行が衝突していても **終了コード `0` で成功** し、`(conflict)` 付きのコミットが生成される（stderr に `Warning: There are unresolved conflicts at these paths:` が出力される）。 |

---

## 2. Windows におけるプロセス起動・出力処理の注意点（判断・経験則）

1. **stderr への進捗メッセージ出力**:
   - `jj new`, `jj squash`, `jj abandon`, `jj op restore` 等は、成功時（`exit=0`）でも `Working copy (@) now at: ...` といった人間向けステータス表示を **`stderr` に出力する**（`stdout` は空、テンプレート出力や `diff` 本体のみ `stdout` に出る）。
   - したがって `JjDriver` では「`stderr` が非空 ＝ エラー」と誤判定してはならず、**必ず `exitCode == 0` で成否を判定** すること（さらに `--quiet` を付ければ情報メッセージを抑制できる）。
2. **Windows コマンドライン引数でのダブルクォート渡し**:
   - PowerShell 5.1 からネイティブ `.exe` を直接呼ぶと文字列内の `"` が剥がれる既知挙動があるが、`.NET ProcessStartInfo` や Dart の `Process.run('jj', ['log', '--no-graph', '-T', templateString], runInShell: false)` で **`runInShell: false`（既定）として引数配列を渡せば**、`"` を含むテンプレート式も正しくエスケープされて渡る（`runInShell: true` は `cmd.exe` 解釈で `"` や `|` が壊れるため `JjDriver` では絶対に使わないこと）。
3. **リポジトリ設定（Author 未設定対策・巨大ファイル保護）**:
   - クリーン環境やテスト環境で `user.name` / `user.email` が未設定だと警告または一部操作エラーになりうるため、テスト用リポジトリ初期化時には `--config` または `jj config set --repo` で設定するのが安全。
   - 監査ログやスワップ領域（例: `.agent_os/`）をワークスペース内に置く場合は、必ず `.gitignore` に追加して `jj` の自動スナップショット対象から除外すること（監査ログ書き込みのたびに `@` が dirty になる無限ループを防ぐため必須）。
