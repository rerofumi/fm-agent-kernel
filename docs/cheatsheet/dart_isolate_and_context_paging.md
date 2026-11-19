# Dart 3.14.1 AOT `Isolate` マルチプロセス境界・ACP `stdout` 純度・コンテキストページング実測

- **確認日**: `2026-11-19`
- **対象環境**: Windows 11 Pro 64-bit (`10.0.26300`) / PowerShell / `mise 2026.10.12`
- **対象技術・版**:
  - Dart SDK `3.14.1` (stable, `windows_x64`) / `dart compile exe`
  - Jujutsu `jj 0.46.0` (`7d382314f942`)
  - Local Ollama (`http://127.0.0.1:11434` / `http://192.168.0.5:11434`), Ollama Cloud (`https://ollama.com`), OpenRouter API v1 (`https://openrouter.ai/api/v1`)

---

## 1. Dart `3.14.1` AOT (`dart compile exe`) での `Isolate.spawn`・IPC・ACP `stdout` 純度

### 1.1 外部一次資料の事実
- **出典**: Dart API リファレンス（`Isolate.spawn`, `TransferableTypedData`, `ZoneSpecification`, 確認日 `2026-11-19`）および `dart compile exe` 公式仕様。
- `dart compile exe` で生成した AOT 実行ファイル内では、任意の `.dart` URI を動的ロードする `Isolate.spawnUri` は利用できないが、**同一コンパイル単位内のトップレベル関数または static メソッドをエントリポイントとする `Isolate.spawn<T>(entryPoint, message, ...)` は AOT でも標準サポートされる**（ツリーシェイキング対策が必要な場合は `@pragma('vm:entry-point')` を付与可能）。
- 各 `Isolate` は独立したヒープと独立した **Root `Zone`** を持つ。親 `Isolate` で設定した `ZoneSpecification`（`print` フック等）は、`Isolate.spawn` で生成される子 `Isolate` には**継承されない**。一方、OS レベルの標準入出力ファイルディスクリプタ（`stdin` / `stdout` / `stderr`）は同一 OS プロセス内の全 `Isolate` で共有される。

### 1.2 ローカルで確認した実行結果（`.planworks/pt01_smoke/q1_isolate/` での AOT `.exe` 検証）
- **操作・コマンド**:
  - `mise exec -- dart compile exe child_daemon.dart -o child_daemon.exe` で単一 Windows 実行ファイルを生成し、親ランナー（`ProcessStartInfo` で `StandardOutput` / `StandardError` を個別パイプ分離）から 3 モードを起動して出力行数と内容を検証（確認後 `.planworks/` は削除済み）。
- **観測結果**:

| 検証モード | 確認内容（期待） | 実際の観測結果（終了コード・出力） |
| --- | --- | --- |
| `normal_suite` | ①3 並列 `Isolate.spawn`（トップレベル関数×2 + static メソッド×1）<br>②`SendPort`/`ReceivePort` 双方向 IPC + `TransferableTypedData` (64 KiB) 往復 + `Isolate.exit`<br>③子 Isolate の未捕捉例外を `onError` + `onExit` で捕捉し親 Isolate が生存継続<br>④無限スピンループ子 Isolate を `Isolate.kill(priority: Isolate.immediate)` で即時強制終了<br>⑤子エントリポイント先頭でも `ZoneSpecification(print: ...)` を設定した場合の `stdout` 純度 | `exit=0`。<br>- 3 ワーカーすべて `byteLength: 65536`, `sum: 8355840` で正常応答・終了。<br>- 例外子 Isolate は `crashCaptured: true`（`Bad state: intentional child failure`）で捕捉され、親は無傷で継続。<br>- 無限スピン子 Isolate は `Isolate.kill(priority: Isolate.immediate)` 呼び出しから **`killLatencyMs: 0` ms** で即座に終了し `onExit` が発火。<br>- **`stdout` は JSON-RPC 応答の 1 行のみ**。親・子 3 個の `print()` 計 4 行はすべて `stderr` 側へ出力された。 |
| `unzoned_child_print` | 親 `main()` は `runZonedGuarded(..., print: -> stderr)` で保護済みだが、**子 Isolate エントリポイントで `runZoned` を張らずに `print('LEAKED_UNZONED_CHILD_PRINT')` を呼ぶ** | `exit=0` だが **`stdout` が 2 行になり、1 行目に生の `LEAKED_UNZONED_CHILD_PRINT` が混入した！**<br>（子 Isolate の Root Zone デフォルト `print` が直接 OS の `stdout` へ書き出すため、ACP JSON-RPC over `stdio` が即座に破損する失敗条件を実証）。 |
| `direct_stdout_in_zoned_child` | 子 Isolate エントリポイントを `ZoneSpecification(print: -> stderr)` で保護した状態で、**`dart:io` の `stdout.writeln(...)` を直接呼ぶ** | `exit=0` だが **`stdout` に `LEAKED_DIRECT_STDOUT_WRITELN` が混入した！**<br>（`dart:io` の `stdout` `IOSink` は `Zone.print` を経由せず直接 OS FD 1 へ書き込むため）。 |

