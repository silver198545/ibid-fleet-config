# WordPress 既存サイトからのデータ移行（リストア）手順

[docs/manual-wordpress.md](manual-wordpress.md)の手順で導入済みのWordPressサイト
（`wordpress-<site>/fleet.yaml`）に、既存の（別環境の）WordPressサイトからバックアップした
データを流し込む手順です。以降、対象サイト名を`<site>`と表記します（例: `web`）。

対象とするバックアップ形式は次の2点です。

- DBダンプ（`mysqldump`等で取得した素のSQLファイル）
- サイトルート一式のtar/zip（`wp-content`ディレクトリを含むもの）

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

## 1. 復元前にLonghornでスナップショットを取る

DBとwp-contentを丸ごと上書きするため、`wordpress-<site>`名前空間の各PVC
（wp-content用のRWXボリューム、mariadb用のRWOボリューム）についてLonghorn UIで
スナップショットを1つ取ってから進めてください。失敗しても切り戻せます。

## 2. 新環境のテーブル接頭辞を確認し、必要なら合わせる

```bash
kubectl -n "wordpress-$SITE" get pods
kubectl -n "wordpress-$SITE" exec <wordpress-pod> -- grep table_prefix /bitnami/wordpress/wp-config.php
```

このクラスタのデフォルトは`tp_`です（[wordpress-base-values.yaml](../wordpress-base-values.yaml)
参照。Bitnamiチャート自体のデフォルトは`wp_`ですが、全サイト共通で`tp_`に上書きしています）。
旧サイトの接頭辞がこれと異なる場合、`wordpress-<site>/fleet.yaml` の `helm.values` に
`wordpressTablePrefix` を設定して上書きします。

```yaml
    wordpressTablePrefix: "旧サイトの接頭辞"
```

**注意:** 環境変数を直接追加したい場合でも `extraEnvVars` で
`WORDPRESS_TABLE_PREFIX` を指定してはいけません。このチャートには同名の
環境変数を生成する専用パラメータ（`wordpressTablePrefix`）が既にあるため、
`extraEnvVars`と二重に定義すると
`duplicate entries for key [name="WORDPRESS_TABLE_PREFIX"]` で
`scripts/deploy-wordpress.sh`の適用がエラーになります。

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

# scripts/deploy-wordpress.shを再実行してPVCを作り直し、mariadb起動後にwordpressを起動する
# (helm upgrade --installがチャートのテンプレートからPVCを再作成する)
./scripts/deploy-wordpress.sh "$SITE"
```

wp-content用のPVC（Deploymentが参照する単独PVCリソース）は、削除しても
StatefulSetのvolumeClaimTemplateのようには自動再作成されません。
`0/5 nodes are available: persistentvolumeclaim "..." not found` のようなエラーで
Podがスケジュールされない場合は、`scripts/deploy-wordpress.sh <site>`を再実行してPVCを
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

## 7. 動作確認

- サイトのトップページが表示されるか
- パーマリンク付きの個別ページが404にならないか
  （`WORDPRESS_ENABLE_HTACCESS_PERSISTENCE: no` の構成のため、
  `.htaccess`はApache起動のたびに再生成される点に注意）
- `/wp-admin/` に旧環境の管理者アカウントでログインできるか
- メディア（`wp-content/uploads`）が表示されるか
- プラグイン一覧でエラー表示がないか
  （旧WPコアバージョンとBitnamiが提供する新コアの差異で非互換警告が出ることがある）

## トラブルシューティング

- **`PASSWORDS ERROR: You must provide your current passwords when upgrading the release`**
  → `wordpress-<site>-mariadb-upgrade-values` Secretの内容が、実際にDBへ設定されている
  パスワードと一致しているか確認してください（[manual-wordpress.md](manual-wordpress.md)参照）。
- **`duplicate entries for key [name="WORDPRESS_TABLE_PREFIX"]`**
  → `extraEnvVars`ではなく`wordpressTablePrefix`を使ってください（2.参照）。
- **`wp-config.php`削除後に`CrashLoopBackOff`になる**
  → 2.の「PVCごと作り直す」方法に切り替えてください。
- **PVC削除後に`persistentvolumeclaim "..." not found`でPodがスケジュールされない**
  → `scripts/deploy-wordpress.sh <site>`を再実行してPVCをチャートに作り直させてください。
