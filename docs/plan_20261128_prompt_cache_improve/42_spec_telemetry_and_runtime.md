# 詳細仕様書 — テレメトリ合算・Runtime Prefix 維持・子プロセス Session ID（42_spec_telemetry_and_runtime.md）

- **親仕様書**: [40_specification.md](40_specification.md)
- **対応 REQ**: `REQ-01`（P0）, `REQ-06`（P2）
- **収録設計項目**: `[D-601]`, `[D-606]`

---

D-601: `LeadAgent.runTurn` キャッシュテレメトリ全ステップ合算

### 1.1 対象 REQ と現行の課題
- **対応 REQ**: `REQ-01`（[30_requirement.md](30_requirement.md)）
- **対象ファイル**: `packages/agent_runtime/lib/src/process_runner.dart`（L412〜419, L575〜597, L645〜655）
- **参照のみ（変更不要）**: `packages/agent_kernel/lib/src/llm_driver.dart`（`LlmUsageTelemetry.cacheHitRate`）
- **現行の問題**: `promptAgg` / `completionAgg` / `costAgg` はターン内全ステップで合算しているのに対し、`lastCachedTokens` / `lastCacheWriteTokens` は最終ステップの値で上書きしているため、$N$ ステップのターンでは `cacheHitRate = lastCachedTokens / sum(promptTokens)` となり実際の約 $1/N$ に過小報告される。

### 1.2 変更仕様
1. **集計ローカル変数の刷新**（`LeadAgent.runTurn` L412〜419）:
   - `int? lastCachedTokens;` / `int? lastCacheWriteTokens;` を廃止し、`costAgg` / `hasAnyCost` と対称な以下へ置き換える：
     ```dart
     var cachedAgg = 0;
     var hasAnyCached = false;
     var cacheWriteAgg = 0;
     var hasAnyCacheWrite = false;
     ```
2. **ステップ毎の合算ロジック**（L576〜597）:
   ```dart
   final cached = usageMap['cachedTokens'];
   if (cached is num) {
     cachedAgg += cached.toInt();
     hasAnyCached = true;
   }
   final cacheWrite = usageMap['cacheWriteTokens'];
   if (cacheWrite is num) {
     cacheWriteAgg += cacheWrite.toInt();
     hasAnyCacheWrite = true;
   }
   ```
3. **ターン終了時の `LlmUsageTelemetry` 構築**（L646〜654）:
   ```dart
   final telemetry = LlmUsageTelemetry(
     promptTokens: promptAgg,
     completionTokens: completionAgg,
     cachedTokens: hasAnyCached ? cachedAgg : null,
     cacheWriteTokens: hasAnyCacheWrite ? cacheWriteAgg : null,
     costMicroUsd: hasAnyCost ? costAgg : null,
     ttftMs: lastTtftMs,
     durationMs: durationAgg,
   );
   ```

### 1.3 境界条件と期待結果

| ケース | 各ステップ `(prompt, cached, cacheWrite)` | 期待 `cachedTokens` | 期待 `cacheWriteTokens` | 期待 `cacheHitRate` |
| --- | --- | :---: | :---: | :---: |
| 単一ステップ（非 `null`） | `[(1000, 800, 0)]` | `800` | `0` | `0.8` |
| 多ステップ（全て非 `null`） | `[(5000, 0, 4800), (6000, 4800, 0), (7000, 5800, 0)]` | `10600` | `4800` | `0.5889` (`10600/18000`) |
| 一部ステップが `null`（Gemini 暗黙キャッシュ等） | `[(5000, null, null), (6000, 4000, null), (7000, null, null)]` | `4000` | `null` | `0.2222` (`4000/18000`) |
| 全ステップが `null` | `[(1000, null, null), (1200, null, null)]` | `null` | `null` | `null` |
| `promptTokens == 0` かつ `cachedTokens == 0` | `[(0, 0, 0)]` | `0` | `0` | `null`（既存 `LlmUsageTelemetry.cacheHitRate` 契約） |

### 1.4 既存テストへの影響
- `packages/agent_runtime/test/lead_agent_loop_test.dart`（L155, L168）: 現行テストは Step 1 `cachedTokens: 0`、Step 2 `cachedTokens: 90` であり合算しても `90` で既存アサーションと互換。新規に「複数ステップ非ゼロ」「一部 `null`」「全 `null`」「`cacheWriteTokens` 合算」のユニットテストを追加する。
- `packages/agent_runtime/test/step1_1_integration_test.dart`: Turn 2 等の `usage?.cachedTokens` が合算値と一致することを検証する。

### 1.5 確認手順（`REQ-01` 対応）
- **E1**: `packages/agent_runtime/test/lead_agent_loop_test.dart` に上記 5 ケースの自動テストを追加し、`dart test` で `cachedTokens`・`cacheWriteTokens`・`cacheHitRate` が一致することを確認する。
- **E2**: 実 API（OpenRouter または OpenAI）で Tool Call を含む 2 ステップ以上のターンを実行し、`AgentTurnResult.usage`（および ACP `turnSummary.usage`）の `cachedTokens`・`cacheWriteTokens`・`cacheHitRate` が、同一ターンの `llm_io.jsonl` 全ステップ合算値と一致することを観測する。

