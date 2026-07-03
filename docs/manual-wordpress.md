# WordPress (Bitnami Chart) 導入手順

このクラスターには複数の独立したWordPressサイトを追加できます。サイトごとに独立した
namespace・Helmリリース・Secret・`fleet.yaml`（`wordpress-<site>/fleet.yaml`）を持つため、
他のサイトの稼働中データに影響を与えずに追加・削除できます。サイト名は3文字程度の短い
英数字（例: `web`）を想定しています。以降、サイト名を`<site>`と表記します。

**WordPressはFleet(Continuous Delivery)による自動デプロイの対象外で、
[scripts/deploy-wordpress.sh](../scripts/deploy-wordpress.sh) による手動デプロイのみで
運用します。** `wordpress-<site>/fleet.yaml` はFleetのバンドル定義としては使われておらず、
`scripts/deploy-wordpress.sh` が読み取るhelm valuesの一次情報源として存在します。

`wordpress-<site>/fleet.yaml` は Bitnami の `wordpress` Chart を使って、LoadBalancer 経由で
公開する冗長構成の WordPress を導入します。

- Web層: `replicaCount: 2` で2レプリカ構成。`wp-content` は Longhorn の
  ReadWriteMany ボリュームで全レプリカ間で共有します。
- DB層: WordPress Chart にバンドルされた MariaDB を単体構成で使用します
  （冗長化はしていません）。
- 公開: `service.type: LoadBalancer` を指定し、Harvester Cloud Provider の
  IPPool から自動でIPを割り当てます。

`replicaCount`・`service.type`・`persistence.*`・`mariadb.*`のデフォルト値など全サイト共通の
設定は[wordpress-base-values.yaml](../wordpress-base-values.yaml)にまとめてあり、
`scripts/deploy-wordpress.sh`が各サイトの`fleet.yaml`より先に読み込みます。各サイトの
`fleet.yaml`にはSecret名などサイト固有の差分だけを書きます。全サイト共通の設定を変える場合は
`wordpress-base-values.yaml`を、そのサイトだけの設定を変える場合はそのサイトの`fleet.yaml`を
編集してください。

前提として、以下が Fleet で導入済みであることが必要です。

- [catalog-repos/fleet.yaml](../catalog-repos/fleet.yaml)（Bitnami リポジトリ登録）
- [longhorn/fleet.yaml](../longhorn/fleet.yaml)（`longhorn` StorageClass、RWX 対応）
- Harvester 管理クラスタ側に、このゲストクラスタ向けの `IPPool` が作成済みであること
  （[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md) 参照）

また、Longhorn の ReadWriteMany（RWX）ボリュームは各ワーカーノードが NFSv4 クライアントとして
マウントする方式のため、**全ノードに `nfs-common` パッケージのインストールが必要**です
（クラスター全体で一度だけ対応すればよく、サイトごとに繰り返す必要はありません）。
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

## 1. ディレクトリをテンプレートから生成する

```bash
cd ibid-fleet-config
./scripts/new-wordpress-site.sh <site>
# 例: ./scripts/new-wordpress-site.sh web
```

`wordpress-<site>/fleet.yaml` が生成されます。namespace・リリース名・Secret名は
`wordpress-<site>`という命名規則で統一されます。

## 2. デプロイスクリプトを実行する

`kubectl`/`helm` が対象クラスタを指すよう設定した状態で、第1引数にサイト名を指定して
実行します。

```bash
./scripts/deploy-wordpress.sh web
```

[wordpress-base-values.yaml](../wordpress-base-values.yaml)（全サイト共通の値）と
`wordpress-web/fleet.yaml`の`helm.chart`/`helm.version`/`helm.values`（このサイト固有の差分）を
読み取り、namespace・リリース名とも`wordpress-web`として`helm upgrade --install`でデプロイします
（初回導入・以後のアップグレードいずれも同じコマンドです）。`wordpress-web/fleet.yaml`を
編集した場合も、変更を反映するには本コマンドを再実行してください（Fleetはこのディレクトリを
追跡しないため、Git pushだけでは反映されません）。

