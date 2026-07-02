# WordPress (Bitnami Chart) 導入手順

既存WordPressサイトからのデータ移行（リストア）手順は
[manual-wordpress-restore.md](manual-wordpress-restore.md) を参照してください。

**WordPressはFleet(Continuous Delivery)による自動デプロイをやめ、
[scripts/deploy-wordpress.sh](../scripts/deploy-wordpress.sh) による手動デプロイに移行しています。**
Fleet管理下から手動運用へ切り替える一度きりの手順は
[manual-wordpress-fleet-cutover.md](manual-wordpress-fleet-cutover.md) を参照してください。
`wordpress/fleet.yaml` はFleetのバンドル定義としては使われておらず、
`scripts/deploy-wordpress.sh` が読み取るhelm valuesの一次情報源として残しています。

[wordpress/fleet.yaml](../wordpress/fleet.yaml) は Bitnami の `wordpress` Chart を使って、
LoadBalancer 経由で公開する冗長構成の WordPress を導入します。

- Web層: `replicaCount: 2` で2レプリカ構成。`wp-content` は Longhorn の
  ReadWriteMany ボリュームで全レプリカ間で共有します。
- DB層: WordPress Chart にバンドルされた MariaDB を単体構成で使用します
  （冗長化はしていません）。
- 公開: `service.type: LoadBalancer` を指定し、Harvester Cloud Provider の
  IPPool から自動でIPを割り当てます。

前提として、以下が Fleet で導入済みであることが必要です。

- [catalog-repos/fleet.yaml](../catalog-repos/fleet.yaml)（Bitnami リポジトリ登録）
- [longhorn/fleet.yaml](../longhorn/fleet.yaml)（`longhorn` StorageClass、RWX 対応）
- Harvester 管理クラスタ側に、このゲストクラスタ向けの `IPPool` が作成済みであること
  （[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md) 参照）

また、Longhorn の ReadWriteMany（RWX）ボリュームは各ワーカーノードが NFSv4 クライアントとして
マウントする方式のため、**全ノードに `nfs-common` パッケージのインストールが必要**です。
Ubuntu の Cloud Image（`noble-server-cloudimg` 等）には標準で含まれていないため、
未導入だと以下のような `MountVolume.MountDevice failed` / `bad option` エラーで
Pod が起動しません。

```bash
for ip in $(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'); do
  echo "=== $ip ==="
  ssh ubuntu@"$ip" "sudo apt-get update -qq && sudo apt-get install -y nfs-common"
done
```

Harvester のマシンプール経由でプロビジョニングされたノードは、スケールやノード入れ替えで
再作成されると手動インストールが失われます。恒久対応として、Harvester のデフォルト
cloud-init（`packages:` リスト）に `nfs-common` を追加し、新規ノードにも自動的に
インストールされるようにしてください（この変更は本リポジトリの管理範囲外で、
Harvester/Rancher 側の設定になります）。

```yaml
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
  - nfs-common
runcmd:
  - - systemctl
    - enable
    - '--now'
    - qemu-guest-agent.service
```

## 1. 認証情報の Secret を事前に作成する

パスワードを Git 管理下に置かないため、Fleet が Chart を適用する前に
`wordpress` Namespace へ Secret を手動で作成します。

```bash
kubectl create namespace wordpress

# WordPress管理者パスワード
kubectl -n wordpress create secret generic wordpress-credentials \
  --from-literal=wordpress-password='<管理者用の強いパスワード>'

# MariaDB (root / bn_wordpress ユーザー) パスワード
kubectl -n wordpress create secret generic wordpress-mariadb-credentials \
  --from-literal=mariadb-root-password='<root用の強いパスワード>' \
  --from-literal=mariadb-password='<bn_wordpress用の強いパスワード>'
```

Bitnamiの`mariadb`サブチャートは、`auth.existingSecret`を使っていても
**Helmアップグレード時**（インストール時は問題ない）に
`auth.rootPassword`/`auth.password`の明示指定を要求してくることがあります
（`PASSWORDS ERROR: You must provide your current passwords when upgrading the release`）。
これを避けるため、上記と同じ値を持つ、Helm values形式のSecretも作成しておきます
（`wordpress/fleet.yaml`の`helm.valuesFrom`から参照されます）。

