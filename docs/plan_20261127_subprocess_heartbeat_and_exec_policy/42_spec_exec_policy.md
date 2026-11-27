# 42_spec_exec_policy.md — `.agent_os/exec_policy.json`・`SysExecClassifier`・`Win32JobExecDriver`・プロンプト結線 詳細設計

関連文書:
- 全体仕様・優先順位契約: [40_specification.md](./40_specification.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)（`REQ-04`, `REQ-05`, `REQ-06`）
- サブプロセス Heartbeat・`sys_wait` 詳細: [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md)

---

## 1. `.agent_os/exec_policy.json` スキーマ・ローダ・Fail-Closed バリデーション

D-506: `.agent_os/exec_policy.json` スキーマ・探索優先順位・Fail-Closed バリデーション・VFS 保護（[REQ-04]）

`packages/agent_drivers/lib/src/exec/exec_policy_config.dart` を新設し、`packages/agent_drivers/lib/agent_drivers.dart` からエクスポートする。

### 1.1 JSON スキーマ定義（[30_requirement.md](./30_requirement.md) §4 引き継ぎ事項 1）

```json
{
  "allow": [
    {
      "command": "v",
      "allowedSubcommands": ["test", "check-md", "fmt"],
      "maxTimeoutMs": 180000
    },
    {
      "command": "mise",
      "allowedArgPrefixes": [
        ["exec", "--"],
        ["run"]
      ],
      "maxTimeoutMs": 300000
    },
    {
      "command": "cargo",
      "maxTimeoutMs": 300000
    }
  ]
}
```

