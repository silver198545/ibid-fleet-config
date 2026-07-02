# ibid-fleet-config

## 構成

- `catalog-repos/`: Rancher のカタログリポジトリ定義（Bitnami）
- `longhorn-crd/`: Rancher Charts から Longhorn CRD を導入する Fleet バンドル
- `longhorn/`: Rancher Charts から Longhorn 本体を導入する Fleet バンドル
- `wordpress/`: Bitnami の WordPress Chart を LoadBalancer 冗長構成で導入する設定一式
  （Fleetバンドルとしては使用しておらず、`scripts/deploy-wordpress.sh` が読み取るhelm valuesの
  参照元。最初のWordPressサイト）
- `wordpress-web/`: 2サイト目のWordPress（サイト名`web`）。用途・運用方法は`wordpress/`と同じで、
  namespace/リリース名も`wordpress-web`に統一。追加経緯は
  `docs/manual-wordpress-multi-site.md`参照
- `scripts/deploy-wordpress.sh`: `wordpress/fleet.yaml`（または`wordpress-<site>/fleet.yaml`）の
  内容をもとに WordPress を手動デプロイするスクリプト（Fleetを介さない）。第1引数にサイト名を
  指定（省略時は最初のサイト）
- `scripts/new-wordpress-site.sh`: 追加のWordPressサイト用ディレクトリ(`wordpress-<site>/fleet.yaml`)を
  ひな形から生成するスクリプト
- `docs/manual-harvester-loadbalancer.md`: Harvester Cloud Provider の IPPool 作成手順
  （MetalLB は廃止し、Harvester Cloud Provider に一本化）
- `docs/manual-wordpress.md`: WordPress 導入前の Secret 作成、デプロイスクリプトの実行手順
  （最初のサイト）
- `docs/manual-wordpress-multi-site.md`: 同じクラスターに2サイト目以降のWordPressを追加する手順
- `docs/manual-wordpress-fleet-cutover.md`: WordPressをFleet管理から手動運用へ切り替える手順

## 想定フロー

1. Fleet で `catalog-repos/` を適用して、Chart リポジトリを追加します。
2. Fleet で `longhorn-crd/` を適用して、Longhorn CRD を導入します。
3. Fleet で `longhorn/` を適用して、Longhorn 本体を導入します。
4. [docs/manual-harvester-loadbalancer.md](docs/manual-harvester-loadbalancer.md) の手順で
   Harvester 管理クラスタに IPPool を作成します。
5. [docs/manual-wordpress.md](docs/manual-wordpress.md) の手順で Secret を作成した後、
   `scripts/deploy-wordpress.sh` を実行して WordPress を導入します（Fleetでは管理しません）。
   WordPress は自分専用の LoadBalancer Service を持つため、Traefik を LoadBalancer 化する
   必要はありません。

## 補足: MetalLB からの移行について

このクラスタは Rancher 経由で Harvester 上にプロビジョニングされており、
**Harvester Cloud Provider** が組み込まれています。MetalLB と Harvester Cloud Provider は
どちらも `Service type=LoadBalancer` を検知して IP を払い出そうとするため、両方を有効にすると
競合します。そのため本リポジトリでは MetalLB を廃止し、Harvester Cloud Provider の
IPPool 機能に一本化しています。
