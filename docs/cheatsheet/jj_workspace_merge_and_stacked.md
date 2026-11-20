# Jujutsu (`jj 0.46.0`) 並列ワークスペース・多親マージ・First-Class Conflicts・Stacked Changes 実測

- **確認日**: `2026-11-20`
- **対象環境**: Windows 11 Pro 64-bit (`10.0.26300`) / PowerShell / `mise`
- **対象技術・版**:
  - Jujutsu `jj 0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f`
  - Dart SDK `3.14.1` (stable, `windows_x64`) / Dart Pub Workspaces
- **確認方法**: `.planworks/pt01_stage3_smoke/` 配下の隔離リポジトリ群での実機コマンド実行（確認後完全削除済み）および公式ドキュメント照合

---

## 1. 外部一次資料の事実

- **出典**: Jujutsu 公式ドキュメント（`https://docs.jj-vcs.dev/latest/working-copy/`, `https://docs.jj-vcs.dev/latest/conflicts/`, `https://docs.jj-vcs.dev/latest/cli-reference/`, 確認日 `2026-11-20`）。
- **複数ワークスペース（`jj workspace`）**:
  - 1 つの `.jj/repo` ストアに対して複数の独立したワーキングコピーディレクトリを接続できる。各ワークスペースは固有のワーキングコピーコミット（`<workspace_name>@`）と独自の sparse パターンを持つ。
  - グローバルオプション `-R, --repository <PATH>` に各ワークスペースのディレクトリパスを渡すと、カレントディレクトリを移動せずに該当ワークスペースを対象としてスナップショットや操作を実行できる。
- **First-Class Conflicts**:
  - `jj` はマージやリベースで発生した競合をエラー停止ではなく**コミットツリー内の構造化データ**としてそのまま記録する。競合コミットをチェックアウトしたワーキングコピーにはコンフリクトマーカーが書き出され、ファイルを通常のテキストに編集してスナップショットするだけで競合解消として記録される。
- **子孫コミットの自動リベースと Stale Working Copy**:
  - あるコミットが書き換えられると、そのコミットを親（先祖）に持つ子孫コミットは自動的に新しいコミットの上へリベースされる。
  - 別ワークスペースの `@` コミットが裏で書き換えられた場合、そのワークスペースの実ファイルは古い Operation 時点のまま残るため `stale` 状態となり、`jj workspace update-stale` で実ファイルを最新コミットへ追従させる仕様である。

---

## 2. ローカルで確認した実行結果（問い1：`jj workspace` 並列払い出し・Op 直列化・Dart Pub Workspaces）

### 2.1 `jj workspace add` の正確な CLI 引数・`Change ID` 生成・Colocated 挙動

隔離 `jj git init --colocate` リポジトリにおいて、ベースチェンジ `<base>` (`qylqnyppvrxx`) から 2 つの子ワークスペース `.agent_os/ws/2` (`ws-2`), `.agent_os/ws/3` (`ws-3`) を作成した実測結果：

| 確認項目 | 実行コマンド | 終了コード・実際の観測結果 |
| --- | --- | --- |
| 同一 `<base>` からの並列ワークスペース払い出し | `jj workspace add <abs_ws_path> --name ws-2 -r <base> -m "worker 2 task"`<br>`jj workspace add <abs_ws_path> --name ws-3 -r <base> -m "worker 3 task"` | 両方 `exit=0`。<br>`-r <base>` は「新ワークスペースの `@` コミットの**親リビジョン**」を指定する引数であり、`<base>` 自体を共有するのではなく、**`<base>` を共通の親（`@-`）とする新しい空（`empty: true`）の独立した無名 `Change ID` が各ワークスペース専用に自動生成される**（実測: `ws-2@` = `lwtztkqtrrwz`, `ws-3@` = `pzlotztkzyxu`, ともに `parents: ["qylqnyppvrxx"]`）。 |
| Colocated リポジトリでの既定 vs `--no-colocate` | ① 既定（フラグなし）<br>② `jj workspace add --no-colocate <abs_ws_path> --name ws-2 -r <base> -m "w2"` | ① 既定では `Created Git worktree for the new workspace.` が走り、親 `.git/worktrees/<name>` と子直下の `.git` ファイルが生成される。<br>② **`--no-colocate` を付与すると `exit=0` で子直下に `.jj` のみが生成され（`.git` 生成なし）、Git worktree の管理・ロックオーバーヘッドを完全に回避できる。** |
| ワークスペース一覧の機械可読取得 | `jj workspace list --ignore-working-copy -T '"{\"name\":" ++ json(name) ++ ",\"change_id\":" ++ json(target.change_id().short(12)) ++ ",\"commit_id\":" ++ json(target.commit_id()) ++ ",\"parents\":" ++ json(target.parents().map(\|c\| c.change_id().short(12))) ++ ",\"empty\":" ++ json(target.empty()) ++ "}\n"'` | `exit=0`。1 行 1 ワークスペースの厳密な JSON Lines（`default`, `ws-2`, `ws-3`）が出力される。 |
| 親ワークスペースの非汚染 | ルート `.gitignore` に `.agent_os/`、かつ `.agent_os/.gitignore` に `*` がある状態で `.agent_os/ws/2`・`3` を作成・ファイル編集後、親で `jj status` を実行 | `exit=0`、`The working copy has no changes.`。親の `@` (`pltysnxl`) も `@-` (`qylqnypp`) も **1 バイトも汚れない** ことを確認。 |

