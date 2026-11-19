# OS アーキテクチャ・概念 調査コレクション

本ディレクトリは、[01_idea.md](../../01_idea.md) で構想されている「OS の設計思想を取り入れた AI コーディングエージェント基盤」を検討するため、黎明期から現代に至る様々なオペレーティングシステム（OS）のアーキテクチャ、機構、設計思想を網羅的に収集・整理した資料群である。

## ドキュメント一覧

| ファイル | 内容 | 主なキーワード |
| :--- | :--- | :--- |
| [01_kernel_architectures.md](./01_kernel_architectures.md) | カーネル構造の類型と歴史的系譜 | モノリシック、階層型、マイクロカーネル (L4/seL4)、ハイブリッド、エグゾカーネル、マルチカーネル、言語ベース OS (Singularity/Theseus/Asterinas)、ユニカーネル、eBPF |
| [02_execution_ipc_and_concurrency.md](./02_execution_ipc_and_concurrency.md) | 実行単位・特権分離・IPC・監視と回復 | 保護リング、プロセス/スレッド/グリーンスレッド、システムコール、`io_uring`、メールボックス、同期ランデブー IPC、Actor モデル、Supervisor ツリー |
| [03_security_capabilities_and_isolation.md](./03_security_capabilities_and_isolation.md) | セキュリティモデル・隔離・資源制御 | DAC/MAC、オブジェクトケーパビリティ (Zircon/seL4/Capsicum)、Ambient Authority 排除、Genode クオータ、Namespaces/cgroups、`pledge`/`unveil`、MicroVM |
| [04_memory_storage_and_namespaces.md](./04_memory_storage_and_namespaces.md) | 仮想記憶・名前空間・VFS・トランザクション | ページング・ワーキングセット・置換アルゴリズム、Copy-on-Write、Plan 9 プライベート名前空間と 9P、FUSE、OverlayFS/ZFS、イミュータブル OS |
| [05_drivers_observability_and_systems.md](./05_drivers_observability_and_systems.md) | ドライバ層・観測性・主要 OS ケーススタディ | ユーザー空間ドライバ、Virtio、契約・プラグイン安全性、`strace`/DTrace/eBPF/rr、主要 OS（古典〜現代研究 OS）の特徴一覧 |
| [06_agent_os_design_perspectives.md](./06_agent_os_design_perspectives.md) | `01_idea.md` 検討のための対照マッピング | アイデアの各項目と OS 概念の対応表、採用パターン別のトレードオフと検討論点 |

## 全体の見取り図

OS の歴史は、本質的に次の 4 つの緊張関係をどう解くかの試行錯誤である。

1. **性能 vs 隔離・安全性（境界のコストをどこに置くか）**
   - ハードウェア境界（MMU・特権リング・VM）による強い隔離 vs 言語・型システム・契約（SIP・Framekernel・Wasm/eBPF）による軽量な隔離。
2. **集中管理 vs 分散・委譲（ポリシーとメカニズムの分離）**
   - カーネルが全部決める（モノリシック）vs 最小限の機構だけを持ち、ポリシーをユーザー空間サーバーやアプリケーションに委ねる（マイクロカーネル・エグゾカーネル・Plan 9・Genode）。
3. **共有状態 vs メッセージパッシング（状態汚染＝State Spill の抑止）**
   - 共有メモリ・グローバル名前空間の利便性 vs ゼロ暗黙権限（Zero Ambient Authority）・明示的メッセージ/ケーパビリティ受け渡しによる疎結合と耐障害性。
4. **可変性 vs 再現性・ロールバック性（状態変更の後始末）**
   - 直接破壊的変更を行うモデル vs Copy-on-Write、Union/Overlay、ジャーナル/トランザクション、イミュータブル構成による原子的ロールバック。