### 1.3 判断・経験則（Stage 2 マルチプロセス × Zed ACP `stdio` 純度維持の鉄則）
1. **子 Isolate 共通ブートストラップラッパーの必須化**:
   - `Isolate.spawn` に渡すエントリポイント関数は、必ずカーネル/ランタイム共通のラッパー関数（先頭で `runZonedGuarded` + `ZoneSpecification(print: (self, parent, zone, line) => stderr.writeln(...))` を設定）で包んでからユーザー空間ループ（`Explorer` / `WebResearcher` 等）を起動すること。
2. **`stdout` シンク参照の単一箇所封じ込め維持**:
   - Stage 1 と同様、全パッケージを通じて `dart:io` の `stdout` に触れてよいのはホスト Isolate の `JsonRpcPeer`（および `acp_cli_client` 等の非デーモン CLI）のみとし、子 Isolate ランタイム・ドライバ・フック内での `stdout.` 直接参照をテスト（静的検査＋実 `.exe` サブプロセス純度テスト）で禁止し続けること。
3. **カーネル単一所有と IPC プロトコル境界**:
   - Dart の `Isolate` 間では `ProcessControlBlock`・`JjDriver` ミューテックス・`AuditLogger` ファイルハンドル・`ApprovalGate` 等のミュータブルオブジェクトは共有できない（`SendPort` 越しに送ろうとすると `ArgumentError: Illegal argument in isolate message` になる）。
   - **推奨構造**: Ring 0 カーネル（`SyscallGate`, `KernelProcessTable`, `JjDriver`, `AuditLogger`, `LlmRouter` 等）は **ホスト（親）Isolate 内に単一インスタンスとして常駐** させ、子 Isolate には「シリアライズ可能な初期構成＋親カーネル受付用の `SendPort`（システムコール RPC チャネル）＋制御受信用 `ReceivePort`」だけを渡す **Microkernel IPC Server パターン** を採ると、`JjDriver` の直列化・`AuditLogger` の単一ファイル追記・`Quota` の原子的加減算・TTY 独占（Ring 3 の承認要求即 `EPERM`）がすべてホスト Isolate 側で決定論的に保証される。

---

## 2. モデル別コンテキスト窓サイズの取得とフォールバック設計

### 2.1 外部一次資料の事実
- **Ollama 公式ドキュメント**（`https://docs.ollama.com/context-length`, `https://github.com/ollama/ollama/blob/main/docs/api.md`, 確認日 `2026-11-19`）:
  - `POST /api/show` (`{"model": "<name>"}`) は、`model_info` マップ内の `"<arch>.context_length"` に **モデルアーキテクチャ上の最大コンテキスト長** を返し、Modelfile で `PARAMETER num_ctx <N>` が指定されていれば `parameters` 文字列内に含める。
  - **重要仕様**: Local Ollama サーバーが実際に確保するコンテキスト窓サイズ（実効窓）は、リクエストの `options.num_ctx` ＞ Modelfile の `num_ctx` ＞ サーバー環境変数 `OLLAMA_CONTEXT_LENGTH` ＞ VRAM 容量別デフォルト（**`< 24 GiB VRAM`: `4,096` / `24〜48 GiB`: `32,768` / `>= 48 GiB`: `262,144`**）で決まる。一方、Ollama Cloud モデルは既定で最大コンテキスト長で稼働する。
  - ロード済みモデルの実効コンテキスト長は `GET /api/ps` の `models[].context_length`（整数）で取得できる。
- **OpenRouter 公式ドキュメント**（`https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties`, `https://openrouter.ai/docs/guides/overview/models`, 確認日 `2026-11-19`）:
  - `GET https://openrouter.ai/api/v1/models`（認証ヘッダ任意）は全公開モデルの配列 `data[]` を返し、各要素に `id` (`"<author>/<slug>"`), `context_length` (int), `top_provider.context_length` (int?), `top_provider.max_completion_tokens` (int?) が含まれる。

