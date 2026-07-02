# WordPress を追加サイトとして導入する手順(2サイト目以降)

最初のWordPressサイト(`wordpress/`)の導入・運用は[manual-wordpress.md](manual-wordpress.md)を
参照してください。本ドキュメントは、同じクラスター内に**別のWordPressサイトを追加**する場合の
手順です。

サイトごとに独立したnamespace・Helmリリース・Secret・`fleet.yaml`を持つため、他のサイトの
稼働中データに影響を与えずに追加・削除できます。サイト名は3文字程度の短い英数字
(例: `web`)を想定しています。以降、サイト名を`<site>`と表記します。

前提として、以下が導入済みであることが必要です([manual-wordpress.md](manual-wordpress.md)参照)。

- [catalog-repos/fleet.yaml](../catalog-repos/fleet.yaml)（Bitnami リポジトリ登録）
- [longhorn/fleet.yaml](../longhorn/fleet.yaml)（`longhorn` StorageClass、RWX 対応）
- Harvester 管理クラスタ側の `IPPool`（[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)参照）
- 全ワーカーノードへの `nfs-common` インストール（[manual-wordpress.md](manual-wordpress.md)参照）

## 1. ディレクトリをテンプレートから生成する

```bash
cd ibid-fleet-config
./scripts/new-wordpress-site.sh <site>
# 例: ./scripts/new-wordpress-site.sh web
```

`wordpress-<site>/fleet.yaml` が生成されます。namespace・リリース名・Secret名は
`wordpress-<site>`という命名規則で統一されます。チャートバージョンや
`replicaCount`、ボリュームサイズなど、サイト固有の要件があれば生成後にこのファイルを
編集してください（[wordpress/fleet.yaml](../wordpress/fleet.yaml)と同様、Fleetバンドルとしては
使わず、`scripts/deploy-wordpress.sh`が読み取る一次情報源として扱います）。

## 2. 認証情報の Secret を事前に作成する

```bash
SITE=web  # 実際のサイト名に置き換える

kubectl create namespace "wordpress-$SITE"

# WordPress管理者パスワード
kubectl -n "wordpress-$SITE" create secret generic "wordpress-$SITE-credentials" \
  --from-literal=wordpress-password='<管理者用の強いパスワード>'

# MariaDB (root / bn_wordpress ユーザー) パスワード
kubectl -n "wordpress-$SITE" create secret generic "wordpress-$SITE-mariadb-credentials" \
  --from-literal=mariadb-root-password='<root用の強いパスワード>' \
  --from-literal=mariadb-password='<bn_wordpress用の強いパスワード>'
```

Bitnamiの`mariadb`サブチャートは、`auth.existingSecret`を使っていても
**Helmアップグレード時**に`auth.rootPassword`/`auth.password`の明示指定を要求してくることが
あるため（`PASSWORDS ERROR`）、同じ値を持つHelm values形式のSecretも作成します
（`wordpress-<site>/fleet.yaml`の`helm.valuesFrom`から参照されます）。

```bash
ROOTPW=$(kubectl -n "wordpress-$SITE" get secret "wordpress-$SITE-mariadb-credentials" -o jsonpath='{.data.mariadb-root-password}' | base64 -d)
BNPW=$(kubectl -n "wordpress-$SITE" get secret "wordpress-$SITE-mariadb-credentials" -o jsonpath='{.data.mariadb-password}' | base64 -d)

cat <<EOF > /tmp/mariadb-upgrade-values.yaml
mariadb:
  auth:
    rootPassword: "$ROOTPW"
    password: "$BNPW"
EOF

kubectl -n "wordpress-$SITE" create secret generic "wordpress-$SITE-mariadb-upgrade-values" \
  --from-file=values.yaml=/tmp/mariadb-upgrade-values.yaml

rm /tmp/mariadb-upgrade-values.yaml
```

このSecretは`wordpress-<site>-mariadb-credentials`のパスワードをそのままコピーしただけの
ものです。パスワードをローテーションした場合は、こちらも同じ内容で更新してください。

## 3. デプロイスクリプトを実行する

`kubectl`/`helm` が対象クラスタを指すよう設定した状態で、第1引数にサイト名を指定して
実行します。

```bash
./scripts/deploy-wordpress.sh web
```

`wordpress-web/fleet.yaml` の `helm.chart`/`helm.version`/`helm.values` を読み取り、
namespace・リリース名とも`wordpress-web`として`helm upgrade --install`でデプロイします
（初回導入・以後のアップグレードいずれも同じコマンドです）。`wordpress-web/fleet.yaml`を
編集した場合も、変更を反映するには本コマンドを再実行してください（Fleetはこのディレクトリを
追跡しないため、Git pushだけでは反映されません）。

## 4. 割り当てられた外部IPを確認する

```bash
kubectl -n wordpress-web get svc
```

`TYPE=LoadBalancer` かつ `EXTERNAL-IP` に Harvester の IPPool 範囲内のアドレスが
割り当てられていることを確認します。割り当てられない場合は
[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)を参照してください。

## 5. Pod とストレージの状態を確認する

```bash
kubectl -n wordpress-web get pods
kubectl -n wordpress-web get pvc
```

- `wordpress-web` の PVC が `ReadWriteMany` で `Bound` になっていること
- 2つの `wordpress-web` Pod がいずれも `Running` になっていること

## 補足

- サイトを追加するたびに、[README.md](../README.md)の構成一覧に
  `wordpress-<site>/`のエントリを追記してください。
- サイトを削除する場合は、`helm uninstall wordpress-<site> -n wordpress-<site>`の後、
  必要に応じてPVC・Secret・namespaceを削除し、`wordpress-<site>/`ディレクトリをGitから
  削除してください（データを残したい場合はPVCに`helm.sh/resource-policy: keep`を付けてから
  uninstallしてください。[manual-wordpress-fleet-cutover.md](manual-wordpress-fleet-cutover.md)の
  手順2と同様です）。
- 最初のサイト(`wordpress/`)だけは、Fleetから手動運用への切替の歴史的経緯により
  namespace/リリース名が`wordpress`/`base-infra-wordpress`という例外的な命名になっています
  （[manual-wordpress-fleet-cutover.md](manual-wordpress-fleet-cutover.md)参照）。2サイト目以降は
  本ドキュメントの`wordpress-<site>`命名規則に統一してください。