> **パス指定の注意点（実測）**: `jj -R <repo_root> workspace add <dest>` に相対パスを渡すと、`jj` は `-R` ではなくプロセス起動時の `workingDirectory` 基準で `<dest>` を解決する。ドライバ実装では必ず `workingDirectory: mainWorkspaceRoot` に固定した上で、`<dest>` にも正規化済み絶対パスを渡すこと。

### 2.2 【重要実測】ネスト配置 `.agent_os/ws/<pid>` における Dart Pub Workspaces 解決と並列 `dart test`

ルート `pubspec.yaml` に `workspace: [packages/pkg_a, packages/pkg_b]`（`pkg_b` が `pkg_a` に依存）を持つプロジェクトを `.agent_os/ws/<pid>` に展開して検証した結果、**事前の `dart pub get --offline` を省略した場合に重大なクロスワークスペース誤解決が発生する**ことを実証した。

| ケース | 操作内容 | 終了コード・実際の観測結果 |
| --- | --- | --- |
| **失敗条件（`dart pub get` 未実行での `dart analyze`）** | `jj workspace add` 直後（`.dart_tool/` は `.gitignore` 対象のため子直下に `.dart_tool/package_config.json` が未生成の状態）で、子 `ws-5` の `pkg_a` に新関数 `addedOnlyInWs5()` を追加し `pkg_b` から呼び出して `ws-5` で `dart analyze` を実行 | **`exit=3`（失敗）**:<br>`error - packages\pkg_b\lib\pkg_b.dart:2:19 - The function 'addedOnlyInWs5' isn't defined.`<br>**原因**: 子直下に `.dart_tool/package_config.json` が無いため、Dart が上方向へディレクトリを遡って **親リポジトリ `<root>/.dart_tool/package_config.json` に誤解決し、親側の古い `pkg_a` を参照した**。 |
| **解決条件（`dart pub get --offline` 実行後）** | 子 `ws-5` ルートで `dart pub get --offline` を 1 回実行してから `dart analyze` および `dart test packages` を実行 | `dart pub get --offline` はネットワーク通信なしで **`exit=0`（約 `790〜830ms`）** で完了し、子直下に `.dart_tool/package_config.json`（`pkg_a` の `rootUri: "../packages/pkg_a"`）を生成。直後の `dart analyze` は **`exit=0` (`No issues found!`)**、`dart test packages` も **`exit=0` (`All tests passed!`)** となった。 |
| **Pub Workspaces ルートでの `dart test` 引数** | ルート直下に `test/` フォルダがなく `packages/*/test/` のみ存在する構成で：① `dart test`（引数なし） vs ② `dart test packages` | ① 引数なし `dart test` は **`exit=65`** (`No test files were passed and the default "test/" directory doesn't exist.`)。<br>② `dart test packages`（または `dart test packages/<pkg>` / パッケージディレクトリを `workingDir` にした `dart test`）は **`exit=0`** で全テスト通過。 |
| **2 子ワークスペース同時並列実行** | `ws-2`（戻り値 `200`/`205`）と `ws-3`（戻り値 `300`/`305`）で別プロセスから同時に `dart pub get --offline` + `dart test packages/...` を並列実行 | 両方 **`pubCode=0`（`831ms` / `789ms`）、`testCode=0`（計 `5.33s` / `5.32s`）**。PUB_CACHE や `.dart_tool` のロック競合は一切発生せず、各ワークスペースの編集内容が完全に独立して検証された。 |