### 2.2 ローカルで確認した実行結果（3 プロバイダ実機プローブ）

| プロバイダ / API | 実測対象と結果（`status=200`） | 観測された重要な事実・罠 |
| --- | --- | --- |
| **Local Ollama** `POST /api/show` | `http://127.0.0.1:11434` および `http://192.168.0.5:11434` の導入済み 22 モデルを検査:<br>- `gemma4:12b`: `model_info["gemma4.context_length"] = 262144`, `parameters` に `num_ctx` なし<br>- `qwen3.8:27b`: `model_info["qwen35.context_length"] = 262144`, `num_ctx` なし<br>- `qwen3.8:27b_out256k`: `qwen35.context_length = 262144`, `parameters` に `num_ctx 256000`<br>- `fm-rpb04-e2-retry:latest`: `qwen35.context_length = 262144`, **`parameters` に `num_ctx 32768`**<br>- `muse-glimmer:30b`: `muse-glimmer.context_length = 131072` | 1. `model_info` のキー接頭辞は `gemma4.`, `qwen35.`, `qwen35moe.`, `glm5.2.`, `gptoss.` のようにモデルファミリ毎に異なるため、`key == 'context_length' \|\| key.endsWith('.context_length')` で走査する必要がある。<br>2. Modelfile で `num_ctx` が絞られているモデル（例: アーキテクチャ上限 `262,144` に対し `num_ctx 32768`）が実在する。 |
| **Local Ollama** `GET /api/ps` | `qwen3.5:0.8b`（`model_info` 上は `262,144`）をデフォルトロードして `/api/ps` を確認 → **`"context_length": 128000`**（本機の `OLLAMA_CONTEXT_LENGTH=128000` が反映）。<br>次に `options: {"num_ctx": 16384}` 付きで呼ぶと → **`"context_length": 16384`** に変化。 | **【重大な罠】`/api/show` の `model_info["*.context_length"]` (`262,144`) だけを信じて High Watermark (85% = 222k) を計算すると、実効窓 (`128,000` や一般 PC の既定 `4,096` / `32,768`) を超過して Ollama 側で無言の先頭切り詰め（KV キャッシュ全損）が起きる！** |
| **Ollama Cloud** `POST https://ollama.com/api/show` | `Authorization: Bearer <OLLAMA_API_KEY>` 付きで `{"model": "gpt-oss:120b"}` を送信 → `status=200`, `model_info["gptoss.context_length"] = 131072`, `capabilities: ["completion", "tools", "thinking"]`。 | Ollama Cloud でも Local と全く同じ `POST /api/show` が動作し、`*.context_length` が取得可能（Cloud は公式仕様通り最大窓で動作）。 |
| **OpenRouter** `GET https://openrouter.ai/api/v1/models` | `status=200`、ペイロード約 `899 KB`（468 モデル、所要 `981 ms`）:<br>- `openai/gpt-4o-mini`: `context_length=128000`, `max_completion_tokens=16384`<br>- `anthropic/claude-haiku-4.5`: `context_length=200000`, `max_completion_tokens=64000`<br>- `google/gemini-2.5-flash`: `context_length=1048576`, `max_completion_tokens=65535` | カタログ JSON が約 900 KB あるため、毎ターン取得せず **セッション内でメモリキャッシュ（初回必要時 1 回取得、失敗・タイムアウト時は静的テーブル／既定値へフォールバック）** すべきである。 |

### 2.3 判断・経験則（コンテキスト窓サイズ解決の優先順位）
1. **Local Ollama の実効コンテキスト窓決定ルール**:
   - ① `/api/ps` に該当モデルがロード済みなら、その `models[].context_length` が**現在割り当て済みの正確な実効窓**である。
   - ② 未ロード時は `/api/show` を 1 回呼び、`parameters` 内の `num_ctx <int>` があればそれを優先する。`num_ctx` 指定がない場合は、`model_info["*.context_length"]` を上限としつつ、環境変数 `OLLAMA_CONTEXT_LENGTH`（設定されていれば `min(archMax, envCtx)`）または安全既定上限（あるいはドライバから明示的に `options.num_ctx` を渡す場合はその値。ただし毎ターン `num_ctx` を変えるとモデル再ロードが走るためモデル単位で固定すること！）と整合させる。