このサイトの認証情報Secret（`wordpress-<site>-credentials`・`wordpress-<site>-mariadb-credentials`・
`wordpress-<site>-mariadb-upgrade-values`）が1つも存在しない場合、本コマンドは初回デプロイと
みなし、サイト専用のランダムなパスワードを自動生成してからSecretを作成します（**全サイトで
パスワードを使い回さないため**。1サイトの認証情報が漏れても他サイトに波及しないようにする
設計です）。生成したパスワードは`helm upgrade --install`の実行後、コマンドの最後に標準エラー
出力へその場限り表示されるので、実行結果から必ず控えてください（Gitや他の場所には保存されません）。

```
生成したパスワード('wordpress-web'。ここにしか表示されないので必ず控えてください):
  WordPress管理者(admin)パスワード:      ...
  MariaDB rootパスワード:               ...
  MariaDB bn_wordpressユーザーパスワード: ...
```

パスワードをローテーションしたい場合は、対象サイトの3つのSecretを削除してから本コマンドを
再実行してください（新しいランダムパスワードで作り直されます。ただし、既にPodが起動済みの
MariaDBの実際のDBユーザーパスワードは変わらないため、DB側のパスワードも合わせて変更しない限り
次回デプロイ時に`PASSWORDS ERROR`になります）。

## 3. 割り当てられた外部IPを確認する

```bash
kubectl -n wordpress-web get svc
```

`TYPE=LoadBalancer` かつ `EXTERNAL-IP` に Harvester の IPPool 範囲内のアドレスが
割り当てられていることを確認します。IP が割り当てられない場合は
`kubectl -n wordpress-web describe svc <service名>` のイベントを確認し、
[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md) の IPPool 設定を見直してください。

## 4. Pod とストレージの状態を確認する

```bash
kubectl -n wordpress-web get pods
kubectl -n wordpress-web get pvc
```

- `wordpress-web` の PVC が `ReadWriteMany` で `Bound` になっていること
- 2つの `wordpress-web` Pod がいずれも `Running` になっていること
- Longhorn の Share Manager Pod が `longhorn-system` Namespace に起動していること
  （RWX ボリュームのため）

```bash
kubectl -n longhorn-system get pods -l app=longhorn-share-manager
```

## サイトを削除する場合

`helm uninstall wordpress-<site> -n wordpress-<site>`の後、必要に応じてPVC・Secret・
namespaceを削除し、`wordpress-<site>/`ディレクトリをGitから削除してください
（データを残したい場合は、PVCに`helm.sh/resource-policy: keep`を付けてからuninstallして
ください）。サイトを追加・削除するたびに、[README.md](../README.md)の構成一覧を更新して
ください。

## 補足

- MariaDB は単体構成のため、DB Pod自体は冗長化されていません。DB層まで冗長化したい
  場合は `bitnami/mariadb-galera` 等への切り替えを別途検討してください。
- Longhorn の ReadWriteMany ボリュームは内部的に NFS (Share Manager) を経由するため、
  通常の ReadWriteOnce ボリュームよりレイテンシが増える点に留意してください。
- WordPress の Chart バージョンは各サイトの`fleet.yaml`で明示的に固定しています。
  アップグレード時はバージョンを更新してください。
- `wp-config.php`は一度生成されると永続ボリューム上に残り続け、Bitnamiの初期化スクリプトは
  「既にファイルがあれば再生成しない」ため、`wordpressTablePrefix`などの初回インストール時
  設定は、インストール後に変更しても反映されません。変更したい場合はWordPress/MariaDBの
  PVCを削除してクリーンな状態から作り直す必要があります。
- **`WORDPRESS_TABLE_PREFIX`を`extraEnvVars`で設定してはいけません。** チャートは
  `wordpressTablePrefix`から同名の環境変数を自動生成するため、`extraEnvVars`で重複指定すると
  `duplicate entries for key [name="WORDPRESS_TABLE_PREFIX"]`でFleet/helmの適用がエラーに
  なります。`wordpressTablePrefix`のみを使用してください。
- 現状は次の項目を明示的に設定せず、Chart のデフォルト値のまま導入しています。
  必要になった際は各サイトの`fleet.yaml`の`helm.values`に追記してください。
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
