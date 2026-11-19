# 4. 実現可能性の評価・リスク分析・段階的ロードマップ（`jj` ネイティブ構成）

[01_idea.md](../../01_idea.md) が掲げる「実際にざっくりと作って調べようというプロトタイピングプロジェクト」という目的に加え、**最初から Jujutsu (`jj`) をネイティブ前提とする方針** を踏まえ、実現可能性・技術的リスク・段階的な構築手順を評価する。

---

## 4.1 機能別・実現可能性と費用対効果マトリクス

`jj` を前提に据えたことで、当初最も実装コストが高いと見込まれた **「Copy-on-Write トランザクション・ロールバック・並列作業空間」の実装難易度が大幅に下がり、逆に完成度と独自性が跳ね上がる** 結果となった。

| 構成要素 | 実現難易度 | プロトタイプ価値 | 実現可能性の根拠と現実的な実装アプローチ |
| :--- | :---: | :---: | :--- |
| **カーネル（Syscall 層）とエージェントループの分離** | **低〜中** | **極大** | 関数呼び出しを `SyscallGate` 1 箇所に集約するだけで骨格が成立する。見通し・テスタビリティが劇的に向上するため **最初から入れるべき最重要設計**。 |
| **`jj` ネイティブ CoW トランザクション & ロールバック** | **低〜中** | **極大** | 自作 OverlayFS が不要になる。`jj new` で作業層を作り、`jj op restore` / `jj abandon` で巻き戻し、`jj workspace` と First-Class Conflicts で並列統合できるため、**最小のコード量で最強の差別化機能** になる。 |
| **Dart によるネイティブ exe 化 & Windows DLL 連携** | **低** | **高** | `dart compile exe` と `dart:ffi`（`package:win32`）は成熟している。Windows Job Object による外部プロセス一括終了も数十行の FFI ラッパーで実装可能。 |
| **プロンプト毎のプロバイダ/モデル切替** | **低〜中** | **極大** | 会話履歴をプロバイダ非依存の Canonical IR で保持し、OpenAI 互換 `/v1/chat/completions` ベースで Local Ollama / Ollama Cloud / OpenRouter ドライバを実装すれば綺麗に動く。 |
| **全システムコール監査 (`strace`) & API/キャッシュ監視** | **低** | **極大** | `SyscallGate` と `LlmDriver` に JSONL ロガーを挟むだけで 100% 記録可能。さらにログに `jj` の `op_id` を刻むことでコード状態の完全なタイムトラベル追跡まで手に入る。 |
| **ACP インターフェース分離 ＋ 簡易 CLI クライアント** | **中** | **高** | JSON-RPC 2.0 over `stdio` は Dart の `Stream` と親和性が高い。まずは ACP のコアサブセットに絞れば短期実装可能。 |
| **マルチプロセス（Isolate）＋ 有界メールボックス IPC** | **中** | **高** | 初期は論理プロセス（同一 Isolate）でも動くよう抽象化しつつ、`Isolate.spawn` + `SendPort` に載せることで並列 AI チームへ拡張できる。 |
| **ケーパビリティ方式 ＋ 階層クオータ（Quota）** | **低〜中** | **高** | カーネル内の `CSpace` テーブルとトークン/費用/時間/子数カウンタで確実に強制可能。暴走防止の安全装置として極めてコスパが良い。 |
| **Prefix 保持型・仮想コンテキストページング** | **中〜高** | **中〜高** | Clean Page（ファイル閲覧や `jj diff` 結果）のスタブ化とモデル切替時の自動縮小は費用対効果が非常に高い。高度な自動要約ページャは後半フェーズで段階導入する。 |
| **シグナルと Supervisor による自動復旧** | **中** | **中** | まずはタイムアウト・強制停止（`SIGKILL`）＋ `jj` ワークスペース回収から始め、再起動ポリシーは運用しながら育てる。 |

---

## 4.2 技術的リスク・落とし穴と対策（`jj` 特有の論点を含む）

### リスク 1：LLM の「Git 手癖バイアス」による誤操作
- **懸念**: ほとんどの LLM は学習データの大半が Git であるため、放っておくとシェル実行で `git checkout -b` や `git stash` を叩いたり、`jj` の `@`（作業コピー＝コミット）とステージングの概念を取り違えたりする。
- **対策**:
  1. **`sys_exec` での生 `git` / `jj` 実行を Hook で完全ブロック** し、意図が明確な高水準システムコール（`sys_jj_status`, `sys_jj_diff`, `sys_tx_checkpoint`, `sys_tx_rollback` 等）だけを提供する。
  2. Segment 0（Pinned System Prompt）に数行だけ「この OS では作業状態は自動的に現チェンジへスナップショットされる（`git add` 不要）」というメンタルモデルを明記する。

### リスク 2：並列 `jj` コマンド実行による Op-Head 分岐と巨大生成物スナップショット
- **懸念**:
  1. 複数プロセスが同時に `jj` 更新コマンドを走らせると Operation Head が分岐し、`@` 解決エラーになる場合がある。
  2. テストやビルドで生成された巨大バイナリが `.gitignore` 漏れしていると、`jj` の自動スナップショットが重くなるか `snapshot.max-new-file-size` エラーで止まる。
