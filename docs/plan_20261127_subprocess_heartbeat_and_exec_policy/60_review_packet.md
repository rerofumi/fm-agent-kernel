# 60_review_packet.md — 計画レビュー資料（利用者確認用）

- **プラン**: `plan_20261127_subprocess_heartbeat_and_exec_policy`（区分: Full / 計画版 `r1` / 結果: **`ready`**）
- **対象基準ソース版**: `main` bookmark / Git commit `1192e3d02f301eef94d8e1c008dd20d439f5c796`（`jj new main` 作業コピー）
- **作成日**: `2026-11-28`（計画開始: `2026-11-27`）

---

## 1. 誰の何が変わるか（変更の全体像）

Windows 上で `agent_os_daemon` / `acp_cli_client` / Kanban UI を利用する開発者の運用において、Gitea Issue #1（サブプロセスの実行時間制限・Heartbeat 監視）および Issue #3（サブプロセスでの `sys_exec` 実行許可設定）を以下の通り解決します（※Issue #2 は別 PR #4 で解決済みのため対象外）。

1. **サブプロセス実行時間・ステップ上限の拡張と Heartbeat（無進行 Stall）監視（`REQ-01`, `REQ-02`）**:
   - Ring 3 子プロセス（`sys_spawn`）の総壁時計上限を 5 分 → **最大 60 分（`3,600,000ms`、省略時既定 10 分 = `600,000ms`）**、最大ステップ数を 32 → **最大 128（省略時既定 `32`）** へ拡張します。
   - ホスト側（`IsolateWorkerHost`）で ReAct ステップ遷移・syscall 開始/完了を **Heartbeat** として単調時計で計測し、無進行状態が **`heartbeatTimeoutMs`（既定 5 分 = `300,000ms`、最大 10 分 = `600,000ms`）** を超えた場合のみ `HEARTBEAT_TIMEOUT`（`ETIMEDOUT`, `exitCode: 124`）で自動強制終了します。`SIGSTOP` サスペンド中は壁時計・Heartbeat ともに一時停止し、連続ツール失敗回数（`consecutiveErrors` / `lastErrorReason`）もループ兆候として記録します。
2. **`sys_wait` タイムアウト時の非破壊継続と親プロセス・ACP からの監視（`REQ-03`）**:
   - `sys_wait` が `timeoutMs`（既定 2 分、最大 10 分）に達した際、従来の「即 `WAIT_TIMEOUT` kill」を廃止し、**子プロセスを kill せず継続実行させたまま**、完了回収分 `children`・`timedOut`・継続中 `running`（PID、状態、ステップ進捗、無進行時間 `idleMs`、実行中/直近 syscall、連続エラー数等の Heartbeat スナップショット）を返却します。
   - 親（`LeadAgent`）は Heartbeat 進行を確認して再度 `sys_wait` で完走回収するか、異常ループ時は `sys_kill`（`SIGSTOP` / `SIGCONT` / `SIGKILL`）で介入できます。ACP `_fm_agent_os/processes` および CLI `/ps` からも同じ Heartbeat 情報を確認でき、親ターン終了時の孤児プロセス自動回収（`onTurnExitCleanup`）は維持されます。
3. **`.agent_os/exec_policy.json` による直接実行コマンド許可とプロンプト反映（`REQ-04`, `REQ-05`）**:
   - `<sessionCwd>/.agent_os/exec_policy.json`（不在時は `<Directory.current>/.agent_os/exec_policy.json`）で直接実行コマンド（`command`、任意の `allowedSubcommands` / `allowedArgPrefixes`、`maxTimeoutMs`）を定義でき、Ring 3（`workspace_worker`, `conflict_resolver`）および Ring 2（`LeadAgent`）で `TTY_MONOPOLY_DENIED` や毎回承認なしに即時実行できます。
   - 併せて `Win32JobExecDriver` の最大タイムアウトを 10 分（`600,000ms`）へ揃え、すべての直接実行コマンドで `/workspace/...`（および `--opt=/workspace/...`）仮想パス引数を隔離ワークスペース相対パスへ安全に解決します。
   - 起動時にロードした追加許可コマンドと新 `sys_spawn` / `sys_wait` 仕様を `AgentPrompts`（`LeadAgent`, `WorkspaceWorker`, `ConflictResolver`）およびツールスキーマ説明へ決定的に反映します。

### 主要なセキュリティ制約と対象外
- **維持する絶対ハードガード**: シェル実行ファイル（`powershell`, `pwsh`, `cmd`, `sh`, `bash`, `wsl` 等 10 種）・シェルメタ文字・パス区切り付きコマンド・短オプション連結パス（`-oC:\...`, `-C../outside`, `-f.env` 等）・生 `git`/`jj`（`--` 経由含む）・直接ネットワークコマンド（`curl`, `wget` 等）・`/workspace` 外や保護パス（`.jj`, `.git`, `.agent_os`, `.env*`）は `.agent_os/exec_policy.json` に記述しても決して自動許可されません（Fail-Closed）。また `.agent_os/exec_policy.json` 自体は `VfsNamespace` によりエージェントからの読み書きが遮断されます。
- **`mise` 等の扱い（対象外）**: 特定ツール専用の信頼フィールドや `mise.toml` 専用の VFS 書き込みガードは設けず、汎用的な直接実行許可ルールに統一します（どのツールを `.agent_os/exec_policy.json` に登録するかは利用者の判断・責任）。稼働中のホットリロードや新規性能数値目標も対象外です。