### 2.3 `-R <ws_path>` スナップショット・Op 直列化・`forget` / `remove` 回収

- **子ワークスペースの個別スナップショット**: メインルートから `jj -R <ws_abs_path> op log --no-graph --limit 1 -T "self.id()"` を単一ミューテックス内で実行すると、該当子ワークスペースの未追跡/変更ファイルのみが `<ws_name>@` にスナップショットされる。
- **Op-Log 一本道の確認**: 全 `jj` 更新操作を単一キューで直列実行した結果、`jj op log --no-graph -T 'json(self.parents().len())'` は初期 root Operation (`0`) を除く全エントリで `1` となり、Concurrent Operation Heads は 0 件であった。
- **ワークスペース破棄とコミット残存仕様（2 方式の実測比較）**:
  1. `jj workspace forget <ws_name>`（`exit=0`）: リポジトリのワークスペース追跡（および Colocated 時の Git worktree 登録）のみを解除し、ディスク上の `.agent_os/ws/<pid>` ディレクトリは残す。その後ホスト側でディレクトリを再帰削除できる。**ワーカーが作成したコミット `<c_w>` は `empty=false` のままリポジトリ内に完全残存し、`Change ID` で後続マージにそのまま利用できる。**
  2. `jj workspace remove <ws_name>`（`jj 0.46.0` で利用可能、`exit=0`）: 追跡解除と同時に `.dart_tool/` 等を含むワークスペースディレクトリもディスクから削除し、**ワーカーのコミット `<c_w>` も同様にリポジトリ内に完全残存する**ことを確認した。

---

## 3. ローカルで確認した実行結果（問い2：多親マージ・First-Class Conflicts・最終統合手順）

### 3.1 `jj new <c1> <c2>` 多親マージと競合ファイル一覧の機械可読取得

