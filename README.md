# ibid-fleet-config

## 構成

- `catalog-repos/`: Rancher のカタログリポジトリ定義（Bitnami）
- `longhorn-crd/`: Rancher Charts から Longhorn CRD を導入する Fleet バンドル
- `longhorn/`: Rancher Charts から Longhorn 本体を導入する Fleet バンドル
- `wordpress/`: Bitnami の WordPress Chart を LoadBalancer 冗長構成で導入する Fleet バンドル
- `docs/manual-harvester-loadbalancer.md`: Harvester Cloud Provider の IPPool 作成手順
  （MetalLB は廃止し、Harvester Cloud Provider に一本化）
- `docs/manual-wordpress.md`: WordPress 導入前の Secret 作成など手動手順書

## 想定フロー

1. Fleet で `catalog-repos/` を適用して、Chart リポジトリを追加します。
2. Fleet で `longhorn-crd/` を適用して、Longhorn CRD を導入します。
3. Fleet で `longhorn/` を適用して、Longhorn 本体を導入します。
4. [docs/manual-harvester-loadbalancer.md](docs/manual-harvester-loadbalancer.md) の手順で
   Harvester 管理クラスタに IPPool を作成します。
5. [docs/manual-wordpress.md](docs/manual-wordpress.md) の手順で Secret を作成した後、
   Fleet で `wordpress/` を適用して WordPress を導入します。WordPress は自分専用の
   LoadBalancer Service を持つため、Traefik を LoadBalancer 化する必要はありません。

## 補足: MetalLB からの移行について

このクラスタは Rancher 経由で Harvester 上にプロビジョニングされており、
**Harvester Cloud Provider** が組み込まれています。MetalLB と Harvester Cloud Provider は
どちらも `Service type=LoadBalancer` を検知して IP を払い出そうとするため、両方を有効にすると
競合します。そのため本リポジトリでは MetalLB を廃止し、Harvester Cloud Provider の
IPPool 機能に一本化しています。