---

## 2. 判断事項

- **新たな利用者判断: 不要**（`B-01`〜`B-04` は利用者確認済み、`OM-01`〜`OM-03` は利用者「おまかせ」合意に基づき確定・記録済みです。下記おまかせ採用値に変更希望がある場合のみ実装開始前にお知らせください）。

| ID | 区分 | 確定内容（選択肢・理由・残る制約は [30_requirement.md](./30_requirement.md) §3.2 / [90_status.md](./90_status.md) 参照） |
| :--- | :---: | :--- |
| `B-01` | 利用者合意 | 機能別設定ファイル `.agent_os/exec_policy.json` を新設（`<sessionCwd>` > `<Directory.current>` 優先） |
| `B-02` | 利用者合意 | シェル全面禁止・直接実行コマンドのみ許可可。`mise` 等の特別扱い専用ガードは設けず汎用ルールに統一 |
| `B-03` | 利用者合意 | `maxAllowedWallTimeMs = 3,600,000`（60分）、`maxAllowedSteps = 128`、Heartbeat 既定 `300,000`（5分） |
| `B-04` | 利用者合意 | `sys_wait` タイムアウト時は子を kill せず継続させ `children` + `running`（Heartbeat スナップショット）を返す新デフォルト化 |
| `OM-01` | おまかせ採用 | `sys_spawn` 省略時の `defaultMaxWallTimeMs = 600,000`（10分）（※10分超は `maxWallTimeMs` 明示指定） |
| `OM-02` | おまかせ採用 | `sys_spawn` 省略時の `defaultMaxSteps = 32`（※32ステップ超は `maxSteps` 明示指定） |
| `OM-03` | おまかせ採用 | `heartbeatTimeoutMs` 指定範囲 `1..600,000`（既定 5分、最大 10分；`E1` テストでの短時間発火検証と重い単発ビルドに対応） |

---

## 3. 未確認事項と実装時の検証方針

- **事前技術調査の未解決事項**: **0 件**（現行コード境界と既存 cheatsheet で全設計前提を確認済み）。
- **実装工程で検証する事項**: 計画段階のため製品コード変更・テスト実行・3 `.exe` 再コンパイルは未実施です。本環境（Windows 11 + Dart SDK `3.14.1` + `jj`）において `EX`（確認不能）項目はなく、`WP-1`〜`WP-4` にて自動テスト・AOT ビルド（`E1`）、実 Isolate サブプロセスによる `sys_wait` ポーリングおよび `.agent_os/exec_policy.json` 実行観測（`E2`）、実装境界照合（`E3`）をすべて直接実施します。

---

## 4. 独立計画レビュー結果と正本リンク

- **独立レビュー結果（[50_review_notes.md](./50_review_notes.md)）**:
  - 初回レビュー（PT-04）で検出された `Must-fix` 2 件（`RV-001`: 複数回 `SIGSTOP`/`SIGCONT` 時の Heartbeat 残り時間二重減算、`RV-002`: `=` なし短オプション連結パス引数のガードおよび `/` 仮想パス排他分岐）を PT-05 で仕様反映し、差分再レビュー（PT-06）にて **残存 `Critical: 0` 件・残存 `Must-fix: 0` 件**（`Suggest: 3` 件は通常モード見送り記録）を確認済みです。
  - **次の作業**: **`implement` 工程へ進行可能（`WP-1` と `WP-2` はパッケージ完全分離のため同時並列または直列で即時開始可 → `WP-3` 統合 → `WP-4` 総合検証 → 独立 `acceptance`）**。

| 正本文書 | 内容 |
| :--- | :--- |
| [10_claim.md](./10_claim.md) | Gitea Issue #1 / #3 の原意・現行課題・対象者 |
| [20_app_requirement.md](./20_app_requirement.md) | 現行/変更後対比・代表シナリオ `S-01`〜`S-04`・範囲と対象外 |
| [30_requirement.md](./30_requirement.md) | 要求一覧（`REQ-01`〜`REQ-06`）・受け入れ条件・A/B/おまかせ決定記録 |
| [40_specification.md](./40_specification.md) | 全体アーキテクチャ・設計 ID マップ（`D-501`〜`D-510`）・横断優先順位と副作用境界 |
| [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md) | `SpawnSpec` 上限・Heartbeat 計測・`SIGSTOP` 連動・非破壊 `sys_wait`・ACP 監視詳細 |
| [42_spec_exec_policy.md](./42_spec_exec_policy.md) | `.agent_os/exec_policy.json`・`SysExecClassifier`・`Win32JobExecDriver`・プロンプト結線詳細 |
| [41_work_packages.md](./41_work_packages.md) | `WP-1` // `WP-2` → `WP-3` → `WP-4` の作業分解・同時編集ゼロ境界・確認手順 |
| [50_review_notes.md](./50_review_notes.md) | 独立計画レビュー・差分再レビュー所見と解消記録 |
| [env_manifest.md](./env_manifest.md) | 環境宣言（基準ソース版・計画成果物ハッシュ・テスト資産・照合方法） |
| [90_status.md](./90_status.md) | 進捗管理正本 |
