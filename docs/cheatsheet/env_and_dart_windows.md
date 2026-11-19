# Windows 11 開発環境・Dart SDK 要件・Win32 Job Object FFI

- **確認日**: `2026-11-19`
- **対象環境**: Windows 11 Pro 64-bit (`10.0.26300`, Build `26300`) / PowerShell
- **対象技術**: Dart SDK (`^3.6.0` / `Google.DartSDK 3.13.7`), `dart:ffi`, `package:win32`, Win32 Job Object (`kernel32.dll`)

---

## 1. ローカルで確認した事実（マシン環境・ツール・環境変数）

`2026-11-19` 時点で開発マシン上を探索・実測した結果は以下の通り。

### 1.1 OS・導入済み CLI ツールチェーン

| 項目 | ローカル観測結果 | パス / 版・備考 |
| --- | --- | --- |
| OS | 稼働確認済み | `Microsoft Windows 11 Pro` (`10.0.26300`, 64-bit) |
| `jj` (Jujutsu) | 導入済み | `C:\Users\rero2\AppData\Local\Microsoft\WinGet\Links\jj.exe` (`jj 0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f`) |
| `git` | 導入済み | `C:\Program Files\Git\cmd\git.exe` (`git version 2.56.0.windows.4`) |
| `ollama` | 導入・稼働中 | `C:\Users\rero2\AppData\Local\Programs\Ollama\ollama.exe` (`0.40.16`, `http://localhost:11434` 応答確認済み) |
| `winget` | 導入済み | `C:\Users\rero2\AppData\Local\Microsoft\WindowsApps\winget.exe` |
| C コンパイラ (`gcc`) | 導入済み | `C:\msys64\ucrt64\bin\gcc.exe`（UCRT64 ヘッダ `<windows.h>` 利用可） |
| MSVC (`cl.exe`) | 未導入 | `vswhere.exe` は存在するがインストール済み Visual Studio / Build Tools 製品は 0 件 |
| **Dart SDK (`dart.exe`)** | **未導入** | `PATH`、レジストリ `Path`、`C:\tools`, `C:\src`, `Program Files`, `AppData`, `fvm`, `scoop`, `flutter`, `winget list` のいずれにも存在しないことを確認 |

### 1.2 環境変数の設定有無（真偽値のみ記録）

秘密情報の値は取得・保存せず、Process / User / Machine スコープにおける非空文字列の設定有無のみを確認した。

| 環境変数名 | Process | User | Machine | 備考 |
| --- | :---: | :---: | :---: | --- |
| `OPENROUTER_API_KEY` | `False` | `False` | `False` | 未設定。OpenRouter 実機 API 検証（E2）前に設定または `.env` 等の注入手段が必要 |
| `OLLAMA_API_KEY` | `False` | `False` | `False` | 未設定。Ollama Cloud 実機 API 検証（E2）前に設定が必要 |
| `OLLAMA_HOST` | `True` | `True` | `False` | バインドアドレス `0.0.0.0` が設定されている（クライアント接続時は `http://localhost:11434` を明示指定すること。`0.0.0.0` をそのまま接続先ホストとして使わないよう注意） |
| `GEMINI_API_KEY` | `True` | `True` | `False` | 設定あり（今回対象外） |
| `OPENAI_API_KEY` | `False` | `False` | `False` | 未設定 |
| `ANTHROPIC_API_KEY` | `False` | `False` | `False` | 未設定 |

---

## 2. 外部一次資料の事実（Dart SDK・Pub Workspaces・`dart compile exe`）

- **出典**: Dart 公式ドキュメント（`https://dart.dev/tools/pub/workspaces`, `https://dart.dev/tools/dart-compile`, 確認日 `2026-11-19`）および `winget search` カタログ確認。

