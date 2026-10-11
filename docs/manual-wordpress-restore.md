# WordPress 既存サイトからのデータ移行（リストア）手順

[docs/manual-wordpress.md](manual-wordpress.md)の手順で導入済みのWordPressサイト
（`envs/<env>/sites/<site>/fleet.yaml`）に、既存の（別環境の）WordPressサイトからバックアップした
データを流し込む手順です。以降、対象サイト名を`<site>`、環境名を`<env>`と表記します（例: `web`）。

対象とするバックアップ形式は次の2点です。

- DBダンプ（`mysqldump`等で取得した素のSQLファイル）
- サイトルート一式のtar/zip（`wp-content`ディレクトリを含むもの）

## スクリプトによる自動化

バックアップが次のlzop圧縮形式で揃っている場合は、
[scripts/restore-wordpress.sh](../scripts/restore-wordpress.sh)で
手順0（事前確認）と手順3〜5（転送・wp-content復元・DB復元）を自動実行できます。

```
<バックアップ元サイト名>/yyyymmdd_hhmm.tar.lzo   # サイトルート一式(wp-content以外も含む)
<バックアップ元サイト名>/yyyymmdd_hhmm.dump.lzo  # mysqldumpのプレーンSQL
```

```bash
# kubectlが対象環境のクラスタを指していることを確認してから実行する。
# タイムスタンプを省略すると最新のペアを使う。
scripts/restore-wordpress.sh <site> <バックアップディレクトリ> [yyyymmdd_hhmm]
```

tar.lzoにはWordPress本体などwp-content以外のファイルも含まれますが、スクリプトは
`wp-content`ディレクトリだけを取り出して復元します（本体はコンテナイメージ側のものを
使うため）。テーブル接頭辞の食い違いを検出した場合はエラーで中断するので、手順2に従って
接頭辞を合わせてから再実行してください。

転送は`kubectl exec`の1本の長いストリームではなく、圧縮＋分割（既定32MBチャンク、
チャンクごとに検証・再試行）で行います（Rancherプロキシ経由の長いストリームが
i/oタイムアウトで切断される事象への対策）。それでも転送に失敗する場合は
`RESTORE_CHUNK_SIZE=8m`のようにチャンクを小さくして再実行してください。
転送が完了するまで既存のwp-content/DBには手を付けないため、転送中の失敗では
サイトは元のまま残ります。**手順1（復元先の現状のバックアップ）は自動化
されないため、実行前に必ず取得してください。** 手順6（URL置換）と手順7（動作確認）も
スクリプト終了時に表示される案内に従って手動で行います。

以降の各手順は、スクリプトが内部で行っている処理の説明を兼ねた手動手順です。
上記以外の形式のバックアップや、途中で失敗した場合の個別リカバリに使ってください。

## 日次バックアップ（サイト自身のCronJob）

チャート0.6.0以降、各サイトにはDBダンプとwp-contentのtarを毎日取るCronJob
`wordpress-<site>-backup`（JST 3:00、14日分保持）があります。出力はNFS上の

```
192.168.1.1:/data/nfs/backup/<env>/wordpress-<site>/yyyymmdd_hhmm.dump.gz
192.168.1.1:/data/nfs/backup/<env>/wordpress-<site>/yyyymmdd_hhmm.tar.gz   # wp-contentのみ
```

で、上記の`scripts/restore-wordpress.sh`でそのまま戻せます。ディレクトリはnamespace名だけで
決まるので、PVCやクラスタを作り直しても同じ場所のバックアップが見えます。

**今すぐ1つ取る**（本番反映前、リストア前など）:

```bash
kubectl --context <dev1|prod1> -n wordpress-<site> create job --from=cronjob/wordpress-<site>-backup \
  wordpress-<site>-backup-manual-$(date +%Y%m%d%H%M)
kubectl --context <dev1|prod1> -n wordpress-<site> logs -f job/wordpress-<site>-backup-manual-<上の時刻>
```

**作業端末から読む**: NFSを読み取り専用でマウントし、ディレクトリをそのままスクリプトに渡します
（作業端末に`nfs-common`が必要）。

```bash
sudo mkdir -p /mnt/ibid-nfs
sudo mount -t nfs -o ro,nfsvers=4.1 192.168.1.1:/data/nfs /mnt/ibid-nfs
ls -l /mnt/ibid-nfs/backup/production/wordpress-<site>/
scripts/restore-wordpress.sh <site> /mnt/ibid-nfs/backup/production/wordpress-<site> [yyyymmdd_hhmm]
sudo umount /mnt/ibid-nfs
```

