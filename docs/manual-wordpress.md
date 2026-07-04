# WordPress (Bitnami Chart) サイト追加手順

各クラスタには複数の独立したWordPressサイトを追加できます。サイトごとに独立した
namespace・Helmリリース・Secretを持つため、他のサイトの稼働中データに影響を与えずに
追加・削除できます。サイト名は3文字程度の短い英数字(例: `web`)を想定しています。
以降、サイト名を`<site>`、環境名(dev / staging / production)を`<env>`と表記します。

既存の(別環境の)WordPressサイトからのデータ移行(リストア)手順は
[manual-wordpress-restore.md](manual-wordpress-restore.md)を参照してください。
マルチ環境全体のセットアップ・昇格運用は [manual-multi-env.md](manual-multi-env.md) を
参照してください。

**WordPressはFleet(Continuous Delivery)で管理します。** サイトの実体は
`envs/<env>/sites/<site>/fleet.yaml` で、mainにマージされると対象環境のFleetが
自動適用します。ただし本番クラスタに届くのは、CODEOWNERSの承認を経てマージされた
変更のみです(mainブランチ保護)。`scripts/deploy-wordpress.sh` による手動デプロイは
緊急用(break-glass)にのみ使います。

構成は全サイト共通で、ラッパーチャート
[../charts/ibid-wordpress/](../charts/ibid-wordpress/)(Bitnami `wordpress` チャートを内包)
がデフォルト値を持ちます:

- Web層: `replicaCount: 2` で2レプリカ構成。`wp-content` は Longhorn の
  ReadWriteMany ボリュームで全レプリカ間で共有します。
- DB層: WordPress Chart にバンドルされた MariaDB を単体構成で使用します
  (冗長化はしていません)。
- 公開: `service.type: LoadBalancer` を指定し、Harvester Cloud Provider の
  IPPool から自動でIPを割り当てます。
- イメージ: 再現性のためdigestで固定しています(チャートの `values.yaml` 参照)。

全サイト共通の設定を変える場合は `charts/ibid-wordpress/values.yaml` を編集し、
`Chart.yaml` のversionを上げてください(マージでGHCRへ公開され、各環境の
`helm.version` を上げることで環境ごとに取り込まれます)。サイト固有の値
(existingSecretの名前、`wordpressTablePrefix` の上書き等)は
`envs/<env>/sites/<site>/fleet.yaml` の `helm.values` に `wordpress:` 配下で書きます。

## 前提

以下が対象クラスタに導入済みであることが必要です。

- `envs/<env>/infra/` の各バンドル(Bitnamiリポジトリ登録、Longhorn。
  `longhorn` StorageClass、RWX 対応)
- Harvester 管理クラスタ側に、このゲストクラスタ向けの `IPPool` が作成済みであること
  ([manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md) 参照)

また、Longhorn の ReadWriteMany(RWX)ボリュームは各ワーカーノードが NFSv4 クライアントとして
マウントする方式のため、**全ノードに `nfs-common` パッケージのインストールが必要**です
(クラスタごとに一度だけ対応すればよく、サイトごとに繰り返す必要はありません)。
Ubuntu の Cloud Image(`noble-server-cloudimg` 等)には標準で含まれていないため、
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
cloud-init(`packages:` リスト)に `nfs-common` を追加し、新規ノードにも自動的に
インストールされるようにしてください(この変更は本リポジトリの管理範囲外で、
Harvester/Rancher 側の設定になります)。

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

## 1. 認証情報のSecretを対象クラスタに作成する

Fleetがサイトを適用する前に、サイト専用のSecret(3種)を対象クラスタへ作成します。
`kubectl` のコンテキストを対象環境のクラスタへ向けてから実行してください。

```bash
kubectl config use-context <対象環境のコンテキスト>
./scripts/bootstrap-site-secrets.sh <site>
```

パスワードはサイトごと・環境ごとにランダム生成されます(**使い回さないため**。
1サイト・1環境の認証情報が漏れても他に波及しないようにする設計です)。生成された
パスワードはコマンドの最後に標準エラー出力へその場限り表示されるので、必ず控えて
ください(Gitや他の場所には保存されません)。

パスワードをローテーションしたい場合は、対象サイトの3つのSecretを削除してから
再実行してください(ただし、既にPodが起動済みのMariaDBの実際のDBユーザーパスワードは
変わらないため、DB側のパスワードも合わせて変更しない限り次回適用時に
`PASSWORDS ERROR`になります)。

## 2. サイトのFleetバンドルを生成してPRを作成する

```bash
./scripts/new-wordpress-site.sh <env> <site>
# 例: ./scripts/new-wordpress-site.sh dev web
```

`envs/<env>/sites/<site>/fleet.yaml` が生成されます。namespace・リリース名・Secret名は
`wordpress-<site>`という命名規則で統一されます。必要ならサイト固有の値
(`wordpressTablePrefix` の上書き等)を `helm.values.wordpress` 配下に追記し、
PRを作成してマージしてください。マージされると対象環境のFleetが自動適用します。

サイトは原則devに追加し、staging / production へはActionsの `promote` ワークフロー
(手動起動)が生成する昇格PRで展開します([manual-multi-env.md](manual-multi-env.md)参照)。
昇格先の環境でも手順1のSecret作成が事前に必要です。

## 3. 割り当てられた外部IPを確認する

```bash
kubectl -n wordpress-<site> get svc
```