### 2.1 Dart SDK 導入方法と対象版
- Windows では `winget install --id Google.DartSDK` で公式安定版（確認日時点で `3.13.7`）を導入可能。
- 導入後は新しいシェルセッションを開くか、インストール先 `dart-sdk\bin` を `PATH` へ反映する必要がある。

### 2.2 Pub Workspaces の成立条件
- **最小 SDK 要件**: **Dart `3.6.0` 以上**。ワークスペース内のすべてのパッケージの `pubspec.yaml` で `environment: sdk: ^3.6.0`（またはそれ以上、例 `^3.10.0`）を指定する必要がある。
- **ルート `pubspec.yaml` の必須記述**:
  ```yaml
  name: _workspace_root
  publish_to: none
  environment:
    sdk: ^3.10.0
  workspace:
    - packages/agent_kernel
    - packages/agent_runtime
    - packages/agent_drivers
    - packages/agent_acp
  ```
- **各子パッケージ `pubspec.yaml` の必須記述**:
  ```yaml
  name: agent_kernel
  environment:
    sdk: ^3.10.0
  resolution: workspace
  ```
- ルート直下に単一の `pubspec.lock` と `.dart_tool/package_config.json` が生成され、全パッケージの依存バージョンが一元解決される。

### 2.3 `dart compile exe`（Windows AOT 単一実行ファイル化）の仕様と制約
- `dart compile exe bin/main.dart -o build/agent_os.exe` により、Dart AOT ランタイムを内包した自己完結型の 64-bit Windows `.exe` を生成できる（MSVC `cl.exe` の事前導入は不要）。
- **制約 1（動的ロード不可）**: `dart:mirrors` は使用不可であり、実行時に未コンパイルの `.dart` ファイルを動的 `import` することはできない。プラグインの動的追加は外部プロセス通信（MCP 等）またはデータ駆動ファイル（`SKILL.md` 等）で行う必要がある。
- **制約 2（Build Hooks 非対応）**: 依存パッケージが Dart の `build hooks`（旧 Native Assets ビルドフック）を使用している場合、`dart compile exe` は失敗し `dart build cli`（ディレクトリ出力）が必要になる。**`kernel32.dll` 等の OS 標準 DLL を `DynamicLibrary.open('kernel32.dll')`（`dart:ffi` / `package:win32`）で呼ぶだけであれば Build Hooks は不要であり、`dart compile exe` で単一 `.exe` 化できる**（Dart SDK 導入後に実機ビルドで確認すること）。

---

## 3. Windows Job Object FFI 仕様と実測確認（`sys_exec` 子孫プロセス一括終了）

- **出典**: Microsoft Learn（`Job Objects`, `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`, `AssignProcessToJobObject`）、`pub.dev/packages/win32`（v5/v6 系、SDK 要件 `>=3.10.0` 相当）、および本機 Windows 11 Build 26300 上での `<windows.h>` オフセット実測・プロセスツリー強制終了テスト（確認日 `2026-11-19`）。

### 3.1 Win32 API 呼び出しシーケンス（`kernel32.dll`）

1. **`CreateJobObjectW(nullptr, nullptr)`**: 無名 Job Object ハンドル `hJob` を作成する（失敗時は `0` / `NULL`）。
2. **`SetInformationJobObject(hJob, 9, pExtendedInfo, 144)`**:
   - 第 2 引数 `JobObjectInfoClass` に `JobObjectExtendedLimitInformation = 9` を渡す。
   - `BasicLimitInformation.LimitFlags` に `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000` を設定する。これにより、タイムアウト時の明示的な `TerminateJobObject` だけでなく、**親の Dart エージェント自体がクラッシュ・強制終了して `hJob` ハンドルが OS により閉じられた場合にも、配下の全子孫プロセスがカーネルによって確実に強制終了される**。