| フィールド | 型 | 必須/任意 | 既定値・制約 |
| :--- | :--- | :--- | :--- |
| `allow` | `List<Object>` | 任意 | 省略時は `[]`（追加許可なし）。ルートに `allow` 以外の未知キーが存在する場合は構造化警告を記録して無視する。 |
| `allow[i].command` | `String` | **必須** | パス区切り（`/`, `\`）・ドライブレター（`:`）・空白・シェルメタ文字を含まない実行ファイル名。末尾の `.exe` / `.cmd` / `.bat` / `.ps1` を除去した小文字ベース名（`normalizedCommand`）へ正規化して保持する。 |
| `allow[i].allowedSubcommands` | `List<String>` | 任意 | 単一トークンの第 1 引数制限の糖衣構文（例: `["test", "fmt"]` は `[["test"], ["fmt"]]` と等価）。指定する場合は非空配列かつ各要素が非空文字列・シェルメタ文字なしであること。 |
| `allow[i].allowedArgPrefixes` | `List<List<String>>` | 任意 | 複数トークンの先頭引数プレフィックス制限（例: `[["exec", "--"], ["run", "build"]]`）。指定する場合は非空配列かつ各内側配列も非空・各要素が非空文字列・シェルメタ文字なしであること。 |
| `allow[i].maxTimeoutMs` | `int` | 任意 | 当該ルールの自動許可タイムアウト上限（ミリ秒）。省略時既定 **`120000`**（2 分）、許容範囲 **`100..600000`**（`Win32JobExecDriver.minTimeoutMs..Win32JobExecDriver.maxTimeoutMs`）。 |

- **引数プレフィックス合成規則**:
  - `allowedSubcommands` と `allowedArgPrefixes` の**両方とも省略（`null`）**された場合：`argPrefixes = null`（任意の安全な引数リスト `0..N` 個を許容）。
  - いずれか一方または両方が指定された場合：単一の重複排除リスト `List<List<String>> argPrefixes` に統合し、呼び出し時の正規化済み `args` がいずれか 1 つのプレフィックスで始まる場合のみ合致とする。
- **`mise` 等の扱い（`B-02` 合意厳守）**:
  - 特定ツール専用の信頼フラグや専用 VFS 書き込みガードは一切設けず、上記汎用スキーマのみで表現する。

### 1.2 ローダ探索優先順位と Fail-Closed バリデーション規則

`ExecPolicyConfigLoader` は `ModelsConfigLoader`（`packages/agent_drivers/lib/src/llm/models_config.dart`）と同じ構造で実装する：

1. **探索優先順位**:
   - 優先 1: `<sessionCwd>/.agent_os/exec_policy.json`（`sessionCwd` が非空かつファイルが存在する場合）
   - 優先 2: `<Directory.current>/.agent_os/exec_policy.json`（優先 1 が存在しない場合；テスト容易性のためコンストラクタで `String? currentDirectoryPath` を受け取れるようにする）
   - 不在時: `ExecPolicyLoadResult(config: ExecPolicyConfig.defaults(), sourcePath: null, warnings: const [])`。
2. **Fail-Closed エラー処理（意図しない広範許可の完全防止）**:
   - ファイル読込失敗・JSON 構文エラー・ルートが `Map` でない・`"allow"` が `List` でない場合：例外を送出せず `warnings` に理由を記録し、`ExecPolicyConfig.defaults()`（`allow: []`）を返す（優先 1 のファイルが壊れている場合に優先 2 へ暗黙フォールバックしてはならない）。
   - ルール要素 `allow[i]` が以下の**いずれか 1 つでも違反**する場合は、不正フィールドだけ無視して無制限ルールにするのではなく、**その `allow[i]` ルール全体をスキップ（無効化）** して `warnings` に記録する（他方の正常な `allow[j]` ルールは有効のまま保持する）：
     1. `allow[i]` が JSON オブジェクトでない、または定義済み 4 キー（`command`, `allowedSubcommands`, `allowedArgPrefixes`, `maxTimeoutMs`）以外の**未知キー**を含む（`"subcommands"` 等のタイポによる無制限許可事故を防ぐ）。
     2. `command` が欠落・非文字列・空文字列・空白含有・パス区切り（`/`, `\`）含有・ドライブレター（`:`）含有・シェルメタ文字（`SysExecCommandNormalizer.containsShellMetacharacters`）含有。
     3. 正規化ベース名 `normalizedCommand` が以下の禁止コマンド集合に含まれる：
        - **シェル実行ファイル（10 種）**: `cmd`, `powershell`, `pwsh`, `sh`, `bash`, `wsl`, `zsh`, `fish`, `ash`, `dash`
        - **生 VCS コマンド（2 種）**: `git`, `jj`
        - **直接ネットワーク取得コマンド（6 種）**: `curl`, `wget`, `invoke-webrequest`, `iwr`, `invoke-restmethod`, `irm`
     4. `allowedSubcommands` が非 `List`、空配列 `[]`、または要素が非文字列・空文字・シェルメタ文字含有。
     5. `allowedArgPrefixes` が非 `List`、空配列 `[]`、内側要素が非 `List`・空配列 `[]`、またはトークンが非文字列・空文字・シェルメタ文字含有。
     6. `maxTimeoutMs` が非 `int`、または `< 100` もしくは `> 600000`。

### 1.3 VFS 自己改ざん防止（`REQ-04.4`）

`VfsNamespace._protectedDirs`（`packages/agent_kernel/lib/src/vfs_namespace.dart`）には既に `'.agent_os'` が登録されているため、`/workspace/.agent_os/exec_policy.json` および相対 `.agent_os/exec_policy.json` への `sys_read_lines`, `sys_write_file`, `sys_edit_block`, `sys_glob`, `sys_grep` はすべて `EACCES: PROTECTED_INTERNAL_PATH` で拒否され、`sys_exec` の引数・`workingDir` 検査でも同様に拒否される。

---

## 2. `SysExecClassifier` のカスタムルール統合と共通ハードガード

D-507: `SysExecClassifier` のカスタム直接実行ルール評価と共通ハードガード強制（[REQ-04], [REQ-05]）

### 2.1 コンストラクタと `namespaceOverride` 伝播契約

```dart
class SysExecClassifier {
  SysExecClassifier({
    required this.namespace,
    ExecPolicyConfig? policy,
  }) : policy = policy ?? ExecPolicyConfig.defaults();