`TYPE=LoadBalancer` かつ `EXTERNAL-IP` に Harvester の IPPool 範囲内のアドレスが
割り当てられていることを確認します。IP が割り当てられない場合は
`kubectl -n wordpress-<site> describe svc <service名>` のイベントを確認し、
[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md) の IPPool 設定を見直してください。

## 4. Pod とストレージの状態を確認する

```bash
kubectl -n wordpress-<site> get pods
kubectl -n wordpress-<site> get pvc
```

- `wordpress-<site>` の PVC が `ReadWriteMany` で `Bound` になっていること
- 2つの `wordpress-<site>` Pod がいずれも `Running` になっていること
- Longhorn の Share Manager Pod が `longhorn-system` Namespace に起動していること
  (RWX ボリュームのため)

```bash
kubectl -n longhorn-system get pods -l app=longhorn-share-manager
```

Fleet側の適用状況はRancher UI(Continuous Delivery → Bundles)または
`kubectl --context <rancher-local> -n fleet-default get bundles` で確認できます。

## プラグインの管理(Git駆動)

プラグインは各サイトの `fleet.yaml` の `helm.values.plugins` に宣言します。
チャートのプラグイン同期Job(wp-cli)が、helm適用のたびにインストール
(バージョン固定)と有効化を行います。

```yaml
  values:
    plugins:
      - name: advanced-custom-fields
        version: "6.8.4"        # 再現性のためversion明示を推奨
      - name: classic-editor
        version: "1.7.0"
        # activate: false       # インストールのみで有効化しない場合
    wordpress:
      ...
```

- **プラグインの追加・バージョンアップ = PR** になり、promoteワークフローで
  dev→staging→production へ昇格できます(動作チェックを経て本番へ、が実現できます)。
- **一覧から消しても自動削除はされません**(稼働中サイトの自動削除は危険なため)。
  削除する場合は手動で: `wp plugin deactivate <name> && wp plugin delete <name>`
  (実行方法はJobのログ、または `kubectl exec` でWordPress Podから)。
- 同期Jobのログ: `kubectl -n wordpress-<site> logs job/wordpress-<site>-plugin-sync`
- wp-adminからの手動インストールも引き続き可能ですが、その内容は他環境へ
  昇格されません。恒久的に使うプラグインは必ず `plugins:` に載せてください。

## サイトを削除する場合

`envs/<env>/sites/<site>/` をGitから削除してマージします。各サイトのfleet.yamlは
`keepResources: true` のため、**Fleetはリソースを削除しません**(データを誤って
道連れにしないための設計)。実リソースの後片付けは手動で行います:

```bash
helm uninstall wordpress-<site> -n wordpress-<site>
# データも消してよければ PVC・Secret・namespace を削除
kubectl delete namespace wordpress-<site>
```

データを残したい場合は、PVCに `helm.sh/resource-policy: keep` を付けてから
uninstallしてください。全環境から消す場合は環境ごとに繰り返します。

## 補足

- MariaDB は単体構成のため、DB Pod自体は冗長化されていません。DB層まで冗長化したい
  場合は `bitnami/mariadb-galera` 等への切り替えを別途検討してください。
- Longhorn の ReadWriteMany ボリュームは内部的に NFS (Share Manager) を経由するため、
  通常の ReadWriteOnce ボリュームよりレイテンシが増える点に留意してください。
- チャートのバージョンは各サイトの `fleet.yaml` の `helm.version` で固定されています。
  上げるときはdevから順に昇格させてください。
- `wp-config.php`は一度生成されると永続ボリューム上に残り続け、Bitnamiの初期化スクリプトは
  「既にファイルがあれば再生成しない」ため、`wordpressTablePrefix`などの初回インストール時
  設定は、インストール後に変更しても反映されません。変更したい場合はWordPress/MariaDBの
  PVCを削除してクリーンな状態から作り直す必要があります
  ([manual-wordpress-restore.md](manual-wordpress-restore.md)参照)。
- **`WORDPRESS_TABLE_PREFIX`を`extraEnvVars`で設定してはいけません。** チャートは
  `wordpressTablePrefix`から同名の環境変数を自動生成するため、`extraEnvVars`で重複指定すると
  `duplicate entries for key [name="WORDPRESS_TABLE_PREFIX"]`でhelmの適用がエラーに
  なります。`wordpressTablePrefix`のみを使用してください。
- 現状は次の項目を明示的に設定せず、Chart のデフォルト値のまま導入しています。
  必要になった際は各サイトの`fleet.yaml`の`helm.values.wordpress`に追記してください。
  - `wordpressScheme` / `ingress.*`: 現在は LB の IP に `http` で直接アクセスする構成。
    ドメイン名でのアクセスや TLS 化をする場合は `ingress.enabled: true` と
    `ingress.hostname`、`wordpressScheme: https` を設定し、DNS でそのホスト名を
    LB の IP(または Traefik 経由)に向ける必要があります。
  - `wordpressBlogName` / `wordpressFirstName` / `wordpressLastName`:
    サイトタイトルや管理者氏名。未設定の場合は導入後に `wp-admin` の管理画面から
    変更できます。
  - `smtpHost` / `smtpPort` / `smtpProtocol` などの SMTP 設定:
    未設定だとパスワードリセット等の通知メールが送信されません。必要になったら
    SMTP サーバー情報を追加してください(認証情報は Secret 化を推奨します)。