2. **出力予約枠（Output Headroom）の確保**:
   - LLM のコンテキスト窓上限は `prompt_tokens + max_completion_tokens` の合計制約である。したがってページャが使える入力フレーム上限は `effectiveInputBudget = contextWindow - reservedOutputTokens`（例: 4k〜8k または窓の 10〜15% を出力用に確保）として High Watermark（例: 85%）を計算すると `400 context_length_exceeded` を確実に防げる。
3. **オフライン・未知モデル時のフォールバック**:
   - ネットワーク不通・モックドライバ・未知モデル時は例外で止めず、設定可能な保守的デフォルト窓（例: Local Ollama 未知モデル `32,768`、Cloud / OpenRouter 未知モデル `128,000`、テスト注入で任意の小さい窓例 `4,096` を指定可能）へフォールバックする構造にしておくと、Dynamic Frame Resizing の単体テスト・故障注入テストも容易になる。

---

## 3. トークン数見積もり（実測補正＋UTF-8 バイトヒューリスティック）

### 3.1 ローカルで確認した実行結果（文字数 vs UTF-8 バイト数 vs 実トークン数）
`qwen3.5:0.8b` の `/api/chat` が返す実測 `prompt_eval_count`（チャットテンプレート固定オーバーヘッド約 12〜15 tokens 込み）を 3 種のテキストで比較した結果：

| サンプル種別 | Unicode 文字数 (`runes`) | UTF-8 バイト数 (`utf8Bytes`) | 実測 `prompt_eval_count` | 実効 `utf8Bytes / token` |
| --- | ---: | ---: | ---: | ---: |
| 英語 Dart コード | `1,448` | `1,448` | `387` | `3.74` |
| 日本語設計ドキュメント | `672` | `1,376` | `395` | `3.48`（文字数比では **`1.70 chars/token`！**） |
| JSON ツール出力（SHA-256 hex・行番号含む） | `875` | `875` | `360` | **`2.43`** |

### 3.2 判断・経験則（過小評価によるコンテキスト溢れを防ぐ推定式）
1. **文字数 `chars / 4` は日本語と JSON/Hex で危険な過小評価になる**:
   - 日本語（`672 chars` → `395 tokens`）で `chars / 4 = 168` と見積もると実態の半分以下になり、High Watermark が発動する前にコンテキスト上限を突破する。
   - 一方、**UTF-8 バイト長 (`utf8.encode(text).length`)** を使うと、英語（`3.74 B/tok`）と日本語（`3.48 B/tok`）がほぼ同じ比率に揃う。JSON 記号や 16 進ハッシュが多いツール出力（`2.43 B/tok`）まで安全側にカバーする単体推定式としては **`ceil(utf8Bytes / 3.0) + messageOverhead`（1 メッセージあたり `+6 tokens`、Tool Schema 1 個あたり JSON 文字列の `ceil(utf8Bytes / 3.0)`）** が計算コスト O(N)・外部トークナイザ辞書不要で安定する。
2. **直近 `LlmUsageTelemetry.promptTokens` による実測アンカー補正**:
   - Stage 1 で既に全 3 プロバイダから毎ステップ正確な `usage.promptTokens` が返却されている（`packages/agent_kernel/lib/src/llm_driver.dart`）。
   - したがって「直近の LLM 呼び出し完了時点の常駐ページ集合の実測トークン合計 = `lastActualPromptTokens`」をアンカーとして記録し、**次の LLM 呼び出し前には「アンカー以降に Segment 1 / Segment 2 へ追加された新規ページの推定トークン数 − ページアウトで減った推定トークン数」を加減算するハイブリッド方式**（モデル切替時や初回ターンのみ純粋な UTF-8 バイト推定を使用）を採れば、長大なセッションでも累積推定誤差がゼロにリセットされ続ける。

---

## 4. `jj 0.46.0` における Clean Page の鮮度（`[STALE]`）判定と再展開

### 4.1 ローカルで確認した実行結果（隔離 `jj` リポジトリでの 3 ケース検証）
`.planworks/pt01_smoke/q2_jj_stale_repo/` にて、`a.dart` と `b.dart` を持つ `jj` リポジトリを作成し、`a.dart` 読取時の `(change_id, commit_id, sha256)` に対する状態変化を実測した（すべて `exit=0`）：