## 0. 事前確認（バックアップ側）

復元先の環境と食い違うと詰まるポイントが2つあるので、作業前に確認しておきます。

```bash
# ダンプがプレーンなSQLか確認（"-- MySQL dump" 等で始まるか）
head -c 200 backup.dump

# 旧サイトのテーブル接頭辞を確認
grep table_prefix wp-config.php
```

- ダンプがプレーンSQLでない（バイナリ形式等）場合は別途変換が必要です。
- ダンプに `CREATE DATABASE` / `USE `旧db名`;` のような行が入っていると、
  インポート時に意図しないデータベースに書き込まれるので、入っていれば取り除いてください。

```bash
grep -n '^CREATE DATABASE\|^USE `' backup.dump
```

## 1. 復元前に、復元先の現状のバックアップを取る

DBとwp-contentを丸ごと上書きするため、復元先サイトの現状をバックアップしてから進めてください。
wp-content（`nfs-external`）とDB（`harvester`）はゲストLonghorn上に無いため、Longhorn UIの
スナップショットは使えません。上記「日次バックアップ」の「今すぐ1つ取る」で取ります
（CronJobの無い古いチャートのサイトでは、[operations-flow.md](operations-flow.md)
「本番データリハーサル」1.の手動の方法）。`scripts/restore-wordpress.sh`でそのまま戻せるので、
失敗しても切り戻せます。
新規の空サイトへ復元する場合は不要です（スクリプトの確認プロンプトには`y`で答える）。

## 2. 新環境のテーブル接頭辞を確認し、必要なら合わせる

```bash
kubectl -n "wordpress-$SITE" get pods
kubectl -n "wordpress-$SITE" exec <wordpress-pod> -- grep table_prefix /bitnami/wordpress/wp-config.php
```

このクラスタのデフォルトは`tp_`です（[charts/ibid-wordpress/values.yaml](../charts/ibid-wordpress/values.yaml)
参照。Bitnamiチャート自体のデフォルトは`wp_`ですが、全サイト共通で`tp_`に上書きしています）。
旧サイトの接頭辞がこれと異なる場合、`envs/<env>/sites/<site>/fleet.yaml` の `helm.values` に
`wordpress:` 配下で `wordpressTablePrefix` を設定して上書きします。

```yaml
  values:
    wordpress:
      wordpressTablePrefix: "旧サイトの接頭辞"
```

**注意:** 環境変数を直接追加したい場合でも `extraEnvVars` で
`WORDPRESS_TABLE_PREFIX` を指定してはいけません。このチャートには同名の
環境変数を生成する専用パラメータ（`wordpressTablePrefix`）が既にあるため、
`extraEnvVars`と二重に定義すると
`duplicate entries for key [name="WORDPRESS_TABLE_PREFIX"]` で
helmの適用がエラーになります。

また、`wp-config.php` は一度生成されると永続ボリューム上に残り続け、
Bitnamiの初期化スクリプトは「既にファイルがあれば再生成しない」ため、
**インストール済みの環境で後から`wordpressTablePrefix`を変更しても反映されません。**
このリストア作業ではどのみちDBとwp-contentを丸ごと差し替えるため、
最も確実なのは対象の2つのPVCを削除してクリーンな状態から作り直すことです
（中途半端に`wp-config.php`だけ削除すると、DBには旧接頭辞のテーブルが残ったまま
新接頭辞で初期化しようとして`CrashLoopBackOff`になることがあります）。

```bash
SITE=web  # 実際のサイト名に置き換える

# PVC名を確認
kubectl -n "wordpress-$SITE" get pvc

# スケールダウン
kubectl -n "wordpress-$SITE" scale deploy "wordpress-$SITE" --replicas=0
kubectl -n "wordpress-$SITE" scale statefulset "wordpress-$SITE-mariadb" --replicas=0

# Podが無くなったことを確認してからPVCを削除
kubectl -n "wordpress-$SITE" get pods
kubectl -n "wordpress-$SITE" delete pvc "wordpress-$SITE"
kubectl -n "wordpress-$SITE" delete pvc "data-wordpress-$SITE-mariadb-0"