---

D-606: `dynamicContextSummary` Prefix 維持コミット & `SubAgentWorker` 子固有 `sessionUuid` 導出・引き回し

### 2.1 対象 REQ とおまかせ採用解釈
- **対応 REQ**: `REQ-06`（[30_requirement.md](30_requirement.md)）
- **採用解釈（`90_status.md` 記録済み）**:
  1. Step 1 送信時と同じ `dynamicContextSummary + currentUserInput` を Segment 1 へコミットする（案 A）。
  2. `SubAgentWorker` は親 `sessionId` と子 `pid` から決定論的に導出した子固有 `sessionUuid` を全 ReAct ステップで引き回す（案 B）。

### 2.2 Part A: `LeadAgent.runTurn` の Step 1 コミット方式統一
- **対象ファイル**: `packages/agent_runtime/lib/src/process_runner.dart`（L604〜612）
- **現行の問題**:
  - Step 1 送信時、`EphemeralTailSegment.renderTailContent()`（`packages/agent_kernel/lib/src/context_memory.dart` L202〜219）は以下の順で非空要素を `'\n\n'` 結合する：
    1. `dynamicContextSummary?.trim()`
    2. `pageDirectorySummary?.trim()`
    3. `currentUserInput`
  - しかし Step 1 完了後（L606〜610）では `currentUserInput` のみを `pcb.memory.appendUserTurn(committedInput)` で Segment 1 にコミットし、`dynamicContextSummary = null` で消去するため、Step 2 で当該 `user` メッセージから `dynamicContextSummary` が剥がれて Prefix が破壊される。
- **重要な境界条件（`pageDirectorySummary` の混入防止）**:
  - `renderTailContent()` をそのまま呼んで Segment 1 にコミットしてはならない。なぜなら、`pageDirectorySummary` は `ContextPager` が各ステップ直前に動的に書き換える `[Context Page Directory]` であり、Segment 1 に固定化すると古いページ一覧が永続履歴に焼き付き、以降のステップで二重出力と Prefix 汚染を招くためである。
- **正確なコミット文字列構成仕様**:
  - 静的ヘルパまたはインライン処理として以下を適用する（`process_runner.dart` L605〜612）：
    ```dart
    if (!userTurnCommitted) {
      final dynSummary =
          pcb.memory.ephemeralSegment.dynamicContextSummary?.trim();
      final baseInput =
          pcb.memory.ephemeralSegment.currentUserInput ?? userInput;
      final committedInput =
          (dynSummary != null && dynSummary.isNotEmpty)
              ? (baseInput.isNotEmpty ? '$dynSummary\n\n$baseInput' : dynSummary)
              : baseInput;
      pcb.memory.appendUserTurn(committedInput);
      pcb.memory.ephemeralSegment.dynamicContextSummary = null;
      pcb.memory.ephemeralSegment.currentUserInput = null;
      userTurnCommitted = true;
    }
    ```
- **既存動作との整合確認**:
  1. **`dynamicContextSummary` が `null` または空白のみの場合**: `committedInput == baseInput` となり既存動作と 100% 一致。
  2. **`dynamicContextSummary` が非空かつ `pageDirectorySummary` が空の場合**: Step 1 送信時の `renderTailContent()` は `'$dynSummary\n\n$baseInput'` を出力し、Step 2 の Segment 1 の該当 `user` メッセージも `'$dynSummary\n\n$baseInput'` となり、**バイト単位で完全一致**する。
  3. **`pageDirectorySummary` が非空の場合**: `pageDirectorySummary` は Segment 1 へ混入せず Segment 2 に残留し、次ステップでも最新の `[Context Page Directory]` として末尾に描画される。
  4. **Step 1 実行前の `SIGCONT` 制約注入（L479〜497）**: `userTurnCommitted == false` の間に `currentUserInput` へ `AgentPrompts.formatSigcontConstraint(...)` が適用されるため、`baseInput` に制約が含まれた状態で Step 1 送信・Step 1 コミットが一致する。
  5. **Step 2 以降の 85% 予算警告（L518〜531）**: `if (userTurnCommitted && ...)` で実行されるため、Step 1 のコミット後のみ `ephemeralSegment.dynamicContextSummary` に一時注入され、Segment 1 へはコミットされない（既存契約維持）。

### 2.3 Part B: `SubAgentWorker` の子固有 `sessionUuid` 決定論的導出と引き回し
- **対象ファイル**:
  - `packages/agent_runtime/lib/src/sub_agent_worker.dart`
  - `packages/agent_runtime/lib/src/isolate_worker_host.dart`
