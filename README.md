# ibid-fleet-config

## 構成

- `catalog-repos/`: Rancher のカタログリポジトリ定義（Bitnami）
- `longhorn-crd/`: Rancher Charts から Longhorn CRD を導入する Fleet バンドル
- `longhorn/`: Rancher Charts から Longhorn 本体を導入する Fleet バンドル
- `wordpress-<site>/`: サイト固有の設定が全サイト共通のデフォルトから外れる場合にのみ置く、
  そのサイト用の上書きファイル（`fleet.yaml`）。標準的な構成のサイトはこのディレクトリ自体が
  存在しなくてよい（`scripts/deploy-wordpress.sh`が実行時にデフォルト設定を生成する）。
  Fleetバンドルとしては使用していない。`scripts/new-wordpress-site.sh <site>` でひな形を生成する
- `wordpress-base-values.yaml`: 全WordPressサイトに共通するデフォルトのHelm values。
  `scripts/deploy-wordpress.sh`がこれを読み込んでデプロイする
- `scripts/deploy-wordpress.sh`: `wordpress-base-values.yaml`と（あれば）`wordpress-<site>/fleet.yaml`の
  内容をもとに WordPress を手動デプロイするスクリプト（Fleetを介さない）。第1引数にサイト名を
  指定（必須）。`wordpress-<site>/fleet.yaml`が無ければ標準のデフォルト設定をその場で生成して
  使用する。認証情報のSecretが未作成の場合は、サイトごとのランダムパスワードを自動生成して
  作成する（全サイトでパスワードを使い回さないため）
- `scripts/new-wordpress-site.sh`: そのサイト専用の`wordpress-<site>/fleet.yaml`をひな形から
  生成するスクリプト（チャートバージョン個別固定など、デフォルトから外れた設定をGitに残したい
  場合のみ使用。標準構成なら不要）
- `docs/manual-harvester-loadbalancer.md`: Harvester Cloud Provider の IPPool 作成手順
  （MetalLB は廃止し、Harvester Cloud Provider に一本化）
- `docs/manual-wordpress.md`: WordPressサイトを追加する手順（ひな形生成、デプロイスクリプトの実行）
- `docs/manual-wordpress-restore.md`: 既存の別環境WordPressサイトからデータを移行（リストア）する手順

## 想定フロー

1. Fleet で `catalog-repos/` を適用して、Chart リポジトリを追加します。
2. Fleet で `longhorn-crd/` を適用して、Longhorn CRD を導入します。
3. Fleet で `longhorn/` を適用して、Longhorn 本体を導入します。
4. [docs/manual-harvester-loadbalancer.md](docs/manual-harvester-loadbalancer.md) の手順で
   Harvester 管理クラスタに IPPool を作成します。
5. [docs/manual-wordpress.md](docs/manual-wordpress.md) の手順で `scripts/deploy-wordpress.sh <site>`
   を実行して WordPress を導入します（Fleetでは管理しません。認証情報はサイトごとに自動生成
   されます）。サイトを追加するたびにこの手順を繰り返します。WordPress は自分専用の
   LoadBalancer Service を持つため、Traefik を LoadBalancer 化する必要はありません。

## 補足: MetalLB からの移行について

このクラスタは Rancher 経由で Harvester 上にプロビジョニングされており、
**Harvester Cloud Provider** が組み込まれています。MetalLB と Harvester Cloud Provider は
どちらも `Service type=LoadBalancer` を検知して IP を払い出そうとするため、両方を有効にすると
競合します。そのため本リポジトリでは MetalLB を廃止し、Harvester Cloud Provider の
IPPool 機能に一本化しています。