# デプロイを再実行してPVCを作り直し、mariadb起動後にwordpressを起動する
# (helm upgrade --installがチャートのテンプレートからPVCを再作成する)。
# Rancher UI(Continuous Delivery → 対象バンドルのForce Update)でFleetに再適用させるか、
# break-glassスクリプトで直接適用する:
./scripts/deploy-wordpress.sh <env> "$SITE"
```

wp-content用のPVC（Deploymentが参照する単独PVCリソース）は、削除しても
StatefulSetのvolumeClaimTemplateのようには自動再作成されません。
`0/5 nodes are available: persistentvolumeclaim "..." not found` のようなエラーで
Podがスケジュールされない場合は、`scripts/deploy-wordpress.sh <env> <site>`を再実行してPVCを
チャートに作り直させてください。

再作成後、Podが `Running` になったら接頭辞を再確認します。

```bash
kubectl -n "wordpress-$SITE" exec <新wordpress-pod> -- grep table_prefix /bitnami/wordpress/wp-config.php
```

## 3. バックアップファイルをクラスタに転送する

Rancher UIの操作端末（kubectl shell）を使っている場合、そこにはローカルPCの
ファイルシステムが見えないため、まずアップロードする必要があります。

1. ローカルで `wp-content` ディレクトリだけを固める
   ```bash
   tar czf wp-content.tar.gz -C <展開先> wp-content
   ```
2. Rancher UI右上の `>_`（kubectl shell）を開く
3. ターミナルパネル上部の「Upload File」アイコンから `wp-content.tar.gz` と
   DBダンプファイルをアップロード
4. アップロードされたシェル環境から、以降のコマンドをそのまま実行する

## 4. wp-content の復元

```bash
kubectl -n "wordpress-$SITE" get pods -l app.kubernetes.io/name=wordpress

# 既存(初期状態)のwp-contentを退避してから展開
kubectl -n "wordpress-$SITE" exec <wordpress-pod> -- mv /bitnami/wordpress/wp-content /bitnami/wordpress/wp-content.orig
kubectl -n "wordpress-$SITE" cp wp-content.tar.gz <wordpress-pod>:/tmp/wp-content.tar.gz
kubectl -n "wordpress-$SITE" exec <wordpress-pod> -- tar xzf /tmp/wp-content.tar.gz -C /bitnami/wordpress
kubectl -n "wordpress-$SITE" exec <wordpress-pod> -- rm /tmp/wp-content.tar.gz
```

`kubectl exec`/`cp`はコンテナ内プロセス（Bitnamiの非rootユーザー）権限で実行されるため、
権限修正（chown）は基本不要です。`wp-content`はReadWriteManyの共有ボリュームなので、
1つのPodに反映すれば他のレプリカにも即座に反映されます。

動作確認後、退避した`wp-content.orig`は削除して構いません。

```bash
kubectl -n "wordpress-$SITE" exec <wordpress-pod> -- rm -rf /bitnami/wordpress/wp-content.orig
```

## 5. DBの復元

```bash
kubectl -n "wordpress-$SITE" get pods -l app.kubernetes.io/name=mariadb
ROOTPW=$(kubectl -n "wordpress-$SITE" get secret "wordpress-$SITE-mariadb-credentials" -o jsonpath='{.data.mariadb-root-password}' | base64 -d)

# 初期データを消してクリーンな状態にする
kubectl -n "wordpress-$SITE" exec <mariadb-pod> -- bash -c "mysql -u root -p'$ROOTPW' -e \"DROP DATABASE IF EXISTS bitnami_wordpress; CREATE DATABASE bitnami_wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON bitnami_wordpress.* TO 'bn_wordpress'@'%'; FLUSH PRIVILEGES;\""

# ダンプを転送してインポート
kubectl -n "wordpress-$SITE" cp backup.dump <mariadb-pod>:/tmp/backup.dump
kubectl -n "wordpress-$SITE" exec <mariadb-pod> -- bash -c "mysql -u root -p'$ROOTPW' bitnami_wordpress < /tmp/backup.dump"

# 確認
kubectl -n "wordpress-$SITE" exec <mariadb-pod> -- bash -c "mysql -u root -p'$ROOTPW' bitnami_wordpress -e \"SHOW TABLES;\""