| ケース | 操作内容 | `--ignore-working-copy` での `@` `commit_id` 一致 | ホスト上の `a.dart` 実ファイル `sha256` 一致 | 観測された意味 |
| --- | --- | :---: | :---: | --- |
| **Case 1: 未編集** | 何も変更せず再確認 | `true` | `true` | Fresh（最新）。 |
| **Case 2a: 未スナップショット編集** | 外部ツールや人間がホスト上で `a.dart` を直接書き換え、まだ `jj` スナップショットが走っていない瞬間 | **`true`（変化しない！）** | **`false`（即検知！）** | `--ignore-working-copy` はスナップショットを走らせないため、`commit_id` 単独では「未スナップショットの外部直接編集」を見落とす。 |
| **Case 2b: スナップショット済み編集** | `HostFsDriver` / `Win32JobExecDriver` 経由の編集後（`syncWorkingCopySnapshot` 実行済み） | `false`（`change_id` は同一のまま `commit_id` が更新） | `false` | `commit_id` と `sha256` の両方で `STALE` 検知可能。さらに `jj file show -r <old_commit_id> --ignore-working-copy a.dart` で読取当時の旧内容（`"int a = 1;"`）も無破壊復元できた。 |
| **Case 3: 別ファイルのみ編集** | `a.dart` は元の内容のまま、**無関係な `b.dart` だけを編集**してスナップショット | **`false`（リビジョン全体の `commit_id` は変わる！）** | **`true`（`a.dart` 自体は不変！）** | `@` の `commit_id` 不一致だけで全ファイル Clean Page を一律 `[STALE]` にすると、1 ファイル編集するたびに過去に読んだ未変更ファイル群まで一斉に `[STALE]` になる（偽陽性）。 |

### 4.2 判断・経験則（Clean Page 種別ごとの正確な `[STALE]` 判定方式）
1. **ファイル読取 Clean Page（`sys_read_lines` 由来）**:
   - Stage 1 の `sys_read_lines` は既に読取時点のファイル全体の `sha256` を返している。PTE（Page Table Entry）に `(virtualPath, startLine, endLine, readSha256, readChangeId, readCommitId)` を記録する。
   - 鮮度チェック時は、まず `@` の `commit_id` と対象ファイルの現在 `sha256`（高速化する場合は `(FileStat.modified, FileStat.size)` が不変ならハッシュ再計算省略）を照合する。**ファイルが存在しないか現在 `sha256 != readSha256` の場合のみ `[STALE]` とマーク**すれば、Case 2a（外部未スナップショット編集）も見逃さず、Case 3（別ファイル編集での誤 `STALE`）も防げる。
   - `sys_mem_pagein(pageId)` が呼ばれた際は、対象ファイルの最新行範囲（または指定に応じて最新内容＋更新有無メタ情報）を Segment 2（末尾一時領域）へ再展開する（Segment 1 のスタブ自体は書き換えないため、過去の Prefix キャッシュを壊さない！）。
2. **リポジトリ状態 Clean Page（`sys_jj_diff`, `sys_jj_status`, `sys_jj_log` 由来）**:
   - 単一ファイルではなくリビジョン全体のスナップショットに依存するため、PTE に記録した `readCommitId`（および `readOpId`）と、現在の `JjTxContext`（または `jj log --no-graph -r @ --ignore-working-copy -T "commit_id"`）の `commit_id` を比較し、変化していれば `[STALE]` とマークする。
   - **絶対守るべき Prefix 不変ルール**: Clean Page が後から `STALE` になった際、**Segment 1 内の過去メッセージ文字列自体を毎ターン `[Fresh]` → `[STALE]` へ書き換えてはならない**（書き換えると編集のたびに過去位置の Prefix キャッシュが割れる）。Segment 1 内の退避スタブ文面は退避時点で不変とし、**各 Clean Page の現在ステータス（`resident` / `evicted(fresh)` / `evicted(STALE)`）の一覧は Segment 2（末尾の Page Directory Summary）に動的出力する** ことで、Prefix キャッシュ 100% 維持とリアルタイム `[STALE]` 通知を両立できる。

---

## 5. 未確認事項と再確認条件
- **未確認事項**: 40 ターン超の実 LLM 連続対話における High Watermark (例: 85%) → Low Watermark (例: 55%) バッチ退避後のプロバイダ別 `cached_tokens` 回復曲線（退避直後の 1 ターンのみ Segment 1 再構築が走り、次のターンから再び高キャッシュヒット率へ復帰する実機挙動）は、実装工程の統合・E2 検証で確認する対象である。
- **再確認トリガー**: Dart SDK のメジャー/マイナー更新時、または Ollama サーバーのバージョン更新（`/api/ps` や `/api/show` の JSON フィールド変更時）に再確認する。