- **導出関数仕様**:
  - `SubAgentWorker` に以下の静的メソッドを定義する：
    ```dart
    static String deriveChildSessionUuid({
      required String parentSessionId,
      required Pid pid,
    }) {
      final normalizedParent = parentSessionId.trim();
      final prefix = normalizedParent.isEmpty ? 'session' : normalizedParent;
      return '$prefix:child:$pid';
    }
    ```
  - **一意性と安定性**:
    - 親（`pid == 1`）の `sessionUuid`（または `sessionId`）は `:child:` サフィックスを持たないため、親子間で衝突しない。
    - 子プロセスの `pid` は `KernelProcessTable.allocateNextPid()` により単調増加で一意に割り当てられるため、並列起動される子プロセス間および Supervisor リトライ（新規 `pid`）間で衝突しない。
    - 同一子プロセスの Step 1..N で不変の値が引き回されるため、子の多ステップ ReAct で Sticky Routing が安定する。
- **インターフェース変更と両バックエンドでの一貫引き回し**:
  1. `SubAgentWorker` コンストラクタに任意フィールド `this.sessionUuid`（`final String? sessionUuid;`）を追加する（既存呼び出し元の後方互換性を維持）。
  2. `SubAgentWorker.run()` の `sys_llm_chat` 呼び出し（L99〜106）:
     ```dart
     final llmRes = await invoker.invoke(
       'sys_llm_chat',
       <String, dynamic>{
         'model': model,
         'turnIndex': step,
         if (sessionUuid != null && sessionUuid!.trim().isNotEmpty)
           'sessionUuid': sessionUuid!.trim(),
         'stream': false,
       },
     );
     ```
  3. **`IsolateChildWorkerBackend` 経路**（`runSubAgentIsolateWorker`, `sub_agent_worker.dart` L475〜483）:
     - `SubAgentWorker.deriveChildSessionUuid(parentSessionId: sessionId, pid: pid)` を算出し、`SubAgentWorker(..., sessionUuid: childSessionUuid)` へ渡す。
  4. **`GreenTaskChildWorkerBackend` 経路**（`GreenTaskChildWorkerBackend.spawn`, `sub_agent_worker.dart` L676〜684）:
     - `SubAgentWorker.deriveChildSessionUuid(parentSessionId: config.sessionId, pid: config.pid)` を算出し、`SubAgentWorker(..., sessionUuid: childSessionUuid)` へ渡す。
  5. **ホスト側防衛線**（`IsolateWorkerHost._executeChildSyscall`, `isolate_worker_host.dart` L1402 付近）:
     - `name == 'sys_llm_chat'` の際、`args['sessionUuid']` が `null` または空文字であれば、コピーした引数マップへ `SubAgentWorker.deriveChildSessionUuid(parentSessionId: child.sessionId, pid: child.pid)` を補完して `syscallGate.invoke` へ渡す。これにより、どの経路から起動された子プロセスでも `llm_router.dart` の親 `sessionId` フォールバックへ落ちないことを保証する。

### 2.4 失敗時・状態失効時の振る舞い
- Step 1 の `sys_llm_chat` が失敗した場合は `userTurnCommitted` が `false` のまま早期リターンするため、Segment 1 に不完全な `user` ターンはコミットされない（既存挙動維持）。
- 子プロセスが `EDQUOT` / `ECANCELLED` / タイムアウトで終了・リトライされた場合、新試行には新しい `pid` が割り当てられるため、自動的に新しい `sessionUuid`（`<sessionId>:child:<newPid>`）が生成され、古い試行のキャッシュセッションと混線しない。

### 2.5 確認手順（`REQ-06` 対応）
- **E1（`dynamicContextSummary` Prefix 一致）**:
  - `packages/agent_runtime/test/lead_agent_loop_test.dart` に、非空の `dynamicContextSummary` を渡した 2 ステップ以上（Tool Call あり）の ReAct テストを追加し、モック LLM ドライバが受信した Step 1 の該当 `user` メッセージ文字列と Step 2 の Segment 1 の該当 `user` メッセージ文字列が**完全一致**することを検証する。
  - 併せて、`pageDirectorySummary` が設定された状態で Step 1 を完了しても Segment 1 に `pageDirectorySummary` が混入しないこと、`dynamicContextSummary == null` の既存動作・85% 予算警告・SIGCONT 制約注入が維持されることを自動テストで確認する。
- **E1（`SubAgentWorker` `sessionUuid` 引き回し）**:
  - `packages/agent_runtime/test/isolate_multiprocess_ipc_test.dart` に、`GreenTaskChildWorkerBackend` および `IsolateChildWorkerBackend` の双方で 2 つの子プロセスを並列起動し、モック LLM ドライバが受信した `LlmChatRequest.sessionUuid` について、(a) 親の `sessionId` / `sessionUuid` と異なること、(b) 2 つの子プロセス間で異なること、(c) 同一子プロセスの複数ステップ間で一致すること、を自動検証する。