# 後片付け
kubectl -n "wordpress-$SITE" exec <mariadb-pod> -- rm /tmp/backup.dump
```

（`mysql -u root -p'<パスワード>' ... < ファイル` の形は、`kubectl exec`単体では
ローカル側のリダイレクトになってしまうため、`bash -c "..."`でPod内シェルに
リダイレクトごと渡す必要があります。）

## 6. URLの置換

移行元と移行先でドメイン/URLが異なる場合、DB内のURL（`siteurl`/`home`および
本文・メタデータ中のシリアライズ済みリンク）をwp-cliで一括置換します。
Bitnamiのwordpressイメージには`wp`コマンドが同梱されています。

置換前に、DBへ実際に復元されている（=置換で指定すべき「旧ドメイン」の）URLを確認します。
思い込みで指定すると1件もヒットせず気づかないまま次に進んでしまうため、必ずDBの値を直接
確認してから使ってください（`wp option get`はwp-config.phpのDB接続設定を経由するため、
意図した接続先を見ているか分かりにくく、手順5と同様にmariadb Podへ直接SQLを投げます。
テーブル接頭辞`tp_`は手順2で確認した実際の値に読み替えてください）。

```bash
ROOTPW=$(kubectl -n "wordpress-$SITE" get secret "wordpress-$SITE-mariadb-credentials" -o jsonpath='{.data.mariadb-root-password}' | base64 -d)

kubectl -n "wordpress-$SITE" exec <mariadb-pod> -- bash -c "mysql -u root -p'$ROOTPW' bitnami_wordpress -e \"SELECT option_name, option_value FROM tp_options WHERE option_name IN ('siteurl','home');\""
```

```bash
kubectl -n "wordpress-$SITE" exec <wordpress-pod> -- wp search-replace \
  'http://旧ドメイン/パス' 'http://新ドメインまたはLB-IP/パス' --all-tables --precise

kubectl -n "wordpress-$SITE" exec <wordpress-pod> -- wp rewrite flush --hard
```

置換後、同じコマンドをもう一度実行して `Made 0 replacements.` になれば
反映が完了しています。新しいLBのIPは以下で確認できます。

```bash
kubectl -n "wordpress-$SITE" get svc
```

新ドメインでアクセスする場合は、DNS（クラスタ外の管理範囲）で
そのドメインをLBのEXTERNAL-IPに向けてください。動作確認だけなら
ローカルPCの`hosts`ファイルへの一時的な追記でも代用できます。

## 6b. 外部リバースプロキシ（RIKEN側nginx等）経由で公開する場合

サイトは`<site>.<env>.ibid.lan`というホスト名で、Traefik経由の共有LB IPに届く構成になっている
（[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)参照）。これをRIKEN側の
nginx等（別ドメイン、独自のLet's Encrypt証明書）から公開する場合の設定。チャート0.7.1以降は、
Gitで管理する設定（fleet.yaml）と、既存サイトだけに必要な1回限りの手作業に分かれる。

1つのドメインの`/ja`と`/en`を別々のWordPressで運用する（サブパス公開）こともできる。
日本語版を`<site>`、英語版を`<site>-en`という別サイトにし、同じホスト名`<site>.<env>.ibid.lan`の
`/ja`と`/en`に振り分ける（2026-10-11、devのabc/abc-enで導入）。

### 仕組み

外部nginxは、Traefikのルーティング（Ingressのホスト名と照合）のため`Host`を内部名
`<site>.<env>.ibid.lan`に固定して送る。そのままだと、WordPressは内部名でアクセスされたと
みなすので、Hostから組み立てるURL（ログイン後の戻り先`redirect_to`、正規URLへの転送、
フィードの転送）に内部名が出る。また、WP_HOMEを外部ドメインにすると、正規URLへの転送が
無限ループになる。

チャート（`templates/site-path.yaml`）は2つの値でこれを解消する。

| 値 | 書く場所 | 効果 |
|---|---|---|
| `sitePath`（例: `/ja`） | fleet.yamlの共通部分（全環境同じ） | Apacheの`Alias`でこのパスをWordPress本体に割り当てる。パスを外さずに届けるので、WordPressが見るURLと公開URLが一致する |
| `publicHost`（例: `wpdev1.brc.riken.jp`） | fleet.yamlの`targetCustomizations`（環境ごと） | PHPの`auto_prepend_file`で、処理前に`HTTP_HOST`を公開ドメインへ差し替える。リダイレクト類が公開ドメインになり、無限ループも起きない |

新規インストール時の`WP_HOME`/`WP_SITEURL`は`https://<publicHost><sitePath>`になる
（`publicHost`が無ければingressのホスト名）。

以前の方式（`redirect_canonical`を無効にするmu-pluginと、WP_HOMEだけを外部ドメインに固定する方式）は
もう使わない。この方式では、`redirect_to`に内部名が出る問題が残っていた。
**`X-Forwarded-Host`で外部ドメインを伝える方式は機能しない**：TraefikはデフォルトでUpstreamからの
転送ヘッダを信頼せず、自分の値で上書きする。

