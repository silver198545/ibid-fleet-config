# 日常運用フロー(変更のテストと昇格)

プラグインの追加・更新、チャート/イメージのバージョンアップといった日常の変更を、
dev → production の2環境でどうテストし、どう本番へ反映するかの運用フロー。

環境そのものの構築・昇格の操作手順は [manual-multi-env.md](manual-multi-env.md)、
サイト管理を他チームへ委譲する際の受付フローは
[wordpress-site-delegation.md](wordpress-site-delegation.md) を参照。

## 各環境の役割

| 環境 | 役割 | コンテンツ |
|---|---|---|
| dev | 全サイトのプラグイン・バージョンアップの**互換性テスト**(インストール・有効化できるか、サイトが壊れないか)。必要に応じて**本番データリハーサル**(下記)も行う | テスト用(本番とは無関係)。リハーサルサイトのみ本番のコピー(一時的) |
| production | dev(とリハーサル)で確認済みの変更の反映のみ。直接の試行錯誤はしない | 本番データ |

以前はdevとproductionの間にstaging環境があり、本番からリストアしたコンテンツで
結合テストをしていた。HWリソース(Harvesterホストのメモリ)の制約から
**2026-10-08にstagingを廃止**し、その役割は「dev1上の一時的なリハーサルサイト」で
代替する(経緯は [roadmap.md](roadmap.md))。

## 基本サイクル: 変更はバッチにまとめて一方向に流す

promoteワークフローは環境ディレクトリを丸ごとコピーするため、
「**devで確認した構成を、一切手を加えずにproductionへ昇格する**」が大原則。

1. **devで変更・互換性テスト**: `envs/dev/` のfleet.yaml(プラグイン一覧、
   `helm.version`)や `charts/`・`images/` を変更するPRを出す。productionに触れないPRは
   `validate` が通れば承認なしでマージできる(auto-merge可)。チャートの変更は
   `scripts/bump-chart.sh`、アプリのイメージ更新は `scripts/update-app-image.sh set-image` が
   devへの反映まで一括で行う([manual-multi-env.md](manual-multi-env.md) 4章)。
   全サイトの表示・管理画面を確認する
2. **本番データリハーサル(DBマイグレーションを伴う変更のとき)**: 下記
   「本番データリハーサル」の手順で、本番のコピーに対して変更を適用して確認する。
   WordPressコア・プラグインのメジャー更新、チャートのMariaDB更新など、
   **DBスキーマを書き換え得る変更では必須**。プラグインの軽微なパッチ更新のみなど
   影響が小さいと判断できる場合は省略してよい(省略した判断は昇格PRに書く)
3. **dev → production 昇格**: promoteワークフロー(手動dispatch、`name`にサイト名か`all`)
   でPRを生成。マージの**直前に必ず本番のバックアップを取得**(下記「本番反映前のバックアップ」)。
   CODEOWNERS承認のうえマージし、反映後に監視(HTTP probe)とサイト表示を確認する
   - `name=all`は**本番に既にあるサイトだけ**を更新する(`gh workflow run promote.yaml -f name=all`。
     アプリは `-f kind=apps` を付ける)。devにしか無いサイトを本番へ
     新規追加するときは、サイト名を指定して昇格させ、事前に
     `scripts/seal-site-secrets.sh production <site>` でSecretを用意する
   - 昇格先固有の設定(ホスト名、production冗長化設定)は各fleet.yamlの中で
     環境ごとに書き分けてあるため、丸ごとコピーで消えることはない
     (下記「環境差分の書き方」)。PRのdiffは昇格させる変更そのもの(`helm.version`、
     `plugins`等)だけになるはずで、それ以外の差分が出たら環境固有の値が
     直書きされていないか確認する

## 環境差分の書き方

promoteワークフローは環境ディレクトリを丸ごとコピーする。昇格PRのdiffを「昇格させる変更」だけに
保つため、**サイト・アプリのバンドルは全環境で同一内容のファイルにし、環境ごとに変わる値は
ファイルの中で書き分ける**(2026-10-08導入)。`diff -r envs/dev/sites envs/production/sites`で
出るのは、昇格待ちの変更(`helm.version`、`plugins`等)だけになる。

- **サイト(`sites/`、Helm)**:
  - 環境名を含む値(ingressのホスト名)は、Fleetのvaluesテンプレートでクラスタの`env`ラベルから
    展開する: `hostname: <site>.${ .ClusterLabels.env }.ibid.lan`。
    validateワークフローが直書きを検出して落とす
  - 環境固有の値は`fleet.yaml`末尾の`targetCustomizations`(`env`ラベルで選ばれる
    `dev`/`production`エントリ)の`helm.values`に書く。選ばれたエントリだけが
    `helm.values`へ深くマージされる。現在はproductionの`replicaCount: 2`/`podAntiAffinityPreset: hard`のみ
    (wp-contentの`nfs-external`は2026-10-09に全環境共通の値へ移した)
  - ひな形は`scripts/new-wordpress-site.sh`が生成する
