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
  - `infra/`: カタログ登録(Bitnami)・Longhorn CRD・Longhorn 本体・
    低レプリカ用StorageClass(`longhorn-r1`、二重レプリケーション対策。
    [docs/roadmap.md](docs/roadmap.md) 項目3参照)・
    監視スタック(rancher-monitoring + blackbox-exporter + アラートルール、
    [docs/manual-monitoring.md](docs/manual-monitoring.md)参照)
  - `sites/<site>/`: WordPressサイト(1サイト=1ディレクトリ、`fleet.yaml`)
  - `apps/<app>/`: WordPress以外の自作アプリ(1アプリ=1ディレクトリ、`fleet.yaml`+素の
    Kubernetesマニフェスト)。`sites/`とは性質が異なる(DBなし・ラッパーチャート未使用)ため
    分離している。追加手順・昇格の注意点は [docs/manual-apps.md](docs/manual-apps.md) 参照
- `charts/ibid-wordpress/`: 全サイト共通デフォルトを内包したラッパーチャート
  (Bitnami `wordpress` を依存に持つ)。mainマージで `release-chart.yaml` がGHCRへ公開し、
  各サイトの `helm.version` を上げることで環境ごとに取り込む
- `images/wordpress/`: カスタムWordPressイメージ(digest固定。Bitnami無償イメージが
  `latest` のみになったことへの対策)。mainマージで `build-image.yaml` がGHCRへ公開
- `images/<app>/`: WordPress以外の自作アプリのビルド定義(例: `images/brc-advanced-search/`)。
  アプリ本体は別リポジトリのため `SRC_REF`(取り込むコミットSHA)で固定する。
  詳細は [docs/manual-apps.md](docs/manual-apps.md) 参照
- `fleet-bootstrap/`: 環境別GitRepo定義(Rancher localクラスタへ手動適用する控え)
- `scripts/new-wordpress-site.sh <env> <site>`: サイトのFleetバンドルをひな形から生成
- `scripts/seal-site-secrets.sh <env> <site>`: サイトの認証情報Secret(3種)を
  SealedSecretとして `envs/<env>/secrets/` に生成(パスワードはサイトごと・
  環境ごとにランダム生成。平文はGitに入らない)。
  `scripts/bootstrap-site-secrets.sh <site>` は緊急時用(クラスタへ直接作成)
- `scripts/seal-monitoring-secret.sh <env>`: アラート通知用Slack Webhook URLを
  SealedSecretとして `envs/<env>/infra/monitoring-secrets/` に生成
- `scripts/deploy-wordpress.sh <env> <site>`: **緊急用(break-glass)**の手動デプロイ。
  通常の変更はPRマージ→Fleet適用で行う
- `scripts/restore-wordpress.sh <site> <バックアップディレクトリ>`: 既存サイトの
  バックアップ(`yyyymmdd_hhmm.tar.lzo`/`.dump.lzo`)を指定サイトへリストア
  ([docs/manual-wordpress-restore.md](docs/manual-wordpress-restore.md)参照)
- `.github/workflows/`: `validate`(PR検証)、`release-chart`(チャート公開)、
  `build-wordpress-image`(イメージ公開)、`build-brc-advanced-search-image`
  (自作アプリのイメージ公開)、`promote`(昇格PR生成。`sites/`のみが対象)
- `docs/manual-tooling-setup.md`: 作業端末に必要なCLIツール(kubectl/helm/kubeseal等)の
  インストール手順とkubeconfigの準備
- `docs/manual-multi-env.md`: マルチ環境のセットアップ・既存クラスタの移行・昇格運用・
  break-glass手順
- `docs/operations-flow.md`: 3環境の日常運用フロー(devで互換性テスト→stagingで
  本番コンテンツによる結合テスト→productionへ昇格。変更のバッチ化、テスト後の
  リセット、本番反映前バックアップ)
- `docs/manual-dr-troubleshooting.md`: DR復元(クラスタ全損からの復元)を実際に
  やってみた際に詰まりやすいポイントの補足(kubeconfig再取得、Longhornの
  fromBackup復元など)
- `docs/manual-harvester-loadbalancer.md`: Harvester Cloud Provider の IPPool 作成手順
  (MetalLB は廃止し、Harvester Cloud Provider に一本化。クラスタごとに作成)
- `docs/manual-wordpress.md`: WordPressサイトを追加する手順
- `docs/manual-apps.md`: WordPress以外の自作アプリ(`envs/<env>/apps/`)を追加する手順・
  昇格時の注意点
- `docs/manual-monitoring.md`: 監視・アラート(rancher-monitoring + Slack通知)の
  導入・運用手順
- `docs/manual-wordpress-restore.md`: 既存の別環境WordPressサイトからデータを移行
  (リストア)する手順
- `docs/manual-storage-migration.md`: 既存サイトのPVCをLonghornの二重増幅対策
  (`longhorn-r1`/`harvester` StorageClass)へ移行する手順
- `docs/wordpress-site-delegation.md`: サイト管理権限を他チームへ委譲する際の
  運用設計(記事は本番直接編集、プラグインは申請→dev検査→本番反映、権限設計)
- `docs/manual-cert-manager-freeipa-acme.md`: cert-manager + FreeIPA ACME(DNS-01/RFC2136)
  によるTLS証明書自動発行の導入手順
- `docs/roadmap.md`: 今後の開発方針(スケール前に決める設計判断、運用の穴、
  優先度とトリガー)

## 想定フロー

### 環境の新規構築(クラスタごと)

1. Rancher UIでRKE2クラスタを作成し、`env=<環境名>` ラベルを付与する
   (cloud-initに `nfs-common` を含める)。
2. [docs/manual-harvester-loadbalancer.md](docs/manual-harvester-loadbalancer.md) の手順で
   Harvester 管理クラスタにそのクラスタ用の IPPool を作成する。
3. `fleet-bootstrap/gitrepo-<env>.yaml` を Rancher local クラスタへ適用する。
4. Fleetが `envs/<env>/infra/`(カタログ登録 → Longhorn CRD → Longhorn 本体 →
   監視スタック)を適用する。監視のSlack通知には環境ごとのSealedSecret生成が必要
   ([docs/manual-monitoring.md](docs/manual-monitoring.md))。

詳細: [docs/manual-multi-env.md](docs/manual-multi-env.md)

### サイトの追加と昇格

1. `scripts/seal-site-secrets.sh dev <site>` で認証情報のSealedSecretを生成する
   (パスワードはサイトごと・環境ごとに自動生成。生成物はGitにコミット)。
2. `scripts/new-wordpress-site.sh dev <site>` でバンドルを生成し、1と合わせてPR→マージ。
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

infraバンドルは旧構成(リポジトリ直下、GitRepo `base-infra`)から `envs/<env>/infra/` へ
移設済みです。devの各fleet.yamlの `helm.releaseName` が `base-infra-*` なのは、
旧GitRepo時代のHelmリリースをそのまま引き継いでいるためです(経緯は
[docs/manual-multi-env.md](docs/manual-multi-env.md) 参照)。