### Git側: fleet.yaml

サブパスで公開するサイト（例: `envs/dev/sites/abc/fleet.yaml`）:

```yaml
helm:
  values:
    sitePath: /ja            # 英語版(<site>-en)は /en
    wordpress:
      ingress:
        hostname: abc.${ .ClusterLabels.env }.ibid.lan   # <site>-en も同じホスト名
        path: /ja            # sitePath と同じ値
        pathType: Prefix
targetCustomizations:
  - name: dev
    clusterSelector:
      matchLabels:
        env: dev
    helm:
      values:
        publicHost: wpdev1.brc.riken.jp
```

ドメイン直下で公開するサイトは`sitePath`/`path`を書かず、`publicHost`だけを設定する。

英語版の新規作成は、通常の`scripts/new-wordpress-site.sh <env> <site>-en`と
`scripts/seal-site-secrets.sh <env> <site>-en`の後、生成されたfleet.yamlのingressの
`hostname`を`<site>.${ .ClusterLabels.env }.ibid.lan`に直し、上記の値を足す。

**ConfigMapの変更だけではPodは再起動しない。** 既存サイトに`sitePath`/`publicHost`を足したり
変えたりしたときは、Fleetの適用後に再起動する:

```bash
kubectl -n "wordpress-$SITE" rollout restart deploy "wordpress-$SITE"
```

### 外部nginx側の設定

```nginx
server {
    server_name  <公開ドメイン>;
    # (listen / ssl / ヘッダ / allow・deny 等は従来どおり)

    # ドメイン直下は日本語版へ
    location = / {
        return 302 /ja/;
    }

    location / {
        proxy_pass https://<site>.<env>.ibid.lan;   # 末尾に / を付けない(パスをそのまま渡す)

        # SNI送信に必須（Traefikは証明書選択にSNIを使う）
        proxy_ssl_server_name on;
        # FreeIPA内部CA発行の証明書のため、そのままだと検証失敗する
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        # 重要: $host(=公開ドメイン)のままだとTraefikのIngressルール
        # (Host: <site>.<env>.ibid.lan)に一致せず404になる。
        proxy_set_header Host <site>.<env>.ibid.lan;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Apache自身のリダイレクト(例: /ja/wp-admin → /ja/wp-admin/)は内部名で返るため、
        # 公開ドメインに書き換える
        proxy_redirect http://<site>.<env>.ibid.lan/ /;
        proxy_redirect https://<site>.<env>.ibid.lan/ /;
    }
}
```

`/ja`と`/en`は同じホスト名のIngress（パス別）に届くので、nginx側で言語ごとに`location`を
分ける必要はない。`sitePath`も`path`も無いIngressへ届いたパスはTraefikが404を返す。

### WordPress側（既存サイトのみ、1回限り）

既存サイトの`wp-config.php`は永続ボリューム上にあり、作り直されない（2.参照）。このため、
`WP_HOME`/`WP_SITEURL`は手で公開URLに直す。新規サイト（`<site>-en`等）は不要
（初回起動時に自動で入る）。`wp option update siteurl/home`では直らない：wp-config.phpの
`define()`がDBの値より優先される。

```bash
URL=https://<公開ドメイン>/ja    # ドメイン直下なら https://<公開ドメイン>
POD=$(kubectl -n "wordpress-$SITE" get pod -l app.kubernetes.io/name=wordpress -o jsonpath='{.items[0].metadata.name}')

kubectl -n "wordpress-$SITE" exec -c wordpress "$POD" -- sed -i \
  -e "s|define( 'WP_HOME',.*|define( 'WP_HOME', '$URL' );|" \
  -e "s|define( 'WP_SITEURL',.*|define( 'WP_SITEURL', '$URL' );|" \
  /bitnami/wordpress/wp-config.php
kubectl -n "wordpress-$SITE" exec -c wordpress "$POD" -- grep -n "WP_HOME\|WP_SITEURL" /bitnami/wordpress/wp-config.php
```

続けて、本文等に残る旧URLを置換する（6.と同じ`wp search-replace`、guid列は除く）。
例（devのabc、2026-10-11）: 内部名`https://abc.dev.ibid.lan`→`https://wpdev1.brc.riken.jp/ja`、
旧本番ドメイン`https://abc.brc.riken.jp`→`https://wpdev1.brc.riken.jp`（`/ja`・`/en`はそのまま残す）。