  final VfsNamespace namespace;
  final ExecPolicyConfig policy;
```

- **重要（Ring 3 / StackedTask `namespaceOverride` バグ防止）**:
  `classify(...)` 内で `namespaceOverride != null && !identical(namespaceOverride, namespace)` の場合に生成する委譲インスタンスには、必ず **`SysExecClassifier(namespace: namespaceOverride, policy: policy)`** と `policy` を引き継ぐ。これにより、隔離 `jj workspace` の `pcb.namespace` を使う Ring 3 `workspace_worker` / `conflict_resolver` でも `policy` が失われない。

### 2.2 `classify()` の判定フロー（[40_specification.md](./40_specification.md) §3.1 準拠）

1. **共通ハードガード検査（全コマンド共通、ビルトイン・カスタムより先行）**:
   - **メタ文字検査**: `command` または `args` のいずれかに `SysExecCommandNormalizer.containsShellMetacharacters`（`[&|;><`\r\n\x00%]|\$\(`）が真 → `RingDecision.askUser` (`SHELL_METACHARS_PRESENT`)。
   - **実行ファイル形式検査**: `trimmedExe.isEmpty` または `/`・`\`・`:` を含む → `RingDecision.askUser` (`EXECUTABLE_PATH_NOT_ALLOWLISTED`)。
   - **禁止実行ファイル検査**: `_normalizeExeBase(trimmedExe)`（末尾 `.exe`, `.cmd`, `.bat`, `.ps1` を小文字除去）が：
     - `_shellWrappers`（`cmd`, `powershell`, `pwsh`, `sh`, `bash`, `wsl`, `zsh`, `fish`, `ash`, `dash`）→ `RingDecision.askUser` (`SHELL_WRAPPER_NOT_ALLOWLISTED`)。
     - `_externalNetworkCommands`（`curl`, `wget`, `invoke-webrequest`, `iwr`, `invoke-restmethod`, `irm`）→ `RingDecision.askUser` (`EXTERNAL_NETWORK_COMMAND: ...`)。
     - `_blockedVcsCommands`（`git`, `jj`）→ `RingDecision.askUser` (`VCS_COMMAND_NOT_ALLOWLISTED`)（※通常は前段 Stage 3 の `AntiGitHabitGuardHook` で `HOOK_BLOCKED` となるが、Classifier 単体呼び出しでも多層防御する）。
   - **`workingDir` スコープ検査**: `effectiveWorkingDir`（省略時 `/workspace`）を `namespace.resolveVirtualPath(effectiveWorkingDir, allowRoot: true, checkProtected: true, checkSymlinks: true)` で解決し、`!wdRes.ok` → `RingDecision.askUser` (`WORKING_DIR_OUT_OF_SCOPE`)。解決成功時は正規化仮想パス `resolvedWorkingVirtualDir = wdRes.value!.virtualPath` を得る。
2. **ビルトイン `dart` 3 ルール判定**:
   - `normalizedBase == 'dart'` の場合、既存の `_classifyDartTest` / `_classifyDartAnalyze` / `_classifyDartFormat` を `timeoutMs <= maxAutoAllowTimeoutMs`（`120000`）条件とともに評価する（パス引数の相対基準は `resolvedWorkingVirtualDir` をサポート）。
   - これが `RingDecision.allow` を返した場合はそのまま採用する。`askUser` だった場合は、`.agent_os/exec_policy.json` に `dart` の追加ルール（例: `dart compile exe` 等）が定義されている可能性があるため次のステップ 3 を評価し、ステップ 3 でも合致しなければビルトイン側の元の `SysExecClassification`（理由コード維持）を返す。
3. **`.agent_os/exec_policy.json` ルール評価（`_classifyWithExecPolicy`）**:
   - `policy.rulesForCommand(normalizedBase)` が空なら `NON_ALLOWLISTED_EXECUTABLE` で `RingDecision.askUser`。
   - **全引数の共通安全性検査（`_validateCustomCommandArgs`）**:
     `args` 内の各要素 `arg` について `final trimmed = arg.trim();` を取り、以下のいずれか 1 つでも違反すれば `RingDecision.askUser` を返す：
     - **空・空白のみ拒否**: `trimmed.isEmpty` でないこと。
     - **`--` 後続ラッパー対象検査**: `--` トークンの直後に続くサブコマンド引数（例: `mise exec -- <subcmd>`）が存在する場合、その `<subcmd>` の `_normalizeExeBase` が `_shellWrappers` / `_externalNetworkCommands` / `_blockedVcsCommands` に該当しないこと（該当時は `WRAPPER_TARGET_NOT_ALLOWLISTED` で `askUser`；さらに生 `git`/`jj` は `AntiGitHabitGuardHook` でも `--` 直後トークンを検査し Stage 3 で `HOOK_BLOCKED` とする）。
     - **引数形態別の排他 3 分岐検査**:
       1. **`=` を含まない `-` 始まりフラグ引数**（`trimmed.startsWith('-') && !trimmed.contains('=')`、例: `-v`, `--release`, `--`, `-j4`）：
          短オプション連結パス（`-oC:\...`, `-I\\server\share`, `-C../outside`, `-I/outside`, `--out:C:\...`, `-f.agent_os/exec_policy.json`, `-f.env`, `-o/workspace/out.exe` 等）によるハードガード迂回および `resolveHostCommandArg` 変換漏れを防ぐため、`trimmed` に `/`・`\`・`:`・`'..'`、および保護名（小文字化した文字列における `.jj`, `.git`, `.agent_os`, `.env`）を**一切含まないこと**を必須とする（パスを渡す場合は分離引数 `["-o", "/workspace/out.exe"]` または `"--out=/workspace/out.exe"` 形式のみ即時許可とし、連結形式は `RingDecision.askUser` へ落とす）。
       2. **`=` を含む `-` 始まりオプション引数**（`trimmed.startsWith('-') && trimmed.contains('=')`、最初の `=` で `<flag>=<value>` に分割）：
          - 左辺 `<flag>` が `'-'` のみでなく、かつ上記 1 と同じく `/`・`\`・`:`・`'..'` および保護名（`.jj`, `.git`, `.agent_os`, `.env`）を含まないこと。
          - 右辺 `<value>`（`trim()` 後）が非空であり、下記「対象トークン共通のパス・値安全性検査」を満たすこと。
       3. **`-` で始まらない通常引数トークン**（`!trimmed.startsWith('-')`）：
          `trimmed` が下記「対象トークン共通のパス・値安全性検査」を満たすこと。
     - **対象トークン共通のパス・値安全性検査**（上記 2 の `<value>` および 3 の `trimmed` を `token` とする）：
       - URL スキーム（`^[a-zA-Z][a-zA-Z0-9+.-]*://`）、ドライブレター（`^[a-zA-Z]:` または `:` 含有）、UNC パス（`\\`, `//`）を含まないこと。
       - `final forward = token.replaceAll('\\', '/');` の `/` 分割セグメントに `'..'` または保護セグメント（`VfsNamespace.isProtectedSegment`: `.jj`, `.git`, `.agent_os`, `.env`, `.env.*`）を含まないこと。
       - **仮想パス vs 相対指定の排他分岐（`if / else`）**:
         - **`if (forward.startsWith('/'))`（`/` 始まり仮想パス指定）**: `forward == '/workspace' || forward.startsWith('/workspace/')` であり、かつ `namespace.resolveVirtualPath(forward, allowRoot: true, checkProtected: true, checkSymlinks: true).ok` が真であること（`resolvedWorkingVirtualDir` とは二重結合しない）。
         - **`else`（`/` で始まらない相対指定・通常トークン）**: `resolvedWorkingVirtualDir` 基準の仮想パス（`resolvedWorkingVirtualDir == '/workspace' ? '/workspace/$forward' : '$resolvedWorkingVirtualDir/$forward'`）として `namespace.resolveVirtualPath(..., allowRoot: true, checkProtected: true, checkSymlinks: true).ok`（`allowedWorkspaceSubpaths` 検査・シンボリックリンク実体境界検査・保護パス検査を含む）が真であること。
   - **ルール照合とタイムアウト検査**:
     `matchingRules`（`rule.matchesArgs(args)` が真のルール群）を抽出する：
     - 0 件なら `NON_ALLOWLISTED_SUBCOMMAND` で `RingDecision.askUser`。
     - 1 件以上合致し、そのうち `timeoutMs <= rule.maxTimeoutMs` を満たすルールが 1 件以上あれば **`SysExecClassification(decision: RingDecision.allow, reason: 'ALLOWLISTED_BY_EXEC_POLICY')`** を返す。
     - プレフィックスは合致したが全合致ルールで `timeoutMs > rule.maxTimeoutMs` だった場合は `TIMEOUT_EXCEEDS_AUTO_ALLOW_LIMIT` で `RingDecision.askUser` を返す。

---

## 3. `Win32JobExecDriver` のタイムアウト整合・仮想パス解決・ネイティブ実行境界

D-508: `Win32JobExecDriver` のタイムアウト上限整合・`/workspace/...` 仮想パス引数解決・ネイティブ実行境界（[REQ-04]〜[REQ-06]）

### 3.1 `Win32JobExecDriver.maxTimeoutMs` の拡張（`OM-03` 整合）

- `packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart` の `maxTimeoutMs` を `300000` から **`600000`（10 分）** に引き上げる（`defaultTimeoutMs = 60000` および `minTimeoutMs = 100` は維持）。
- これにより、`SpawnSpec.maxAllowedHeartbeatTimeoutMs = 600000` および `.agent_os/exec_policy.json` の `maxTimeoutMs: 600000` と上限が一致し、単発で最大 10 分かかるネイティブビルド（C++/Rust/V AOT ビルド等）を `EXEC_TIMEOUT` させずに実行可能とする。

### 3.2 `/workspace/...` 仮想パス引数のホスト相対パス解決（[30_requirement.md](./30_requirement.md) §4 引き継ぎ事項 4）

1. `SysExecClassifier.resolveHostCommandArg(VfsNamespace namespace, String hostWorkingDir, String rawArg)` を拡張する：
   - **単独仮想パス引数**: `rawArg` が `/workspace` または `/workspace/...` の場合、`namespace.resolveVirtualPath(forward, allowRoot: true, checkProtected: true, checkSymlinks: true)` で解決し、`hostWorkingDir` からの相対パス（同一ディレクトリなら `'.'`、それ以外は `/` 区切り相対パス）へ変換する（従来通り）。
   - **オプション値仮想パス引数（新規対応）**: `rawArg` が `-` で始まり `=` を含む場合（例: `--out=/workspace/bin/app.exe`, `-o=/workspace/out`）、最初の `=` で分割し、右辺が `/workspace` または `/workspace/...` であれば同様に `hostWorkingDir` からの相対パスへ変換して `'<prefix>=<resolvedRel>'` を返す。
2. `Win32JobExecDriver._buildSpawnPlan` において、従来 `exeBase == 'dart'` に限定していた `resolveHostCommandArg` 適用を、**すべての直接実行コマンド（`!normalized.hadShellMeta && !_shellExecutables.contains(exeBase)`）** に適用する。これにより、`workspace_worker` が隔離ワークスペース（`.agent_os/ws/<pid>`）内で `v test /workspace/src/foo_test.v` を呼んだ際、Windows 上の `v.exe` に正しい相対パス `src/foo_test.v`（`workingDirectory: <allocatedWsRoot>`）が渡される。

### 3.3 Windows 実行ファイル解決境界

- `Win32JobExecDriver.execute` は引き続き `Process.start(spawnPlan.executable, spawnPlan.arguments, workingDirectory: hostWorkingDir, environment: sanitizedEnv, includeParentEnvironment: false, runInShell: false)` を厳守する。
- Windows の `CreateProcessW`（`runInShell: false`）は `PATH` 上のネイティブ PE 実行ファイル（`<command>.exe`、例: `dart.exe`, `v.exe`, `mise.exe`, `cargo.exe`）をシェルを介さずに直接起動して Win32 Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`）へ即座にバインドする。`.cmd` / `.bat` バッチファイルを暗黙的に `cmd.exe /c` へフォールバックさせる処理は、シェル引数展開インジェクションを防ぐため**意図的に行わない**（存在しないコマンドは `ProcessException` を捕捉して構造化エラー `ENOENT: PROCESS_START_FAILED` を返す既存契約を維持）。

---

## 4. `AgentPrompts` および `SyscallToolSchema` への決定的反映

D-509: `AgentPrompts` および `SyscallToolSchema`（`sys_exec` / `sys_spawn` / `sys_wait`）への決定的反映と純粋性維持（[REQ-03], [REQ-05], [REQ-06]）

### 4.1 整形メソッド `ExecPolicyConfig.toPromptRuleSummaries()`（`agent_drivers`）

[30_requirement.md](./30_requirement.md) §4 引き継ぎ事項 5 に基づき、`agent_prompts.dart` の `dart:io` / `agent_drivers` 非依存を守るため、`ExecPolicyConfig` 側で決定的な 1 行サマリ配列 `List<String>` を生成する：

- `policy.allow` が空なら `const <String>[]` を返す。
- 各 `ExecAllowRule` を記述順で以下の決定的フォーマットへ変換する：
  - `argPrefixes == null`: ``'`<command>` (any safe workspace args; maxTimeoutMs: <maxTimeoutMs>)'``
  - `argPrefixes != null`: ``'`<command>` (allowed prefixes: `<p1>`, `<p2>`; maxTimeoutMs: <maxTimeoutMs>)'``（各 `<pi>` はトークンを空白結合）

### 4.2 `AgentPrompts` の純粋 API シグネチャ（`packages/agent_runtime/lib/src/prompts/agent_prompts.dart`）

1. **既存定数の維持と Stage 2/3 文言の更新**:
   - `leadStep1Instruction` は一切変更しない（Stage 1 互換維持）。
   - `leadStage2Instruction`（およびそれを参照する `leadStage3Instruction`）の `sys_spawn` / `sys_wait` 説明を、拡張上限（最大 60 分 / 128 ステップ / Heartbeat 5 分）および非破壊 `sys_wait`（タイムアウト時も子は継続し `timedOut: true` と `running` の Heartbeat スナップショットが返るため再 `sys_wait` で待機継続または異常ループ時に `sys_kill` する旨）へ更新する。
   - `KernelBootstrap.defaultStep1Instruction` / `defaultStage2Instruction` / `defaultStage3Instruction` の `const` エイリアスはそのまま維持する。
2. **`AgentPrompts.buildLeadInstruction`（新規純粋メソッド）**:
   ```dart
   static String buildLeadInstruction({
     required int stage, // 1, 2, or 3
     List<String> additionalExecRuleSummaries = const <String>[],
   })
   ```
   - `additionalExecRuleSummaries` が空のときは、`stage` に応じて `leadStep1Instruction` / `leadStage2Instruction` / `leadStage3Instruction` の定数参照をそのまま返す（既存と完全一致、KV プレフィックスキャッシュ不変）。
   - 非空のときは、ベース命令の末尾に以下の決定的ブロックを付与する：
     ```text

     Additional `sys_exec` direct commands auto-allowed by `.agent_os/exec_policy.json` (shell metacharacters, shell wrappers, raw `git`/`jj`, and paths outside `/workspace` remain blocked):
     - <summary 1>
     - <summary 2>
     ```
3. **`AgentPrompts.buildChildInstruction` の拡張（後方互換シグネチャ）**:
   ```dart
   static String buildChildInstruction({
     required ProcessProfileId profile,
     List<String>? allowedSubpaths,
     List<String> additionalExecRuleSummaries = const <String>[],
   })
   ```
   - `additionalExecRuleSummaries` 省略時（または空配列時）は、全 4 プロファイルで既存の文字列と **1 バイトも違わず一致** する。
   - `additionalExecRuleSummaries` が非空のとき：
     - **`workspaceWorker` / `conflictResolver`**: ベース命令の末尾に上記と同一形式の `Additional sys_exec direct commands auto-allowed by .agent_os/exec_policy.json:` ブロックを付与する。
     - **`explorer` / `webResearcher`**: `CapRight.exec` を持たず `sys_exec` が実行不可であるため、**`additionalExecRuleSummaries` を無視して一切付与しない**。

### 4.3 `SyscallToolSchema` 説明文の更新

1. **`Win32JobExecDriver.toolSchemas({ExecPolicyConfig? policy})`**（`win32_job_exec_driver.dart`）:
   - `timeoutMs` プロパティ説明を `'Timeout in milliseconds (100..600000, default 60000).'` に更新する。
   - `policy == null || policy.allow.isEmpty` の場合は既存の `sys_exec` `description` を維持し、非空の場合は `Additional auto-allowed direct commands (.agent_os/exec_policy.json): ...` を `description` に決定的に連結する。
2. **`buildProcessToolSchemas()`**（`process_syscalls.dart`）:
   - `sys_spawn`: `maxWallTimeMs`（`default 600000, max 3600000`）、`maxSteps`（`default 32, max 128`）、新規 `heartbeatTimeoutMs`（`default 300000, max 600000; paused during SIGSTOP`）、および `workspace_worker` プロファイル説明（`allowlisted sys_exec commands`）を反映する。
   - `sys_wait`: タイムアウト時に未完了の子を kill せず `children`・`timedOut`・`running`（Heartbeat 進捗スナップショット）を返す非破壊仕様と `timeoutMs`（`default 120000, max 600000`）を明記する。

---

## 5. `KernelBootstrap`・`IsolateWorkerHost`・`AcpServer` 統合結線と既存テスト影響

D-510: `KernelBootstrap`・`IsolateWorkerHost`・`AcpServer` セッション結線と既存テスト互換維持（[REQ-03], [REQ-05], [REQ-06]）

### 5.1 `KernelBootstrap` と `IsolateWorkerHost` の結線順序（`kernel_bootstrap.dart`, `isolate_worker_host.dart`）

`KernelBootstrap.create` では `allToolSchemas` と `pinnedSystem` が `Win32JobExecDriver` 生成より前に構築されるため、以下の順序で結線する：

1. `KernelBootstrapConfig` に任意パラメータ `final ExecPolicyConfig? execPolicy;` および `final void Function(String message)? onExecPolicyWarning;` を追加する。
2. `AuditLogger` 初期化直後（`effectiveEnvLoader` 構築箇所と同じ段階）で `effectiveExecPolicy` を確定する：
   - `config.execPolicy != null` ならそれを使用。
   - `null` なら `ExecPolicyConfigLoader(sessionCwd: namespace.workspaceHostRoot).load()` を呼び出し、`warnings` の各要素を `effectiveRedactor.redactString` した上で `config.onExecPolicyWarning ?? ((msg) => stderr.writeln('[exec_policy] $msg'))` へ出力する（※`stdout` は絶対に使用しない）。
3. `final execRuleSummaries = effectiveExecPolicy.toPromptRuleSummaries();` を計算する。
4. `allToolSchemas` 構築時に `...Win32JobExecDriver.toolSchemas(policy: effectiveExecPolicy)` を渡す（これにより `LeadAgent` と Ring 3 `workspace_worker` / `conflict_resolver` の双方に更新後の `sys_exec` スキーマが配信され、`explorer` / `web_researcher` からは `filterToolSchemasForPcb` により除外される）。
5. `pinnedSystem` 構築時、`config.systemInstruction == null` であれば `AgentPrompts.buildLeadInstruction(stage: isStage3Team ? 3 : (isStage2Multiprocess ? 2 : 1), additionalExecRuleSummaries: execRuleSummaries)` を使用する。
6. `Win32JobExecDriver` 生成時に `classifier: SysExecClassifier(namespace: namespace, policy: effectiveExecPolicy)` を渡す（`Win32JobExecDriver.forWorkspace` にも任意 `ExecPolicyConfig? execPolicy` を追加）。
7. `IsolateWorkerHost` コンストラクタに `this.additionalExecRuleSummaries = const <String>[]` を追加し、`_launchAttempt` 内の `AgentPrompts.buildChildInstruction` 呼び出し（2 箇所）へ渡す。
8. `KernelBootstrap` に `final ExecPolicyConfig execPolicy;` フィールドを公開する。

### 5.2 `AcpServer` への結線（`packages/agent_acp/lib/src/acp_server.dart`）

- `AcpServerConfig` に任意 DI 用 `final ExecPolicyConfig? execPolicy;` を追加する。
- `_onSessionNew` 内の `KernelBootstrapConfig` 生成時に `execPolicy: config.execPolicy` を渡す（未指定時は `KernelBootstrap.create` が `normalizedCwd` 基準で `<normalizedCwd>/.agent_os/exec_policy.json` を自動ロードし、警告を `stderr` へ出力する）。

### 5.3 既存テストへの影響範囲と互換維持方針

| 既存テストファイル | 影響の有無と対応方針 |
| :--- | :--- |
| `packages/agent_runtime/test/agent_prompts_test.dart` | `leadStage2Instruction` / `leadStage3Instruction` の `sys_spawn`・`sys_wait` 説明文更新に伴い、同テスト内の `expectedStage2`（および `$expectedStage2` を参照する `expectedStage3`）を新文言へ更新する。`leadStep1Instruction` および `buildChildInstruction`（追加ルールなし既定呼び出し）は既存アサーションのまま変更なしでパスさせ、追加で `additionalExecRuleSummaries` 指定時のテストを追記する。 |
| `packages/agent_drivers/test/win32_job_exec_test.dart` | ビルトイン `dart` の `maxAutoAllowTimeoutMs = 120000` および既存の拒否理由コードを維持するため、既存テストは変更なしで全件パスする。 |
| `packages/agent_runtime/test/capability_tty_and_quota_test.dart`, `signals_and_supervisor_test.dart`, `isolate_multiprocess_ipc_test.dart`, `workspace_worker_and_conflict_resolver_test.dart` | 既存テストはすべて子完了を待つ `sys_wait` で `(waitRes.value!['children'] as List)` を参照しており、`children` 形式を維持するため破壊的影響なし。 |
| `packages/agent_acp/test/stage3_architecture_and_purity_test.dart` | E3-1（`agent_kernel` 純粋性）、E3-2（子 Isolate の `JjDriver` 非保持）、E3-3（`stdout` 純粋性）、E3-4（Kanban エンジン非依存）、E3-5（3 バイナリ緩和フラグなし）のすべてを設計段階から満たしており、無修正でパスする。 |

---

## 6. 確認手順（REQ-04 〜 REQ-06 向け）

1. **`REQ-04` ローダ・ハードガード・VFS 保護テスト（`E1` / `E3`）**:
   - `packages/agent_drivers/test/exec_policy_and_classifier_test.dart`（新規または既存拡張）にて：
     - `<sessionCwd>/.agent_os/exec_policy.json` と `<currentDirectoryPath>/.agent_os/exec_policy.json` の両方がある場合に `sessionCwd` 側が優先されること、`sessionCwd` 側不在時に `currentDirectoryPath` 側が読まれること、両方不在時に `allow: []` となること。
     - JSON 構文不正、ルート非 Map、未知キー付きルール（例: `"subcommands"` タイポ）、空配列 `allowedSubcommands: []`、範囲外 `maxTimeoutMs` に対してクラッシュせず警告が記録され、該当ルールが無効化（fail-closed）されること。
     - `exec_policy.json` にシェル 10 種（`cmd`, `powershell`, `pwsh`, `sh`, `bash`, `wsl`, `zsh`, `fish`, `ash`, `dash`、`.exe`/`.bat` 付き含む）、生 `git`/`jj`、ネットワークコマンド 6 種（`curl`, `wget`, `Invoke-WebRequest`, `iwr`, `Invoke-RestMethod`, `irm`）、パス区切り付きコマンド（`C:\tools\v.exe`, `./script.sh`）を記載しても警告付きで無効化され、`SysExecClassifier` でも決して `RingDecision.allow` にならないこと。
     - 有効なカスタムルール（例: `v` のサブコマンド制限、`mise` の `["exec", "--"]` プレフィックス制限、`where` 等の Windows 標準ネイティブ `.exe`、および `/workspace/...` や `--out=/workspace/...` 仮想パス引数・複数 `allowedWorkspaceSubpaths` 下での別サブパス `/workspace/...` 引数指定）が `RingDecision.allow` になる一方、空白のみの引数、`;` / `&&` / `|` / `$(...)` / `%VAR%` 等のシェルメタ文字、`mise exec -- powershell ...`、`mise exec -- git status`、`../outside`、`C:\Windows`、`/workspace/.agent_os/exec_policy.json`、`.env`、`-oC:\Users\Public\out.exe`・`-C../outside`・`-f.env`・`-f.agent_os/exec_policy.json`・`-o/workspace/out.exe` 等の `=` なし短オプション連結パス、`allowedWorkspaceSubpaths` 外パス、`maxTimeoutMs` 超過では `RingDecision.askUser`（生 `git`/`jj` は `HOOK_BLOCKED`）になること。
     - `HostFsDriver`（`sys_read_lines`, `sys_write_file`, `sys_edit_block`, `sys_glob`, `sys_grep`）から `/workspace/.agent_os/exec_policy.json` へのアクセスが `EACCES: PROTECTED_INTERNAL_PATH` で拒否されること。
2. **`REQ-05` Ring 3 / Ring 2 実機実行およびプロンプト・ツールスキーマ反映テスト（`E1` / `E2`）**:
   - `E1` 自動統合テスト（`packages/agent_runtime/test/` および `packages/agent_acp/test/`）：
     - `.agent_os/exec_policy.json` に Windows 標準の安全なネイティブ実行ファイル（例: `where` や `hostname`、または `dart` の追加サブコマンド等）を設定した隔離 Jujutsu リポジトリで `KernelBootstrap` および `AcpServer` を起動する。
     - (a) Ring 3 `workspace_worker` および `conflict_resolver` が、その許可コマンド（`/workspace/...` 仮想パス引数付きを含む）を `sys_exec` で呼び出した際、`TTY_MONOPOLY_DENIED` にならず承認ハンドラ呼び出し 0 回で自身の隔離 `jj workspace` 内で実行成功し、`sys_exit(0)` → `sys_wait` で結果回収できること。また Ring 2 `LeadAgent` でも承認要求 0 回で即時実行できること。
     - (b) `.agent_os/exec_policy.json` に未記載のコマンドは Ring 3 で `EPERM: TTY_MONOPOLY_DENIED`、Ring 2 で `ApprovalHandler` 呼び出し（`askUser`）となること。
     - (c) `explorer` および `web_researcher` では `.agent_os/exec_policy.json` 設定時も `sys_exec` ツールがスキーマに現れず、直接呼び出しでも `EPERM: CAPABILITY_DENIED` となること。
     - (d) `LeadAgent`・`WorkspaceWorker`・`ConflictResolver` の構築済みシステムプロンプト、および `sys_exec` / `sys_spawn` / `sys_wait` の `SyscallToolSchema.description` に、設定した許可コマンド情報および非破壊 `sys_wait`・Heartbeat 仕様が含まれ、`Explorer` / `WebResearcher` のプロンプトには `sys_exec` 追加許可ブロックが含まれないこと。
   - `E2` 実サブプロセス実行観測：
     - `.agent_os/exec_policy.json` を配置したテストリポジトリに対し、実 Isolate ワーカー（`IsolateChildWorkerBackend`）を用いた `workspace_worker` を `sys_spawn` し、設定済み直接実行コマンドの `sys_exec` 実行と `sys_wait` 完了回収が成功することを実観測する。
3. **`REQ-06` 全パッケージ回帰・純粋性・Windows 3 バイナリ AOT ビルド確認（`E1`）**:
   - [40_specification.md](./40_specification.md) §5.3 の通り、ワークスペース全体の `dart analyze`、全パッケージ `dart test`、および 3 つの `.exe`（`agent_os_daemon.exe`, `acp_cli_client.exe`, `acp_kanban_app.exe`）の `dart compile exe` 成功（および `stage3_architecture_and_purity_test.dart` の E1/E3 検査パス）を確認する。
