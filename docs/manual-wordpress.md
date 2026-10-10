# WordPress (Bitnami Chart) サイト追加手順

各クラスタには複数の独立したWordPressサイトを追加できます。サイトごとに独立した
namespace・Helmリリース・Secretを持つため、他のサイトの稼働中データに影響を与えずに
追加・削除できます。サイト名は3文字程度の短い英数字(例: `web`)を想定しています。
以降、サイト名を`<site>`、環境名(dev / production)を`<env>`と表記します。

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

- Web層: devは1レプリカ、productionは2レプリカ(別ノードへ分散。fleet.yamlの
  `targetCustomizations`)。`wp-content` は外部NFS(StorageClass `nfs-external`、
  NFSサーバー`192.168.1.1`)のReadWriteManyボリュームで全レプリカ間で共有します。
- DB層: WordPress Chart にバンドルされた MariaDB を単体構成で使用します
  (冗長化はしていません)。ボリュームは `harvester` StorageClass です。
- 公開: Traefik Ingress(`<site>.<env>.ibid.lan`、TLSはcert-manager + FreeIPA ACME)。
  Traefikの共有LoadBalancer IPを全サイトで使います(サイトごとのIPは使いません)。
- イメージ: 再現性のためdigestで固定しています(チャートの `values.yaml` 参照)。

上記のwp-content・公開方式は、`scripts/new-wordpress-site.sh`が生成するfleet.yamlで
設定されます(チャートの既定値はLoadBalancer・`longhorn-r1`のまま残っています)。

全サイト共通の設定を変える場合は `charts/ibid-wordpress/values.yaml` を編集し、
`Chart.yaml` のversionを上げてください(マージでGHCRへ公開され、各環境の
`helm.version` を上げることで環境ごとに取り込まれます)。サイト固有の値
(existingSecretの名前、`wordpressTablePrefix` の上書き等)は
`envs/<env>/sites/<site>/fleet.yaml` の `helm.values` に `wordpress:` 配下で書きます。

## 前提

以下が対象クラスタに導入済みであることが必要です。

- `envs/<env>/infra/` の各バンドル(Bitnamiリポジトリ登録、Longhorn、csi-driver-nfs、
  cert-manager、sealed-secrets等)
- TraefikがLoadBalancer化され、IPが付いていること
  ([manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)の「Traefik を LoadBalancer 化する」)

また、全ノードに `nfs-common` パッケージが必要です(`nfs-external`とLonghorn RWXのマウントに
使うため)。未導入だと`MountVolume.MountDevice failed` / `bad option`でPodが起動しません。
ノードのUser Data(cloud-init)に入れてあるので、通常は意識する必要はありません
([manual-multi-env.md](manual-multi-env.md)の「2. クラスタの新規作成」、
User Dataの全文は[manual-node-ntp.md](manual-node-ntp.md)の「恒久対策」)。

## 1. 認証情報のSealedSecretを生成する

サイト専用のSecret(3種)をSealedSecretとして生成し、Gitにコミットします
(平文パスワードはGitに入らず、対象環境のコントローラだけが復号できます)。

```bash
./scripts/seal-site-secrets.sh <env> <site>
# 例: ./scripts/seal-site-secrets.sh dev web
# kubectlコンテキストは環境名から自動選択(dev1/prod1)。
# 異なる場合は KUBE_CONTEXT=<コンテキスト名> を前置して上書きできます。
```

`envs/<env>/secrets/<site>.yaml` が生成されるので、手順2のfleet.yamlと同じPRに
含めてください。マージされると対象環境のSealed Secretsコントローラが復号して
Secretを作成します(手動でのSecret投入は不要)。

パスワードはサイトごと・環境ごとにランダム生成されます(**使い回さないため**。
1サイト・1環境の認証情報が漏れても他に波及しないようにする設計です)。生成された
パスワードはコマンドの最後に標準エラー出力へその場限り表示されるので、必ず控えて
ください(Gitや他の場所には保存されません)。

- 昇格先の環境でも同様に、その環境用のSealedSecretを生成してコミットします
  (封印は環境ごとの鍵で行うため、ファイルの環境間コピーはできません)。
- パスワードをローテーションしたい場合は、対象サイトの3つのSecretと
  `envs/<env>/secrets/<site>.yaml` を削除してから再実行してください(ただし、
  既にPodが起動済みのMariaDBの実際のDBユーザーパスワードは変わらないため、
  DB側のパスワードも合わせて変更しない限り次回適用時に`PASSWORDS ERROR`になります)。
- 旧 `scripts/bootstrap-site-secrets.sh`(クラスタへ直接Secretを作成)は
  Sealed Secretsが使えない緊急時用として残しています。

## 2. サイトのFleetバンドルを生成してPRを作成する

```bash
./scripts/new-wordpress-site.sh <env> <site>
# 例: ./scripts/new-wordpress-site.sh dev web
```

`envs/<env>/sites/<site>/fleet.yaml` が生成されます。namespace・リリース名・Secret名は
`wordpress-<site>`という命名規則で統一されます。必要ならサイト固有の値
(`wordpressTablePrefix` の上書き等)を `helm.values.wordpress` 配下に追記し、
PRを作成してマージしてください。マージされると対象環境のFleetが自動適用します。

サイトは原則devに追加し、production へはActionsの `promote` ワークフロー
(手動起動)が生成する昇格PRで展開します([manual-multi-env.md](manual-multi-env.md)参照)。
昇格先の環境でも手順1と同様に、その環境用のSealedSecretを生成・コミットしておく
必要があります(封印は環境ごとの鍵のため、devのファイルは流用できません)。