```bash
kubectl -n "wordpress-$SITE" exec -c wordpress "$POD" -- \
  wp search-replace '<旧URL>' '<新URL>' --all-tables-with-prefix --skip-columns=guid --dry-run
# 件数を確認してから --dry-run を外して実行し、最後に wp cache flush
```

最後にPodを再起動する（OPcacheが古いwp-config.phpを持っているため）。

```bash
kubectl -n "wordpress-$SITE" rollout restart deploy "wordpress-$SITE"
```

wp-content と同じ共有ボリューム上のファイルなので、レプリカが複数でも1回でよい。
対象PVCを作り直した場合（2.、または別クラスタへのDR復元）はやり直す。

内部名（`https://<site>.<env>.ibid.lan/ja/`）で直接アクセスしても、リンク先は公開ドメインになる。
実運用の正のURLは公開ドメインなので問題ない。

## 7. 動作確認

- サイトのトップページが表示されるか
- パーマリンク付きの個別ページが404にならないか
  （`WORDPRESS_ENABLE_HTACCESS_PERSISTENCE: no` の構成のため、
  `.htaccess`はApache起動のたびに再生成される点に注意）
- `/wp-admin/` に旧環境の管理者アカウントでログインできるか
- メディア（`wp-content/uploads`）が表示されるか
- プラグイン一覧でエラー表示がないか
  （旧WPコアバージョンとBitnamiが提供する新コアの差異で非互換警告が出ることがある）
- 外部リバースプロキシ経由で公開するサイトの場合（6b.参照）、CSS/JS等のアセットURLが
  外部公開ドメイン（サブパス公開なら`/ja`等を含む）を指しているか（`curl -sk https://<site>.<env>.ibid.lan/ | grep -o
  'https://[^"'"'"']*\.css[^"'"'"']*'`で確認可能）

## トラブルシューティング

- **`PASSWORDS ERROR: You must provide your current passwords when upgrading the release`**
  → `wordpress-<site>-mariadb-upgrade-values` Secretの内容が、実際にDBへ設定されている
  パスワードと一致しているか確認してください（[manual-wordpress.md](manual-wordpress.md)参照）。
- **`duplicate entries for key [name="WORDPRESS_TABLE_PREFIX"]`**
  → `extraEnvVars`ではなく`wordpressTablePrefix`を使ってください（2.参照）。
- **`wp-config.php`削除後に`CrashLoopBackOff`になる**
  → 2.の「PVCごと作り直す」方法に切り替えてください。
- **PVC削除後に`persistentvolumeclaim "..." not found`でPodがスケジュールされない**
  → `scripts/deploy-wordpress.sh <env> <site>`を再実行してPVCをチャートに作り直させてください。
- **外部ドメインでアクセスすると404、または内部ホスト名(`*.ibid.lan`)のURLが混ざる**
  → 6b.参照。404なら外部nginxの`proxy_set_header Host`が内部ホスト名に固定されているか
  （サブパス公開ならfleet.yamlの`sitePath`とingressの`path`も）、CSS等のURLが内部名なら
  wp-config.phpのWP_HOME/WP_SITEURL、リダイレクト先が内部名なら`publicHost`と再起動の有無を確認。
- **リストア後、`wp plugin list`がfleet.yamlの`plugins:`と一致しない（一部のプラグインが無効になっている）**
  → プラグイン同期Jobが、リストアのDB作り直しと同時に走ったため（DBが空の間に処理された分が失われる。
  2026-09-04にwebで発生、`Table 'bitnami_wordpress.tp_options' doesn't exist`が多発）。
  `kubectl -n wordpress-<site> delete job -l app.kubernetes.io/component=plugin-sync`で
  Jobを消し、GitRepoの`forceSyncGeneration`を+1すると再実行される。
- **新しく作られた`wp-config.php`の`WP_HOME`/`WP_SITEURL`が`http://<hostname>//`になっている**
  （スキームがhttp、末尾のスラッシュが重複）→ この定数がDBの`siteurl`/`home`より優先されるため、
  `search-replace`では直らない。`wp-config.php`をsedで`https://<hostname>`に書き換える
  （6b.の「wp-config.phpのWP_HOME/WP_SITEURLを固定する」と同じ方法）。
- **WP_HOME/WP_SITEURL固定後、外部ドメインで`ERR_TOO_MANY_REDIRECTS`になる**
  → `publicHost`が未設定か、設定後にPodを再起動していない（6b.「仕組み」参照）。
  以前の回避策（`redirect_canonical`を無効にするmu-plugin）は不要になった。
