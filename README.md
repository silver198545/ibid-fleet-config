# ibid-fleet-config

dev → staging → production の3つのRKE2クラスタ(Harvester上、Rancher管理)で
数十のWordPressサイトを運用するためのFleet(GitOps)構成リポジトリ。

## 全体像

- **単一mainブランチ + 環境別ディレクトリ**(`envs/dev|staging|production`)。
  環境ごとのGitRepo([fleet-bootstrap/](fleet-bootstrap/))が自分の環境のディレクトリ
  だけを監視し、`env=<環境名>` ラベルのクラスタへ適用する。
- **昇格(プロモーション)はPRで制御**する。Actionsの `promote` ワークフローが
  dev→staging / staging→production の昇格PRを生成し、`envs/production/` 配下は
  [CODEOWNERS](.github/CODEOWNERS) により承認必須(mainブランチ保護)。
  承認済みマージのみが本番クラスタに届く。
- Gitで昇格するのは**構成のみ**(チャートバージョン、values、イメージ)。
  DBデータ・wp-contentは昇格しない([docs/manual-wordpress-restore.md](docs/manual-wordpress-restore.md))。

## 構成

- `envs/<env>/`: 環境別のFleetバンドル([envs/README.md](envs/README.md)参照)
  - `infra/`: カタログ登録(Bitnami)・Longhorn CRD・Longhorn 本体
  - `sites/<site>/`: WordPressサイト(1サイト=1ディレクトリ、`fleet.yaml`)
- `charts/ibid-wordpress/`: 全サイト共通デフォルトを内包したラッパーチャート
  (Bitnami `wordpress` を依存に持つ)。mainマージで `release-chart.yaml` がGHCRへ公開し、
  各サイトの `helm.version` を上げることで環境ごとに取り込む
- `images/wordpress/`: カスタムWordPressイメージ(digest固定。Bitnami無償イメージが
  `latest` のみになったことへの対策)。mainマージで `build-image.yaml` がGHCRへ公開
- `fleet-bootstrap/`: 環境別GitRepo定義(Rancher localクラスタへ手動適用する控え)
- `scripts/new-wordpress-site.sh <env> <site>`: サイトのFleetバンドルをひな形から生成
- `scripts/bootstrap-site-secrets.sh <site>`: サイトの認証情報Secret(3種)を
  対象クラスタへ作成(パスワードはサイトごと・環境ごとにランダム生成)
- `scripts/deploy-wordpress.sh <env> <site>`: **緊急用(break-glass)**の手動デプロイ。
  通常の変更はPRマージ→Fleet適用で行う
- `.github/workflows/`: `validate`(PR検証)、`release-chart`(チャート公開)、
  `build-wordpress-image`(イメージ公開)、`promote`(昇格PR生成)
- `docs/manual-multi-env.md`: マルチ環境のセットアップ・既存クラスタの移行・昇格運用・
  break-glass手順
- `docs/manual-harvester-loadbalancer.md`: Harvester Cloud Provider の IPPool 作成手順
  (MetalLB は廃止し、Harvester Cloud Provider に一本化。クラスタごとに作成)
- `docs/manual-wordpress.md`: WordPressサイトを追加する手順
- `docs/manual-wordpress-restore.md`: 既存の別環境WordPressサイトからデータを移行
  (リストア)する手順

## 想定フロー

### 環境の新規構築(クラスタごと)

1. Rancher UIでRKE2クラスタを作成し、`env=<環境名>` ラベルを付与する
   (cloud-initに `nfs-common` を含める)。
2. [docs/manual-harvester-loadbalancer.md](docs/manual-harvester-loadbalancer.md) の手順で
   Harvester 管理クラスタにそのクラスタ用の IPPool を作成する。
3. `fleet-bootstrap/gitrepo-<env>.yaml` を Rancher local クラスタへ適用する。
4. Fleetが `envs/<env>/infra/`(カタログ登録 → Longhorn CRD → Longhorn 本体)を適用する。

詳細: [docs/manual-multi-env.md](docs/manual-multi-env.md)

### サイトの追加と昇格

1. `scripts/bootstrap-site-secrets.sh <site>` で対象クラスタにSecretを作成する
   (認証情報はサイトごと・環境ごとに自動生成)。
2. `scripts/new-wordpress-site.sh dev <site>` でバンドルを生成し、PR→マージ。
   devのFleetが自動適用する。WordPress は自分専用の LoadBalancer Service を持つため、
   Traefik を LoadBalancer 化する必要はない。
3. devで動作確認後、Actionsの `promote` を手動起動して昇格PRを作成し、
   レビュー・承認を経てマージする(staging→productionも同様。本番は承認必須)。

詳細: [docs/manual-wordpress.md](docs/manual-wordpress.md)

## 補足: MetalLB からの移行について

各クラスタは Rancher 経由で Harvester 上にプロビジョニングされており、
**Harvester Cloud Provider** が組み込まれています。MetalLB と Harvester Cloud Provider は
どちらも `Service type=LoadBalancer` を検知して IP を払い出そうとするため、両方を有効にすると
競合します。そのため本リポジトリでは MetalLB を廃止し、Harvester Cloud Provider の
IPPool 機能に一本化しています。

## 補足: 旧構成(単一クラスタ)からの移行

リポジトリ直下の `catalog-repos/`・`longhorn-crd/`・`longhorn/` は旧GitRepo
(`base-infra`)が参照している移行前のバンドルです。`envs/dev/infra/` への移設は
[docs/manual-multi-env.md](docs/manual-multi-env.md) の手順(keepResourcesの同期確認 →
リリース名の引き継ぎ → 旧GitRepo削除 → 移設PRマージの順)で行ってください。