- **アプリ(`apps/`、raw YAML)**:
  - 直下のマニフェストはdevの値で書き、productionで変える部分だけを
    `overlays/production/<マニフェスト名>_patch.yaml`に置く(Fleetのyaml overlay機能。
    `fleet.yaml`の`targetCustomizations`で`env: production`のクラスタにだけ適用される)
  - パッチ内のリスト(Ingressの`rules`/`tls`等)は丸ごと置き換わるため、リスト全体を書く。
    直下の`ingress.yaml`のパス等を変えたら、パッチ側も合わせて直すこと
- 環境固有の値を変えたいとき(例: productionのレプリカ数)は、**devのファイルを編集して
  通常どおり昇格させる**。productionのファイルだけを直すと、次の昇格で上書きされる

書き換え前後でFleetのレンダリング結果が変わらないことは、Fleet CLI(`fleet apply` →
`fleet target` → `fleet deploy --dry-run`)を実クラスタのラベルに対して実行し、
稼働中のBundleDeploymentの内容と照合して確認した。

## 本番データリハーサル

devのサイトは新品DB(またはテスト用コンテンツ)のため、**本番相当データでしか出ない問題**
(スキーマ変換の失敗、大量データでの移行時間、プラグイン同士の干渉)は検出できない。
これを本番反映前に拾うため、dev1上に**一時的なリハーサルサイト `<site>-rh`** を作り、
本番のバックアップを入れてから昇格予定の変更を適用して確認する。devの既存サイト
(`<site>`)のコンテンツは触らない。

- 本番コンテンツをdevに置くのは**リハーサルの間だけ**。終わったら必ず削除する
- dev1(とHarvesterホスト)はメモリに余裕がないため、**同時に置くリハーサルサイトは1つまで**
- リハーサルサイトもFleet管理(Git経由)にする。名前の置き換えは
  `scripts/rehearsal-site.sh` が行う

### 1. 本番のバックアップを取得する

本番サイトの日次バックアップ(`/data/nfs/backup/production/wordpress-<site>/`)をそのまま使う。
新しいものが必要なら、その場で1つ取る(どちらも
[manual-wordpress-restore.md](manual-wordpress-restore.md)「日次バックアップ」)。

日次バックアップがまだ無いサイト(チャート0.6.0より前)では、次の手動の方法で
`scripts/restore-wordpress.sh` が読める形式(`yyyymmdd_hhmm.tar.lzo` +
`yyyymmdd_hhmm.dump.lzo` の組)で、本番から取り出す。

```bash
SITE=<site>
NS=wordpress-$SITE
TS=$(date +%Y%m%d_%H%M)
DIR=~/rehearsal/$SITE && mkdir -p "$DIR" && chmod 700 "$DIR"

ROOTPW="$(kubectl --context prod1 -n $NS get secret wordpress-$SITE-mariadb-credentials \
  -o jsonpath='{.data.mariadb-root-password}' | base64 -d)"
kubectl --context prod1 -n $NS exec wordpress-$SITE-mariadb-0 -c mariadb -- \
  env MYSQL_PWD="$ROOTPW" mysqldump -u root --single-transaction --routines bitnami_wordpress \
  | lzop >"$DIR/$TS.dump.lzo"
kubectl --context prod1 -n $NS exec deploy/wordpress-$SITE -c wordpress -- \
  tar cf - -C /bitnami/wordpress wp-content \
  | lzop >"$DIR/$TS.tar.lzo"
lzop -dc "$DIR/$TS.dump.lzo" | head -1   # "-- MariaDB dump" 等で始まること
```

長いストリームがRancherプロキシ経由で切れる場合は、Pod内で一度ファイルに書き出してから
`kubectl cp` する。

### 2. リハーサルサイトを本番と同じ構成で作る

```bash
scripts/rehearsal-site.sh $SITE production     # envs/dev/sites/<site>-rh/fleet.yaml
scripts/seal-site-secrets.sh dev $SITE-rh       # envs/dev/secrets/<site>-rh.yaml(新規パスワード)
```

この2ファイルを1つのPRにしてマージする(devのみの変更)。Fleetがdev1に
`wordpress-<site>-rh` を本番と同じチャート版・プラグインで作る。
`<site>-rh.dev.ibid.lan`は、DNSのワイルドカード(`*.dev.ibid.lan`)でそのまま引ける。

### 3. 本番データをリストアする

```bash
kubectl config use-context dev1
scripts/restore-wordpress.sh $SITE-rh "$DIR" "$TS"
# 日次バックアップを使う場合: DIR=/mnt/ibid-nfs/backup/production/wordpress-$SITE(NFSをroでマウント)
```