## 3. HTTPSで開けることを確認する

DNSは環境ごとのワイルドカード(`*.<env>.ibid.lan`)なので、サイトごとの登録は不要です
([manual-cert-manager-freeipa-acme.md](manual-cert-manager-freeipa-acme.md)の
「サイトホスト名のDNS」)。個別のAレコードは作らないでください(ワイルドカードより優先されます)。

```bash
kubectl --context <dev1|prod1> -n kube-system get svc rke2-traefik   # TraefikのLB IP
kubectl -n wordpress-<site> get ingress,certificate                   # CertificateがReady=True
curl -sI https://<site>.<env>.ibid.lan/                               # HTTP 200(または302)
```

新規インストールで生成された`wp-config.php`の`WP_HOME`/`WP_SITEURL`は、Bitnamiイメージの作りにより
`http://<site>.<env>.ibid.lan//`(スキームがhttp、末尾スラッシュ重複)になります。
**チャート0.6.5以降は、初回起動時のpost-initスクリプトが自動で`https://<site>.<env>.ibid.lan`に
直す**ため手作業は不要です(`charts/ibid-wordpress/values.yaml` の `customPostInitScripts`)。
確認だけ行います(WordPress Podのログに `ibid-fix-wp-home:` の行が出ます)。

```bash
kubectl -n wordpress-<site> exec deploy/wordpress-<site> -c wordpress -- grep -n "WP_HOME\|WP_SITEURL" /bitnami/wordpress/wp-config.php
```

自動の修正が失敗した場合(ログに「元に戻しました」と出る)や、0.6.5より前のチャートのサイトでは、
次の手順で手で直し、OPcacheに古い値が残らないようPodを入れ替えます。ファイルはRWXのwp-content側
ボリューム上にあるため、1つのPodで書き換えれば全レプリカに反映されます。

```bash
H=<site>.<env>.ibid.lan
kubectl -n wordpress-<site> exec deploy/wordpress-<site> -c wordpress -- grep -n "WP_HOME\|WP_SITEURL" /bitnami/wordpress/wp-config.php
kubectl -n wordpress-<site> exec deploy/wordpress-<site> -c wordpress -- sh -c "
  cp -p /bitnami/wordpress/wp-config.php /bitnami/wordpress/wp-config.php.bak-\$(date +%Y%m%d) &&
  sed -i \"s|WP_HOME', 'http://$H//'|WP_HOME', 'https://$H'|; s|WP_SITEURL', 'http://$H//'|WP_SITEURL', 'https://$H'|\" /bitnami/wordpress/wp-config.php &&
  grep -n 'WP_HOME\|WP_SITEURL' /bitnami/wordpress/wp-config.php && php -l /bitnami/wordpress/wp-config.php"
kubectl -n wordpress-<site> rollout restart deploy/wordpress-<site>
```

DBの`home`/`siteurl`は`http://`のままで構いません(wp-config.phpの定数が優先されます)。
readinessProbeは`X-Forwarded-Proto: https`を付けて叩くため(チャート0.6.1以降)、
https化した後もProbeWarningは出ません。

## 4. Pod とストレージの状態を確認する

```bash
kubectl -n wordpress-<site> get pods
kubectl -n wordpress-<site> get pvc
```

- `wordpress-<site>`(wp-content)のPVCが`nfs-external`・`ReadWriteMany`で`Bound`
- `data-wordpress-<site>-mariadb-0`(DB)のPVCが`harvester`で`Bound`
- `wordpress-<site>` Pod(productionは2つ)と`wordpress-<site>-mariadb-0`が`Running`
- プラグイン同期Job(`wordpress-<site>-plugin-sync-*`)が`Complete`

Fleet側の適用状況はRancher UI(Continuous Delivery → Bundles)または
`kubectl --context rancher -n fleet-default get bundles` で確認できます。

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
  dev→production へ昇格できます(動作チェックを経て本番へ、が実現できます)。
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

- productionの`nfs-external`は`reclaimPolicy: Retain`のため、PVCを消してもNFS上の
  `/data/nfs/wordpress/production/wordpress-<site>/`は残ります。不要なら手動で消します。
- DBの`harvester`のPVは、Harvester CSIの既知の問題で`Released`のまま残ることがあります
  ([roadmap.md](roadmap.md)項目8の手順で片付けます)。
- 日次バックアップの`/data/nfs/backup/<env>/wordpress-<site>/`は両環境とも残ります(`nfs-backup`は`Retain`)。
  最後の数日分は念のため残し、不要になったら手動で消します。
- `envs/<env>/secrets/<site>.yaml`も削除します(DNSはワイルドカードなので作業は無い)。

## 補足

- MariaDB は単体構成のため、DB Pod自体は冗長化されていません。DB層まで冗長化したい
  場合は `bitnami/mariadb-galera` 等への切り替えを別途検討してください。
- wp-contentはNFS上にあるため、ファイル数の多い操作はローカルディスクより遅くなります。
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
  - `wordpressBlogName` / `wordpressFirstName` / `wordpressLastName`:
    サイトタイトルや管理者氏名。未設定の場合は導入後に `wp-admin` の管理画面から
    変更できます。
  - `smtpHost` / `smtpPort` / `smtpProtocol` などの SMTP 設定:
    未設定だとパスワードリセット等の通知メールが送信されません。必要になったら
    SMTP サーバー情報を追加してください(認証情報は Secret 化を推奨します)。
