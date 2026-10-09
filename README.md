# ibid-fleet-config

dev → production の2つのRKE2クラスタ(Harvester上、Rancher管理)で
数十のWordPressサイトと自作アプリを運用するためのFleet(GitOps)構成リポジトリ。

## 全体像

- **単一mainブランチ + 環境別ディレクトリ**(`envs/dev|production`)。
  環境ごとのGitRepo([fleet-bootstrap/](fleet-bootstrap/))が自分の環境のディレクトリ
  だけを監視し、`env=<環境名>` ラベルのクラスタへ適用する。
- **昇格(プロモーション)はPRで制御**する。`envs/production/` 配下は
  [CODEOWNERS](.github/CODEOWNERS) により承認必須(mainブランチ保護)。
  承認済みマージのみが本番クラスタに届く。
- サイト・アプリのバンドルは**全環境で同一内容**にし、環境差分はクラスタラベルで選ぶ。
  昇格はディレクトリの丸ごとコピーで完結する。
- Gitで昇格するのは**構成のみ**(チャートバージョン、values、イメージ)。
  DBデータ・wp-contentは昇格しない。
- 本番データでの確認は、dev1上の一時的なリハーサルサイト`<site>-rh`で行う
  (staging環境は2026-10-08に廃止)。

## 現在の構成(2026-10-09時点)

| | dev1(`env=dev`) | prod1(`env=production`) |
|---|---|---|
| ノード | control-plane 3台(SSD) + worker 5台 | 同じ |
| WordPressサイト | 15 | 2(web、dna) |
| 自作アプリ | 4(brc-advanced-search、riken-diips、sparqlist、metadatabase-v2) | 3(metadatabase-v2以外) |
| TraefikのLB IP(IPPool) | `192.168.1.33`(pool1 `.30-.49`) | `192.168.1.99`(pool3 `.90-.100`) |
| ホスト名(DNS) | `<site>.dev.ibid.lan`(`*.dev`のワイルドカード) | `<site>.production.ibid.lan`(`*.production`のワイルドカード) |

WordPressのデータの置き場所:

| データ | StorageClass | 実体 | 定期バックアップ |
|---|---|---|---|
| wp-content | `nfs-external` | NFS `192.168.1.1:/data/nfs/wordpress/<env>/` | サイトのCronJob(日次、14日分、NFS `/data/nfs/backup/<env>/`) |
| MariaDB | `harvester` | Harvester側のボリューム | 同上(DBダンプ) |
| (参考)Prometheus、sparqlist等 | `longhorn`/`longhorn-r1` | ゲストLonghorn | Longhornの日次バックアップ(NFS `/data/nfs/longhorn/<env>`) |

WordPressのバックアップCronJobはチャート0.6.0から(2026-10-09に両環境へ導入)。NFSサーバー上のデータの二次コピーは、組織のBaculaのバックアップで取られている(本リポジトリの管理外)。
([docs/roadmap.md](docs/roadmap.md)の項目5)。戻し方は
[docs/manual-wordpress-restore.md](docs/manual-wordpress-restore.md)「日次バックアップ」。

## ドキュメント

まず読むもの:

| 文書 | 内容 |
|---|---|
| [docs/operations-flow.md](docs/operations-flow.md) | 日常の変更の流れ(dev → リハーサル → production)、環境差分の書き方、本番反映前のバックアップ |
| [docs/manual-multi-env.md](docs/manual-multi-env.md) | GitHub設定、**クラスタの新規作成チェックリスト**(2.)、日常運用・定期メンテナンス、バックアップ、封印鍵、break-glass、DR |
| [docs/roadmap.md](docs/roadmap.md) | 決定事項の記録と、残っている課題(優先度つき) |
| [docs/manual-tooling-setup.md](docs/manual-tooling-setup.md) | 作業端末のツール(kubectl/helm/kubeseal/gh等)とkubeconfig |

作業別の手順:

| 作業 | 文書 |
|---|---|
| WordPressサイトの追加・削除、プラグイン管理 | [docs/manual-wordpress.md](docs/manual-wordpress.md) |
| WordPressのデータ移行・リストア、外部リバースプロキシ経由の公開 | [docs/manual-wordpress-restore.md](docs/manual-wordpress-restore.md) |
| 自作アプリ(`apps/`)の追加・昇格、アプリ別のメモ | [docs/manual-apps.md](docs/manual-apps.md) |
| アプリのイメージ更新をRundeckから実行 | [docs/manual-rundeck-app-image.md](docs/manual-rundeck-app-image.md) |
| 監視・アラート(rancher-monitoring + Slack) | [docs/manual-monitoring.md](docs/manual-monitoring.md) |
| TLS証明書(cert-manager + FreeIPA ACME)、DNS登録 | [docs/manual-cert-manager-freeipa-acme.md](docs/manual-cert-manager-freeipa-acme.md) |
| IPPool、TraefikのLoadBalancer化、Rancher chartValuesの注意 | [docs/manual-harvester-loadbalancer.md](docs/manual-harvester-loadbalancer.md) |
| control-plane VMのディスクをSSDに限定(etcd遅延対策) | [docs/manual-harvester-etcd-ssd.md](docs/manual-harvester-etcd-ssd.md) |
| ノードの時刻同期(chrony)とノードのUser Data | [docs/manual-node-ntp.md](docs/manual-node-ntp.md) |