| 検証項目 | 実行コマンド / 条件 | 実測結果 |
| --- | --- | --- |
| 非重複変更の多親マージ | `jj new <c1> <c2> -m "merge clean"` | `exit=0`, `conflict: false`, `parents` に 2 つの親を持つクリーンなマージコミットが即座に生成される。 |
| 同一関数衝突時の多親マージ | `c1` (`return 111;`) と `c2` (`return 222;`) を `jj new <c1> <c2> -m "merge with conflict"` で合流 | **`exit=0`（異常停止しない）**。`conflict: true` のコミットが正常生成され、`stderr` に `Warning: There are unresolved conflicts at these paths:` が出力される。 |
| **`jj resolve --list` の罠** | ① 競合ありコミットで `jj resolve --list -r <rev> --ignore-working-copy`<br>② **競合なしコミット**で同コマンドを実行 | ① 競合あり時は `exit=0` で `sub dir\spaced file.txt    2-sided conflict`（Windows では `\` 区切り＋空白パディングの整形文字列）を出力。<br>② **競合なし時は `exit=2`, `stderr='Error: No conflicts found at this revision'` でエラー終了する！** |
| **推奨：`conflicted_files` JSON テンプレート** | `jj log --no-graph -r <rev> --ignore-working-copy -T '"{\"conflict\":" ++ json(conflict) ++ ",\"files\":" ++ json(conflicted_files.map(\|e\| e.path())) ++ "}\n"'` | **競合の有無にかかわらず常に `exit=0`**。<br>- 競合あり時: `{"conflict":true,"files":["calc.dart","sub dir/spaced file.txt"]}`（空白入りパスも POSIX `/` 区切りの厳密な JSON 配列で返却）<br>- 競合なし時: `{"conflict":false,"files":[]}` |

### 3.2 `jj 0.46.0` のコンフリクトマーカー形式と解消遷移

2 ワーカーが `calc.dart` の同一行を書き換えた際、マージコミットのワーキングコピーに展開された実測マーカー全文：

```text
int calc() {
<<<<<<< conflict 1 of 1
%%%%%%% diff from: xpyopqwu db489ee4 "lead working change"
\\\\\\\        to: trlwvxty 347f844f "worker 1 conflict"
-  return 0;
+  return 111; // from worker 1
+++++++ pwzyylxn 1ea71151 "worker 2 conflict"
  return 222; // from worker 2
>>>>>>> conflict 1 of 1 ends
}
```

- 上記ファイルをマーカーなしの統合コード（`return 111 + 222;`）に書き換えてスナップショットした直後、テンプレート出力が `{"conflict":false,"files":[]}` へ自動遷移することを実測確認した。

### 3.3 多親マージコミット `M`（＋ワーカーコミット群）を単一作業チェンジ `W_lead` へ統合する非対話手順

親 2 つを持つマージコミット `M` 上で素の `jj squash -u` を実行すると、**`exit=1` (`Error: Cannot squash merge commits without a specified destination`)** で失敗する。人間の直前チェンジ `@-` (`userParent`) の上に切った単一作業チェンジ `W_lead` へ、`c1`, `c2`, `M`（競合解消済み）の成果を非対話で平坦化統合する以下の **2 方式** がともに `exit=0` で成立することを実測確認した：

| 方式 | 実行コマンド列（すべて `exit=0` 確認済み） | 完了後のコミットグラフと特徴 |
| --- | --- | --- |
| **方式 A：ツリー転写＋一時チェンジ破棄**<br>（`restore` + `edit` + `abandon`） | 1. `jj restore --from <M> --into <W_lead>`<br>2. `jj edit <W_lead>`<br>3. `jj abandon <M> <c1> <c2>` | `userParent` の直上に単一親の `W_lead (@)` だけが残り、余分な空コミットすら生成されない。`M` が `W_lead` の子孫として作られていれば `W_lead` の先行編集も `M` の競合解消結果も 100% バイト一致で保持され、そのまま既存の単一親 `jj squash -u`（`sys_tx_squash`）へ直結できる。 |
| **方式 B：範囲指定一括 Squash**<br>（`squash --from ... --into`） | 1. `jj squash --from "(<W_lead>::<M>) ~ <W_lead>" --into <W_lead> -u`<br>2. （`W_lead` に戻る場合）`jj edit <W_lead>` | 1 コマンドで `c1`, `c2`, `M`（競合解消差分含む）が `W_lead` へ統合され、元コミット群は自動 abandon される（直後の `@` は `W_lead` の上の新規空コミットになるため、必要に応じて `edit <W_lead>` または空 `@` の abandon を行う）。`M` 分岐後に `W_lead` 側でも別ファイルを並行編集していた場合の 3-way 合流にも強い。 |

---

## 4. ローカルで確認した実行結果（問い3：Stacked Changes × 自動リベースと `stale` 追従）

タスク A のワークスペース `ws-a` (`c_A`) の上に、依存タスク B のワークスペース `ws-b` (`c_B`, `-r <c_A>`) を積んで検証した実測結果：

1. **コミットグラフ上の即時自動リベース**:
   - `ws-a` 側でファイルを更新してスナップショットすると、その場で `Rebased 1 descendant commits onto updated working copy.` が実行され、`--ignore-working-copy` で参照したコミットグラフ上では `c_B` の親 `commit_id` が即座に新しい `c_A` の `commit_id` へ更新される。
2. **`ws-b` の Stale Working Copy エラーと追従（非競合時）**:
   - 自動リベース直後、`ws-b` のディスク上のファイルはまだ更新前のままであり、`jj -R <ws_B> status` を呼ぶと **`exit=1`**・`stderr`: `Error: The working copy is stale (not updated since operation <op>). Hint: Run 'jj workspace update-stale' to update it.` となる。
   - `jj -R <ws_B> workspace update-stale` を実行すると **`exit=0`** で完了し、`ws-b` 上の実ファイルが `c_A` の最新内容に更新されつつ、`c_B` 自身の編集ファイルも無傷で維持される。
3. **競合発生時の自動リベースと `workspace update-stale`**:
   - `c_A` と `c_B` が同一ファイルの同一行を編集していた場合も、`ws-a` スナップショット時に自動リベースは停止せず `c_B` が `conflict: true` になる。続く `jj -R <ws_B> workspace update-stale` も **`exit=0` で成功** し、`ws-b` のディスク上の該当ファイルにコンフリクトマーカーが書き出される。
4. **【重大な罠】`ws-b` に未スナップショットのローカル変更がある状態で親 `c_A` が更新された場合**:
   - `ws-b` 上でファイルを作成・編集したまま `jj` スナップショットを取らずに放置し、先に `ws-a` の更新で `c_B` が自動リベースされた後で `jj -R <ws_B> workspace update-stale` を実行すると、`Concurrent modification detected` により同一 `Change ID` が `(divergent)`（例: `zpsoopvm/0` と `zpsoopvm/2`）に分裂し、未スナップショット変更が片方の分裂コミットへ取り残されてワーキングコピー上から消える事象を実測確認した。

---

## 5. 判断・経験則と現行コードベースへの接続前提

1. **子ワークスペース払い出しの標準シーケンス**:
   - ① `JjDriver` 単一ミューテックス内で `jj workspace add --no-colocate <abs_ws_path> --name <ws_name> -r <base_change_id> -m "<desc>"` を実行し、払い出された無名 `Change ID` を子 PCB の `JjTxContext` に記録する。
   - ② 対象ワークスペースに `pubspec.yaml` が存在する場合、ワーカー起動前にホスト側（ミューテックス外・並列可）で `dart pub get --offline`（`workingDirectory: <abs_ws_path>`）を実行して `.dart_tool/package_config.json` を生成させる（Ring 3 ワーカーは TTY 独占原則により `sys_exec("dart", ["pub", "get"])` を自己承認できないため、カーネルブートストラップ側で行うのが必須）。
2. **Divergent 防止のための即時スナップショット鉄則と自動 `update-stale`**:
   - 全ワークスペースにおいて、`sys_write_file` / `sys_edit_block` / `sys_exec` 完了直後に必ず `JjDriver` 単一ミューテックス内で `jj -R <abs_ws_path>` スナップショットを実行し、未スナップショットの dirty ファイルを放置しないこと。
   - また Stacked Changes 運用時に親更新で子ワークスペースが `stale` になった場合、`JjDriver` が `-R <abs_ws_path>` コマンドで `The working copy is stale` を検知した際（または親リベース直後）にミューテックス内で `jj -R <abs_ws_path> workspace update-stale` を自動実行すれば、Divergent を起こすことなく安全に実ファイルを追従させられる。
3. **現行 Stage 2 コードベースでプロセス別ワークスペース対応が必要な箇所**:
   - `HostFsDriver` (`packages/agent_drivers/lib/src/fs/host_fs_driver.dart`): `readLines`/`glob`/`grep`/`writeFile`/`editBlock` は `namespaceOverride: exec.pcb.namespace` を受け取っているが、内部コールバック `_ensureActiveTransaction` と `_syncWorkingCopySnapshot` が引数なし（メインワークスペース固定）になっているため、呼び出し元 `pcb` に応じて子ワークスペース用の `-R <ws_path>` スナップショットへ分岐させる必要がある。
   - `Win32JobExecDriver` & `SysExecClassifier` (`packages/agent_drivers/lib/src/exec/`): `this.namespace`（メインワークスペース固定）を参照しているため、`exec.pcb.namespace` を受け取って子ワークスペース内で `dart test` / `dart analyze` を実行・スナップショットできるよう拡張する必要がある。
   - `WorkspacePageFreshnessChecker` & `buildMemPageinSyscallDefinition` (`packages/agent_drivers/lib/src/memory/workspace_page_freshness_checker.dart`): `pcb.namespace` と対象ワークスペースの `@` `commit_id` を使うよう拡張する必要がある。

---

## 6. 未確認事項と再確認条件

- **未確認事項**: 3 個以上の `WorkspaceWorker` が実 LLM 推論と `dart test` を同時に回しながら統合・競合解消まで自律完走する E2 結合挙動は、Stage 3 実装工程の統合試験で確認する対象である。
- **再確認トリガー**: Jujutsu (`jj`) のマイナーバージョン更新時（`0.46.x` → `0.47+` での `workspace add/remove` フラグや `conflicted_files` テンプレート仕様変更有無）、および Dart SDK 更新時（Pub Workspaces の `package_config.json` 探索規則変更有無）。