```bash
ROOTPW=$(kubectl -n wordpress get secret wordpress-mariadb-credentials -o jsonpath='{.data.mariadb-root-password}' | base64 -d)
BNPW=$(kubectl -n wordpress get secret wordpress-mariadb-credentials -o jsonpath='{.data.mariadb-password}' | base64 -d)

cat <<EOF > /tmp/mariadb-upgrade-values.yaml
mariadb:
  auth:
    rootPassword: "$ROOTPW"
    password: "$BNPW"
EOF

kubectl -n wordpress create secret generic wordpress-mariadb-upgrade-values \
  --from-file=values.yaml=/tmp/mariadb-upgrade-values.yaml

rm /tmp/mariadb-upgrade-values.yaml
```

このSecretは`wordpress-mariadb-credentials`のパスワードをそのままコピーしただけのものです。
そのため、`wordpress-mariadb-credentials`のパスワードをローテーションした場合は
こちらも同じ内容で更新する必要があります（更新し忘れると次回のFleetアップグレード時に
同じ`PASSWORDS ERROR`が再発します）。

## 2. デプロイスクリプトを実行する

`kubectl`/`helm` が対象クラスタを指すよう設定した状態で、以下を実行します。

```bash
cd ibid-fleet-config
./scripts/deploy-wordpress.sh
```

`wordpress/fleet.yaml` の `helm.chart`/`helm.version`/`helm.values` を読み取り、
`helm upgrade --install` でデプロイします（初回導入・以後のアップグレードいずれも同じコマンドです）。
`wordpress/fleet.yaml` を編集した場合も、変更を反映するには本スクリプトを再実行してください
（Fleetは`wordpress`を追跡していないため、Git pushだけでは反映されません）。

## 3. 割り当てられた外部IPを確認する

Fleet がインストールする Helm リリース名は GitRepo の設定に依存するため、
Service 名は `wordpress` そのままとは限りません（例: `base-infra-wordpress`）。
まず実際の Service 名を確認してから見てください。

```bash
kubectl -n wordpress get svc
```

`TYPE=LoadBalancer` かつ `EXTERNAL-IP` に Harvester の IPPool 範囲内の
アドレスが割り当てられていることを確認します。IP が割り当てられない場合は
`kubectl -n wordpress describe svc <service名>` のイベントを確認し、
[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md) の IPPool 設定を見直してください。

## 4. Pod とストレージの状態を確認する

```bash
kubectl -n wordpress get pods
kubectl -n wordpress get pvc
```

- `wordpress` の PVC が `ReadWriteMany` で `Bound` になっていること
- 2つの `wordpress` Pod がいずれも `Running` になっていること
- Longhorn の Share Manager Pod が `longhorn-system` Namespace に起動していること
  （RWX ボリュームのため）

```bash
kubectl -n longhorn-system get pods -l app=longhorn-share-manager
```

## 補足

- MariaDB は単体構成のため、DB Pod自体は冗長化されていません。DB層まで冗長化したい
  場合は `bitnami/mariadb-galera` 等への切り替えを別途検討してください。
- Longhorn の ReadWriteMany ボリュームは内部的に NFS (Share Manager) を経由するため、
  通常の ReadWriteOnce ボリュームよりレイテンシが増える点に留意してください。
- WordPress の Chart バージョンは [wordpress/fleet.yaml](../wordpress/fleet.yaml) で
  明示的に固定しています。アップグレード時はバージョンを更新してください。
- 現状は次の項目を明示的に設定せず、Chart のデフォルト値のまま導入しています。
  必要になった際は `wordpress/fleet.yaml` の `helm.values` に追記してください。
  - `wordpressScheme` / `ingress.*`: 現在は LB の IP に `http` で直接アクセスする構成。
    ドメイン名でのアクセスや TLS 化をする場合は `ingress.enabled: true` と
    `ingress.hostname`、`wordpressScheme: https` を設定し、DNS でそのホスト名を
    LB の IP（または Traefik 経由）に向ける必要があります。
  - `wordpressBlogName` / `wordpressFirstName` / `wordpressLastName`:
    サイトタイトルや管理者氏名。未設定の場合は導入後に `wp-admin` の管理画面から
    変更できます。
  - `smtpHost` / `smtpPort` / `smtpProtocol` などの SMTP 設定:
    未設定だとパスワードリセット等の通知メールが送信されません。必要になったら
    SMTP サーバー情報を追加してください（認証情報は Secret 化を推奨します）。
