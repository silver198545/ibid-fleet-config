# ibid-fleet-config

## 構成

- `catalog-repos/`: Rancher のカタログリポジトリ定義（Bitnami）
- `longhorn-crd/`: Rancher Charts から Longhorn CRD を導入する Fleet バンドル
- `longhorn/`: Rancher Charts から Longhorn 本体を導入する Fleet バンドル
- `wordpress-<site>/`: サイトごとに独立したWordPressの設定一式（例: `wordpress-web/`）。
  Bitnami の WordPress Chart を LoadBalancer 冗長構成で導入する。Fleetバンドルとしては
  使用しておらず、`scripts/deploy-wordpress.sh` が読み取るhelm valuesの参照元。
  `scripts/new-wordpress-site.sh <site>` でひな形を生成する
- `wordpress-base-values.yaml`: 全WordPressサイトに共通するデフォルトのHelm values。各サイトの
  `fleet.yaml`にはこのファイルとの差分（Secret名やサイト固有の設定）のみを書く
- `scripts/deploy-wordpress.sh`: `wordpress-base-values.yaml`と`wordpress-<site>/fleet.yaml`の
  内容をもとに WordPress を手動デプロイするスクリプト（Fleetを介さない）。第1引数にサイト名を
  指定（必須）
- `scripts/new-wordpress-site.sh`: 追加のWordPressサイト用ディレクトリ(`wordpress-<site>/fleet.yaml`)を
  ひな形から生成するスクリプト
- `docs/manual-harvester-loadbalancer.md`: Harvester Cloud Provider の IPPool 作成手順
  （MetalLB は廃止し、Harvester Cloud Provider に一本化）
- `docs/manual-wordpress.md`: WordPressサイトを追加する手順（ひな形生成、Secret作成、
  デプロイスクリプトの実行）

## 想定フロー

1. Fleet で `catalog-repos/` を適用して、Chart リポジトリを追加します。
2. Fleet で `longhorn-crd/` を適用して、Longhorn CRD を導入します。
3. Fleet で `longhorn/` を適用して、Longhorn 本体を導入します。
4. [docs/manual-harvester-loadbalancer.md](docs/manual-harvester-loadbalancer.md) の手順で
   Harvester 管理クラスタに IPPool を作成します。
5. [docs/manual-wordpress.md](docs/manual-wordpress.md) の手順で `scripts/new-wordpress-site.sh`
   によりサイトのひな形を生成し、Secret を作成した後、`scripts/deploy-wordpress.sh <site>` を
   実行して WordPress を導入します（Fleetでは管理しません）。サイトを追加するたびにこの手順を
   繰り返します。WordPress は自分専用の LoadBalancer Service を持つため、Traefik を
   LoadBalancer 化する必要はありません。

## 補足: MetalLB からの移行について

このクラスタは Rancher 経由で Harvester 上にプロビジョニングされており、
**Harvester Cloud Provider** が組み込まれています。MetalLB と Harvester Cloud Provider は
どちらも `Service type=LoadBalancer` を検知して IP を払い出そうとするため、両方を有効にすると
競合します。そのため本リポジトリでは MetalLB を廃止し、Harvester Cloud Provider の
IPPool 機能に一本化しています。