3. **プロセス起動（`Process.start`）と `OpenProcess` → `AssignProcessToJobObject`**:
   - Dart の `dart:io` `Process.start(...)` は Win32 の生のプロセスハンドルを公開せず `int pid` のみを返す。
   - そのため `OpenProcess(dwDesiredAccess, FALSE, pid)` で `hProcess` を取得し、`AssignProcessToJobObject(hJob, hProcess)` を呼んだ直後に `CloseHandle(hProcess)` する（`hJob` はコマンド終了まで保持し続ける）。
   - **最小必要アクセス権（実測確認済み）**: `PROCESS_SET_QUOTA (0x0100) | PROCESS_TERMINATE (0x0001) = 0x0101` のみで `AssignProcessToJobObject` が成功する。
4. **終了・タイムアウト時の回収**:
   - タイムアウトまたはキャンセル時は `TerminateJobObject(hJob, exitCode)` を呼び、続けて `CloseHandle(hJob)` を呼ぶ。
   - 正常終了時も `finally` ブロックで必ず `CloseHandle(hJob)` を呼び、起動コマンドが裏で残したバックグラウンド孫プロセスを掃除する。

### 3.2 64-bit Windows における構造体サイズ・アライメント（`<windows.h>` 実測値）

本機の `C:\msys64\ucrt64\bin\gcc.exe` で `<windows.h>` の `sizeof` / `offsetof` を実測した結果は以下の通り。`SetInformationJobObject` は構造体サイズ（`144` バイト）が 1 バイトでも異なると `ERROR_BAD_LENGTH (24)` で失敗するため、`dart:ffi` で自前定義する場合も `package:win32` を使う場合も以下のレイアウトを厳守すること（**`@Packed` を付けてはならない**。自然な 8 バイトアライメントによる 4 バイトパディングが 2 箇所入る）。

| 構造体 / フィールド | 型 (64-bit Windows) | オフセット (byte) | サイズ (byte) | 定数値・備考 |
| --- | --- | ---: | ---: | --- |
| **`JOBOBJECT_BASIC_LIMIT_INFORMATION`** | struct | `0` | **`64`** | |
| `PerProcessUserTimeLimit` | `Int64` (`LARGE_INTEGER`) | `0` | `8` | |
| `PerJobUserTimeLimit` | `Int64` (`LARGE_INTEGER`) | `8` | `8` | |
| **`LimitFlags`** | `Uint32` (`DWORD`) | **`16`** | `4` | **`0x00002000`** (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) |
| *(alignment padding)* | — | `20` | `4` | 次の `SIZE_T` (8 byte) 境界合わせ |
| `MinimumWorkingSetSize` | `UintPtr` (`SIZE_T`) | `24` | `8` | |
| `MaximumWorkingSetSize` | `UintPtr` (`SIZE_T`) | `32` | `8` | |
| `ActiveProcessLimit` | `Uint32` (`DWORD`) | `40` | `4` | |
| *(alignment padding)* | — | `44` | `4` | 次の `ULONG_PTR` (8 byte) 境界合わせ |
| `Affinity` | `UintPtr` (`ULONG_PTR`) | `48` | `8` | |
| `PriorityClass` | `Uint32` (`DWORD`) | `56` | `4` | |
| `SchedulingClass` | `Uint32` (`DWORD`) | `60` | `4` | |
| **`IO_COUNTERS`** | struct | `64` | **`48`** | `Uint64` × 6 個 |
| **`JOBOBJECT_EXTENDED_LIMIT_INFORMATION`** | struct | `0` | **`144`** | `Basic(64) + Io(48) + SIZE_T×4(32)` |
| `ProcessMemoryLimit` | `UintPtr` (`SIZE_T`) | `112` | `8` | |
| `JobMemoryLimit` | `UintPtr` (`SIZE_T`) | `120` | `8` | |
| `PeakProcessMemoryUsed` | `UintPtr` (`SIZE_T`) | `128` | `8` | |
| `PeakJobMemoryUsed` | `UintPtr` (`SIZE_T`) | `136` | `8` | |

