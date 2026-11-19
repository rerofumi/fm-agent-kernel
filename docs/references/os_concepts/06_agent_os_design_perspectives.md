# 6. `01_idea.md` 検討のための対照マッピングと論点整理

本資料は、収集した OS アーキテクチャおよび概念（[01](./01_kernel_architectures.md) 〜 [05](./05_drivers_observability_and_systems.md)）を、[01_idea.md](../../01_idea.md) の構想と対応づけ、設計検討時の比較軸・論点を整理したものである。

---

## 6.1 アイデア要素と OS 概念の対応表

| `01_idea.md` の構想項目 | 対応する OS アーキテクチャ / 概念 | 特に参考になる具体モデル |
| :--- | :--- | :--- |
| **カーネル＝システムコール層（防波堤）**<br>エージェントループ本体をカーネルに置かない | マイクロカーネルの最小性原則<br>エグゾカーネルの「機構と方針の分離」 | seL4, L4, Zircon, Exokernel<br>OpenSSH の特権分離（Monitor vs Worker） |
| **マイクロエージェントカーネル（プロセス）**<br>ユーザー依頼で起動しエージェントループを回す | ユーザー空間プロセス / ライブラリ OS / SIP / Isolate | Erlang BEAM プロセス, Dart Isolate, Singularity SIP, Unikernel |
| **危険操作の抑止と保護リング**<br>リングレベルに応じたユーザー許可確認ゲート | 保護リング & Call Gate<br>システムコールインターセプション<br>Exception / User-notif 機構 | Multics リング, `seccomp` (`RET_USER_NOTIF`), Capsicum, OpenBSD `pledge` |
| **子プロセス生成とメールボックス**<br>Actor モデルに近いメッセージ交換 | 非同期メールボックス / 同期ランデブー IPC<br>双方向チャネル＋権限転送 | Actor モデル (Erlang), Mach Port, Zircon Channel, Hubris 同期 IPC |
| **1. ケイパビリティ方式**<br>子には親の権限の一部だけを渡す | オブジェクトケーパビリティ<br>Zero Ambient Authority & Attenuation | Zircon (Handle + Rights), seL4 CSpace, Capsicum, WASI |
| **2. 資源の上限（rlimit / cgroup）**<br>トークン・費用・時間・子の数を制限 | `rlimit`, `cgroups v2`（階層型予算管理）<br>親→子へのクオータ寄贈（Quota Donation） | Linux `cgroups v2`, Genode の階層的クオータ管理 |
| **3. シグナルと Supervisor**<br>プロセス監督・障害回復 | Supervisor ツリー（Let It Crash）<br>再起動ポリシー・例外チャネル | Erlang/OTP Supervisor, MINIX 3 Reincarnation Server, Hubris Supervisor, `systemd` |
| **4. VFS・名前空間・CoW トランザクション**<br>書き込みをためてロールバック実現 | Per-process 名前空間 + Union/OverlayFS<br>CoW スナップショット + WAL/トランザクション | Plan 9 プライベート名前空間, Linux OverlayFS, ZFS/Btrfs, Qubes Disposable VM |
| **5. 全システムコール監査ログ**<br>`strace` 相当の記録＋キャッシュ/入出力監視 | システムコールトレース・動的トレース・監査・決定論的リプレイ | `strace`, `auditd`, eBPF, ETW, `rr` (Time-travel) |
| **6. 文脈管理のページング**<br>有限コンテキスト窓の出し入れとキャッシュ | 仮想記憶・ページング・ワーキングセット・置換アルゴリズム・Dirty Write-back | Denning Working Set, Clock / ARC / 2Q, zram (要約圧縮退避) |
| **7. 外部連携のドライバ層**<br>LLM プロバイダ・MCP・Git の抽象化 | VFS / FUSE / HAL / Virtio / リソースマネージャ | Plan 9 ファイルサーバー, QNX Resource Manager, Virtio, Linux VFS |
| **ACP による上位 UI 分離 & モジュラー化** | クライアント/サーバー分離・IDL・Component Model | Fuchsia FIDL / Component, Chromium IPC (Mojo), 9P プロトコル |

---

## 6.2 設計検討において特に掘り下げるべき論点（OS の歴史からの教訓）

### 論点 1: 「物理隔離」か「言語内隔離（Framekernel / Intralingual）」か
- Dart で単一バイナリ（exe）プロトタイプを作る場合、各エージェントプロセスを **OS プロセス** として分けるか、**Dart Isolate（共有メモリなしアクター）** として分けるか、**同一メモリ内の型境界（Framekernel 的 OSTD 分離）** とするかの選択がある。
- **OS からの教訓**:
  - 外部プロセス（OS プロセス）や外部ツール実行（シェル・コンパイラ）を伴う部分は OS レベルの隔離（ディレクトリ/環境/プロセス権限）が効く。
  - 一方、エージェントループ同士の連携や高速な構造化データ交換は、Singularity (SIP) や Asterinas (Framekernel)、Dart Isolate のように **「言語・ランタイム内の非共有メッセージパッシング＋カーネルモジュール（OSTD 相当）の厳格な境界」** とすると、IPC コストを抑えつつ見通しと型安全性を保ちやすい。
  - **ハイブリッド解**: 「カーネル（システムコール検証・権限制御・監査・ドライバ管理）」と「エージェントプロセス（Isolate 等）」は同一ランタイム内の明確なインターフェース境界で分離し、エージェントが呼び出す **実環境操作（シェルコマンド等）は OS プロセス/サンドボックス境界へ落とす** 構造。