障害対応・記録:

| 文書 | 内容 |
|---|---|
| [docs/manual-dr-troubleshooting.md](docs/manual-dr-troubleshooting.md) | DR・ボリューム復元・ノード入れ替えで詰まった点と対処(Machine削除の停止など) |
| [docs/manual-storage-migration.md](docs/manual-storage-migration.md) | 【完了済み】既存サイトのPVCを`harvester`/`longhorn-r1`/`nfs-external`へ移した記録 |
| [docs/wordpress-site-delegation.md](docs/wordpress-site-delegation.md) | サイト管理を他チームへ委譲する際の運用設計(検討記録) |
| [envs/README.md](envs/README.md)、[fleet-bootstrap/README.md](fleet-bootstrap/README.md) | 環境別ディレクトリとGitRepo定義の説明 |

## ディレクトリ構成

- `envs/<env>/`: 環境別のFleetバンドル(`infra/`・`sites/`・`apps/`・`secrets/`)。
  [envs/README.md](envs/README.md)
- `charts/ibid-wordpress/`: 全サイト共通デフォルトを内包したラッパーチャート
  (Bitnami `wordpress` を依存に持つ)。値を変えたら`Chart.yaml`のversionを上げる。
  mainマージで `release-chart.yaml` がGHCRへ公開し、各サイトの `helm.version` を上げて取り込む
- `images/wordpress/`: カスタムWordPressイメージ(digest固定。Bitnami無償イメージが
  `latest` のみになったことへの対策)
- `images/<app>/`: 自作アプリのビルド定義(アプリ本体は別リポジトリ。`SRC_REF`で固定)
- `fleet-bootstrap/`: 環境別GitRepo定義(Rancher localクラスタへ手動適用する控え)
- `rundeck/jobs/`: `update-app-image.sh`用のRundeckジョブ定義
- `.github/workflows/`:
  - `validate`: PR検証(YAML構文、fleet.yamlの必須キー、helm lint/template)
  - `promote`: `sites/`の昇格PR生成(手動起動。`site`にサイト名か`all`)
  - `release-chart`: チャート公開
  - `build-image`: WordPressイメージ公開
  - `build-<app>-image`: 自作アプリのイメージ公開(brc-advanced-search、riken-diips、sparqlist、metadatabase-v2)

## スクリプト

| スクリプト | 用途 |
|---|---|
| `scripts/new-wordpress-site.sh <env> <site>` | サイトのfleet.yamlをひな形から生成 |
| `scripts/seal-site-secrets.sh <env> <site>` | サイトの認証情報Secret(3種)をSealedSecretとして生成(環境ごと・サイトごとにランダム) |
| `scripts/rehearsal-site.sh <site> <production\|dev>` | 本番データリハーサル用の`<site>-rh`バンドルを生成 |
| `scripts/restore-wordpress.sh <site> <dir> [ts]` | `yyyymmdd_hhmm.tar.lzo`/`.dump.lzo`のバックアップをサイトへリストア |
| `scripts/update-app-image.sh <subcommand>` | 自作アプリのイメージ更新〜dev→production昇格PR |
| `scripts/seal-monitoring-secret.sh <env>` | アラート通知用Slack Webhook URLのSealedSecret |
| `scripts/seal-sparqlist-secret.sh <env>` | sparqlistのADMIN_PASSWORDのSealedSecret |
| `scripts/deploy-wordpress.sh <env> <site>` | **緊急用(break-glass)**の手動デプロイ。通常はPRマージ→Fleet適用 |
| `scripts/bootstrap-site-secrets.sh <site>` | **緊急用**。Secretをクラスタへ直接作成 |

## 主なフロー

- **クラスタの新規作成・再作成**: [docs/manual-multi-env.md](docs/manual-multi-env.md)の
  「2. クラスタの新規作成」のチェックリストに従う(SSDイメージ、User Data、anti-affinity、
  2枚目のNIC、chartValues、IPPool、`env`ラベル、封印鍵)。
- **サイトの追加**: `seal-site-secrets.sh dev <site>` と `new-wordpress-site.sh dev <site>` の
  生成物を1つのPRにしてマージ → devで確認(DNSはワイルドカードなので登録不要) → `promote`で本番へ
  (本番用のSealedSecretは`seal-site-secrets.sh production <site>`で別に作る)。
  [docs/manual-wordpress.md](docs/manual-wordpress.md)
- **設定変更・バージョンアップ**: devのfleet.yamlやチャートを変更 → devで確認 →
  (DBを書き換え得る変更なら)リハーサルサイトで本番データに対して確認 → 本番のバックアップ →
  `promote`で昇格。[docs/operations-flow.md](docs/operations-flow.md)