- **対策**:
  1. **`JjDriver` 内でのミューテックス直列化**（ファイル編集とテスト実行は各 `jj workspace` で完全並列、`jj` メタデータコマンドだけ単一キュー実行）＋ 参照系の `--ignore-working-copy` 徹底で Op-Head 分岐をゼロにする。
  2. ワークスペース初期化時に `snapshot.max-new-file-size` と無視設定（`.agent_os/` 等）をカーネルが自動検査・保護する。

### リスク 3：「OS ごっこ」によるシステムコール粒度の細分化しすぎ
- **懸念**: POSIX の低レベル `open/lseek/read` をそのまま真似ると、ローカル Ollama 等の小型モデルでツール呼び出し回数とエラーが増える。
- **対策**: 機構（権限・クオータ・監査）は OS に学びつつ、システムコールの粒度は `sys_read_lines`, `sys_edit_block`, `sys_grep` のように LLM が 1 回で正確に意図を表現できる高水準プリミティブにする。

### リスク 4：Dart AOT コンパイル（`exe`）時の動的プラグイン制約
- **懸念**: `dart compile exe` では実行時に未コンパイル `.dart` ファイルを動的 `import` できない。
- **対策**: コアドライバはコンパイル時登録とし、動的追加する拡張は **MCP（別プロセス JSON-RPC）** と **Skill（Markdown + スクリプト）** で受けることで、単一 `exe` の軽快さと動的拡張性を両立する。

---

## 4.3 推奨 Dart ワークスペース・パッケージ構成案

Dart の Pub Workspaces を使い、`agent_kernel` が外部通信や特定 LLM に一切依存しない構造をコンパイラで強制する。

```text
fm-agent-os-2/
├── pubspec.yaml                  # Dart Workspace ルート
├── packages/
│   ├── agent_kernel/             # [Ring 0] TCB コア (LLM/HTTP/UI への依存ゼロ！)
│   │   ├── pcb.dart              # プロセス制御ブロック (JjTxContext 保持)
│   │   ├── syscall_gate.dart     # システムコール検証・Ring判定・Hook実行
│   │   ├── capability.dart       # CSpace・ハンドル派生・権限減衰
│   │   ├── quota.dart            # 階層型クオータ寄贈・回収
│   │   ├── ipc_mailbox.dart      # 有界メールボックス・シグナル配送
│   │   ├── vfs_namespace.dart    # プライベート名前空間・パス正規化・排他リース
│   │   ├── context_memory.dart   # Canonical Page IR・Prefix保持ページテーブル
│   │   └── audit_logger.dart     # strace 監査 (jjOpId 紐付) & キャッシュ監視
│   │
│   ├── agent_runtime/            # [Ring 1-3] エージェントプロセス実行環境
│   │   ├── isolate_runner.dart   # Isolate / GreenTask 起動アダプタ
│   │   ├── agent_loop.dart       # マイクロエージェントの基本ループ実装
│   │   ├── context_pager.dart    # Cleanスタブ化・Dirty要約退避サービス
│   │   └── supervisor.dart       # 子プロセス監視・再起動ポリシー
│   │
│   ├── agent_drivers/            # [Drivers] 外部連携・OS/VCS 固有処理
│   │   ├── jj_driver.dart        # ★ Jujutsu (jj) 専用ドライバ (Op直列化・workspace・merge)
│   │   ├── llm_openai_compat.dart# Ollama (Local/Cloud) & OpenRouter 共通基盤
│   │   ├── host_fs_driver.dart   # スコープ検証・CAS ハッシュ付きファイル I/O
│   │   ├── win32_job_exec.dart   # Windows Job Object FFI 付きコマンド実行
│   │   └── mcp_driver.dart       # MCP クライアント連携
│   │
│   └── agent_acp/                # [UI 境界] ACP プロトコル層
│       ├── acp_server.dart       # stdio JSON-RPC 2.0 ACP サーバー
│       └── bin/
│           ├── agent_os_daemon.dart # エージェントエンジン本体エントリポイント
│           └── acp_cli_client.dart  # 検証・デバッグ用簡易 ACP REPL クライアント
```

---

## 4.4 段階的プロトタイピング計画（概要）

先行試作で直面した 3 つの暗礁（権限の混線・コンテキスト溢れ・同時ファイル編集の衝突）を二度と踏まないための具体的な 7 段階直交ステップは [05_three_walls_and_step_plan.md](./05_three_walls_and_step_plan.md) に詳述する。大枠のマイルストーンは以下の通りである。

- **Milestone 1 (Step 1〜2)**: 防波堤カーネル ＋ Local Ollama/OpenRouter 毎ターン切替 ＋ **`jj new` / `jj op restore` による絶対安全なシングルエージェント編集** ＋ ACP 分離（実用シングルエージェント完成）
- **Milestone 2 (Step 3〜4)**: Prefix 保持 Clean Page スタブ化 ＋ **Read-Only 子プロセス（`Isolate`）並列調査と `exit` メモリ回収**（コンテキスト溢れと承認混線の完全克服）
- **Milestone 3 (Step 5〜7)**: **`jj workspace` による並列ワーカー空間 ＋ `jj new <c1> <c2>` 多親マージ ＆ First-Class Conflicts 解消 ＋ Stacked Changes カンバン運用**（「`jj` を自在に操る AI チーム OS」の完成）