### 3.3 ローカルで確認した実行結果（孫プロセス一括終了の実証）
- **操作**: `.planworks\pt01_smoke\` にて、C# P/Invoke から上記 144 バイトバッファ（オフセット `16` に `0x2000` のみ設定）で `CreateJobObjectW` → `SetInformationJobObject(..., 9, buf, 144)` を呼び、`powershell.exe` 子プロセスからさらに `ping.exe -n 60 127.0.0.1`（孫プロセス）を生成させ、PID から `OpenProcess(0x0101, false, pid)` → `AssignProcessToJobObject` → `TerminateJobObject(hJob, 137)` を実行。
- **結果**: `SetInformationJobObject=True`, `AssignProcessToJobObject=True`, 強制終了前の孫生存 `True` → `TerminateJobObject` 直後に親・孫ともに生存 `False`（ゾンビ残留ゼロ）を実測確認。

---

## 4. 判断・経験則と注意点（レースコンディション対策）

1. **`Process.start` + `OpenProcess` 方式のレースウィンドウと対策**:
   - `dart:io` の `Process.start` は `CREATE_SUSPENDED` を指定できないため、「プロセス起動完了 〜 `AssignProcessToJobObject` 完了」までの数ミリ秒の隙間に親プロセスが超高速で子プロセスを spawn して即終了した場合、その子プロセスが Job から漏れる理論上のレースウィンドウがある。
   - **対策 A（Stage 1 で十分実用的かつ標準ストリーム扱いが容易）**: `Process.start` が返った直後（`stdout`/`stderr` リスナ待機より前）に同期 FFI で即座に `OpenProcess` + `AssignProcessToJobObject` を呼ぶ。またプロセスが既に一瞬で終了していた場合は `OpenProcess` または `AssignProcessToJobObject` が `ERROR_INVALID_PARAMETER` / `ERROR_ACCESS_DENIED`（終了済みプロセスへの割当不可）を返すため、終了コード取得済みか判定してエラーハンドリングする。
   - **対策 B（レース完全ゼロが必要な場合）**: Win32 `CreateProcessW` を `CREATE_SUSPENDED (0x00000004)` 付きで呼び、`AssignProcessToJobObject` 完了後に `ResumeThread` する（ただし無名パイプ作成と Dart 非同期 `Stream` へのブリッジ実装が増えるため、まずは対策 A で実装し、テストで問題が出た場合のみ対策 B を採るのが妥当）。
2. **Windows 8 以降の Nested Jobs 対応**:
   - Windows 11 では親プロセス（VS Code ターミナルやランナー等）が既に別の Job Object に入っていても、子用の新しい Job Object への `AssignProcessToJobObject` はネストされた Job として問題なく成功する（今回の PowerShell タスクランナー配下での実測でもネスト成功を確認済み）。
   - `JOB_OBJECT_LIMIT_BREAKAWAY_OK (0x800)` は**設定しないこと**（設定すると外部コマンド側が `CREATE_BREAKAWAY_FROM_JOB` で脱獄できてしまうため）。

---

## 5. 未確認事項と再確認条件

- **未確認 1（Dart SDK 実機動作）**: 本機に Dart SDK が未導入のため、`dart pub get`（Pub Workspaces 解決）、`package:win32` または `dart:ffi` コードの型検査、`dart compile exe` による `.exe` 出力自体は未実行。
  - **開始・解消条件**: 実装工程の最初（または環境準備ステップ）で `winget install --id Google.DartSDK`（`>=3.10.0`）を導入し、`dart --version` と最小 `dart compile exe` を確認すること。
- **未確認 2（クラウド API キー環境変数）**: `OPENROUTER_API_KEY` および `OLLAMA_API_KEY` が環境変数に未設定のため、これら 2 プロバイダの実機 E2 実行前に利用者によるキー設定（環境変数または git/jj 無視対象の `.env` 読み込み機構）が必要。