### 論点 2: メッセージパッシングは「非同期メールボックス」か「同期ランデブー」か
- `01_idea.md` では「メールボックス（Actor モデルに近い）」が挙げられている。
- **OS からの教訓**:
  - 純粋な無制限非同期メールボックスは、暴走した子エージェントが大量のメッセージを送りつけて親やシステムを飽和させる **Fault Amplification（障害増幅）** を起こしやすい（Hubris の指摘）。
  - **対策の選択肢**: メールボックスに必ず上限（Bounded Queue / バックプレッシャ）を設ける、あるいは重要な承認要求やリソース要求（tool call / syscall）は同期ランデブー（要求→承認/実行→応答まで呼び出し元が停止）にする。

### 論点 3: State Spill（状態漏出）をどう防ぐか（Theseus OS の教訓）
- プロバイダやモデルを「人間のプロンプト入力ごとに切り替える」構想や、プラグイン（フック・スキル・ツール）の着脱を実現するには、特定のプロバイダ固有の状態（特殊な会話形式、ツール ID 体系、キャッシュ状態など）がカーネルや他のモジュールに漏れ出さないことが重要。
- **OS からの教訓**:
  - Theseus が指摘するように、コンポーネント間で暗黙の共有状態（State Spill）を持つと差し替えが破綻する。
  - カーネル側の状態表現（会話履歴・リソース・システムコール仕様）をプロバイダ非依存の正規化モデル（Virtio / VFS のような統一抽象）に閉じ込め、ドライバ（各 LLM プロバイダ）はステートレス変換に近い形で保つと切り替えが容易になる。

### 論点 4: 権限と予算の継承（Capability + Genode Quota モデル）
- 親エージェントが子エージェントを生成する際、以下の 2 つを同時に制限・委譲できると安全性が高い。
  1. **何ができるか（Capability Attenuation）**: 例「親はプロジェクト全体の Write 権限を持つが、調査用の子には特定ディレクトリの Read-Only ハンドルと `web_search` のみ渡す」「危険な書き込みはリングレベル上ユーザー承認ゲートを通す」。
  2. **どれだけ使えるか（Hierarchical Quota / cgroup）**: 例「親の残り予算（トークン数・金額・時間・最大子数）の一部を子に寄贈（Donation）し、子が使い切ったら親へ戻る」。
- また、親が子を終了させたとき、子が作った孫や開いた一時資源（CoW 作業ツリー等）が孤児化しないよう、cgroup / Process Group のように **ツリー単位の一括回収（Cleanup）** が不可欠。

### 論点 5: 文脈ページング（Context Paging）の境界とキャッシュヒット率との緊張関係
- `01_idea.md` では「キャッシュヒットも大きな要因になってきたのでキャッシュも監視したい」「文脈管理をページングとみなす」とある。
- **OS からの教訓（および LLM 特有の制約）**:
  - 通常の OS ページングは任意のページの出し入れが容易だが、LLM の KV キャッシュ（Prompt Caching）は **Prefix 一致（先頭からの連続一致）** に強く依存する。
  - つまり「途中のページを頻繁にスワップアウト・順序変更する（LRU 等）」と、**Prefix キャッシュが無効化されコストとレイテンシが跳ね上がる**（OS における TLB フラッシュやスラッシングに類似）。
  - したがって、文脈ページングでは「**不変な固定ページ（Pinned Pages: システム指示・基本定義・共有知識）を先頭に固定し、後ろのワーキング領域だけを追記・退避・圧縮（zram 的要約）する**」といった **キャッシュフレンドリーなメモリ配置戦略** が鍵になる。

### 論点 6: CoW / Overlay による作業隔離と外部副作用の扱い
- ファイル操作（Read/Write）は OverlayFS / CoW のようにメモリや一時ディレクトリに書き込みを溜め、ユーザー確認後またはタスク成功時に実ディレクトリへコミット（失敗時は破棄）できる。
- **OS からの教訓**: ファイル操作はロールバック可能でも、**外部通信（API 送信、Git push、不可逆なコマンド実行）は CoW できない**。OS のトランザクションシステムや Qubes/Capsicum では、副作用を持つ操作を「コミットフェーズまで遅延させる」か「別リング（承認必須ゲート）に分類して実行前に確認を取る」ことで整合性を保つ。