スクリプトが最後に表示する手順に従い、URLを
`https://<site>.production.ibid.lan` → `https://<site>-rh.dev.ibid.lan` に置換する
(詳細は [manual-wordpress-restore.md](manual-wordpress-restore.md))。
新規サイトなのでLonghornスナップショットの確認プロンプトは `y` でよい。
この時点で本番と同じ表示になることを確認する(以降の比較の基準)。

### 4. 昇格予定の変更を適用して確認する

```bash
scripts/rehearsal-site.sh $SITE dev    # devで検証中の構成(helm.version・plugins等)へ切り替え
```

PRにしてマージすると、本番昇格時と同じ順序で、本番データに対してチャート更新と
プラグイン同期Jobが走る。確認すること:

- プラグイン同期Job(`plugin-sync`)が成功したか、所要時間
  (`kubectl --context dev1 -n wordpress-<site>-rh logs job/<Job名>`)
- WordPressのDB更新(管理画面の「データベースの更新が必要です」が出るなら実行し、所要時間を記録)
- MariaDBのイメージが変わったとき: システムテーブルのアップグレードが済んだか
  (`kubectl --context dev1 -n wordpress-<site>-rh exec wordpress-<site>-rh-mariadb-0 -c mariadb -- cat /bitnami/mariadb/data/mariadb_upgrade_info`
  がイメージのバージョンと一致するか。チャート0.6.3より前は、Bitnamiイメージの不具合で
  メジャー更新しても実行されていなかった。charts/ibid-wordpress/values.yaml の `extraVolumes` 参照)
- 記事表示、管理画面操作、プラグイン固有の画面
- エラーログ(`kubectl logs` のPHPエラー)

問題があればdevで修正して手順4をやり直す。結果(所要時間、気づいた点)は昇格PRに書く。

### 5. リハーサルサイトを削除する

1. Git側: `envs/dev/sites/<site>-rh/` と `envs/dev/secrets/<site>-rh.yaml` を削除するPRを作成・マージ
2. クラスタ側(手動。`keepResources: true`のためGit側の削除だけではリソースは消えない。
   **マージ後に**行うこと。先に消すとFleetが再作成する):
   ```bash
   kubectl --context dev1 delete namespace wordpress-<site>-rh   # PVC(nfs-external/harvester)も削除される
   ```
   `harvester` StorageClassのPV(mariadb)は、Harvester CSIドライバの既知の問題で
   `Released`のまま残ることがある。その場合は [roadmap.md](roadmap.md) 項目8の手順で片付ける
3. 手元のバックアップ(`~/rehearsal/<site>`)を削除する

## Harvester物理層の容量

新規サイトやリハーサルサイトのPVC作成がスケジュール待ちで詰まる場合は、
Harvester物理層の空き容量の既知の制約([roadmap.md](roadmap.md)項目3参照)を疑う。
その時点で空きのあるHarvesterホストが確保できるまで待つか、
不要なリソース(検証用に一時的に追加したノード等)を削除して空きを作る。

## 本番反映前のバックアップ(必須)

プラグイン更新・コア更新はDBスキーマを書き換えるため、
**fleet.yamlのバージョンピンをrevertしてもDBは元に戻らない**
(ロールバックはGit revertだけでは完結しない)。
production昇格PRをマージする直前に、対象サイトの

- DBダンプ(mysqldump)
- wp-contentのtar

を必ず取得する。日次バックアップのCronJobから「今すぐ1つ取る」
([manual-wordpress-restore.md](manual-wordpress-restore.md)「日次バックアップ」)。
前夜の日次バックアップより後の変更も含めるため、マージ直前に取ること。
wp-content(`nfs-external`)とDB(`harvester`)はゲストLonghornの定期バックアップの対象外なので、
Longhorn側には頼れない([manual-multi-env.md](manual-multi-env.md)の5.)。障害時はこのバックアップからの復元
([manual-wordpress-restore.md](manual-wordpress-restore.md))がロールバック手段になる。

## プラグインの「削除」はGitOpsから漏れる(要手動作業)

fleet.yamlの `plugins:` 一覧が宣言的に管理するのは**インストール・有効化のみ**。
一覧から消してもFleetは各環境のプラグインを無効化・削除しない。
テストの結果プラグインをやめる場合は、

1. fleet.yamlから該当エントリを消すPR(dev→productionへ通常どおり昇格)
2. **各環境でwp-cliによる無効化・削除を手動実行**
   ([manual-wordpress.md](manual-wordpress.md) 参照)

の両方が必要。2.を忘れるとGitと実環境が乖離したままになるので、
昇格PRの本文に手動作業のチェックリストを書いておくとよい。
