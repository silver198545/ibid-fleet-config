# 日常運用フロー(変更のテストと昇格)

プラグインの追加・更新、チャート/イメージのバージョンアップといった日常の変更を、
dev → staging → production の3環境でどうテストし、どう本番へ反映するかの運用フロー。

環境そのものの構築・昇格の操作手順は [manual-multi-env.md](manual-multi-env.md)、
サイト管理を他チームへ委譲する際の受付フローは
[wordpress-site-delegation.md](wordpress-site-delegation.md) を参照。

## 各環境の役割

| 環境 | 役割 | コンテンツ |
|---|---|---|
| dev | 全サイトのプラグイン・バージョンアップの**互換性テスト**(インストール・有効化できるか、サイトが壊れないか) | テスト用(本番とは無関係) |
| staging | 本番へ出す前の**本番データでの確認**(下記「stagingでの確認」)。確認中のサイト・アプリだけを一時的に置き、終わったら消す | 本番のコピー(一時的) |
| production | stagingで確認済みの変更の反映のみ。直接の試行錯誤はしない | 本番データ |

stagingは2026-10-08に一度廃止し(HWリソースの制約。その間はdev1上の一時的なリハーサルサイト
`<site>-rh` で代替していた)、2026-10-25にSSDを使ったstaging1で再導入した(経緯は [roadmap.md](roadmap.md))。
staging1は小さい(8GiBのノード3台)ため常駐させるものは無く、**同時に置けるWordPressサイトは4つまで**。

## 基本サイクル: 変更はバッチにまとめて一方向に流す

promoteワークフローは環境ディレクトリを丸ごとコピーするため、
「**stagingで確認した構成を、一切手を加えずにproductionへ昇格する**」が大原則。
本番へは必ずstagingを通す(promoteワークフローの本番への昇格元はstaging)。

1. **devで変更・互換性テスト**: `envs/dev/` のfleet.yaml(プラグイン一覧、
   `helm.version`)や `charts/`・`images/` を変更するPRを出す。productionに触れないPRは
   `validate` が通れば承認なしでマージできる(auto-merge可)。チャートの変更は
   `scripts/bump-chart.sh`、アプリのイメージ更新は `scripts/update-app-image.sh set-image` が
   devへの反映まで一括で行う([manual-multi-env.md](manual-multi-env.md) 4章)。
   全サイトの表示・管理画面を確認する
2. **stagingで本番データを使って確認**: 下記「stagingでの確認」の手順で、本番と同じ構成・本番データの
   サイトをstagingに置き、昇格予定の変更(devの構成)を当てて基準と比べる。stagingだけに触れるPRは
   承認不要でauto-mergeされる。WordPressコア・プラグインのメジャー更新、チャートのMariaDB更新など、
   **DBスキーマを書き換え得る変更では念入りに**確認する
3. **staging → production 昇格**: promoteワークフロー(手動dispatch、`to=production`、`name`にサイト名か`all`)
   でPRを生成。マージの**直前に必ず本番のバックアップを取得**(下記「本番反映前のバックアップ」)。
   CODEOWNERS承認のうえマージし、反映後に監視(HTTP probe)とサイト表示を確認する。
   `scripts/wordpress-pipeline.sh promote-production` がバックアップ・マージ待ち・確認までを行う
   - `name=all`は**本番に既にあり、stagingに載っているサイトだけ**を更新する
     (`gh workflow run promote.yaml -f to=production -f name=all`。アプリは `-f kind=apps` を付ける)。
     本番に無いサイトを新規追加するときは、サイト名を指定して昇格させ、事前に
     `scripts/seal-site-secrets.sh production <site>` でSecretを用意する。
     サイト名は空白かカンマ区切りで複数指定でき、1つのPRにまとまる
     (例: `-f name="abc abc-en"`。`all`は単独でのみ指定できる)
   - 昇格先固有の設定(ホスト名、production冗長化設定)は各fleet.yamlの中で
     環境ごとに書き分けてあるため、丸ごとコピーで消えることはない
     (下記「環境差分の書き方」)。PRのdiffは昇格させる変更そのもの(`helm.version`、
     `plugins`等)だけになるはずで、それ以外の差分が出たら環境固有の値が
     直書きされていないか確認する
4. **stagingの片付け**: 本番へ昇格したら、stagingからサイトを削除する(`staging-cleanup`)。
   本番データのコピーを残さないため、またstaging1のメモリを空けるため、必ず行う

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
    `helm.values`へ深くマージされる。現在はproductionの`replicaCount: 2`/`podAntiAffinityPreset: hard`と、
    外部nginxで公開するサイトの`publicHost`(公開ドメイン。例: devのabc/abc-enは`wpdev1.brc.riken.jp`、
    [manual-wordpress-restore.md](manual-wordpress-restore.md) 6b.)
    (wp-contentの`nfs-external`は2026-10-09に全環境共通の値へ移した)
  - ひな形は`scripts/new-wordpress-site.sh`が生成する
- **アプリ(`apps/`、raw YAML)**:
  - 直下のマニフェストはdevの値で書き、staging・productionで変える部分だけを
    `overlays/<env>/<マニフェスト名>_patch.yaml`に置く(Fleetのyaml overlay機能。
    `fleet.yaml`の`targetCustomizations`で、`env`ラベルが一致するクラスタにだけ適用される)。
    パッチではなく同名のファイルを置くと、直下のファイルを丸ごと置き換える
  - overlayは環境ごとに1つだけ使い、重ねない(stagingのoverlayはproductionのものを参照しない)。
    stagingは原則productionに近い設定(ホスト名、`RACK_ENV`等)にするが、**レプリカは1**、
    **本番と共有するNFSは読み取り専用のまま**にする。本番のデータや外部サービスへ書き込める
    設定はstagingに持ち込まない(例: metadatabase-v2はstagingでもdevの設定。fleet.yamlのコメント参照)
  - パッチ内のリスト(Ingressの`rules`/`tls`等)は丸ごと置き換わるため、リスト全体を書く。
    直下の`ingress.yaml`のパス等を変えたら、各環境のパッチ側も合わせて直すこと。
    validateワークフローが、各環境のIngressのホスト名(`<app>.<env>.ibid.lan`)と、
    devに`overlays/staging|production/ingress_patch.yaml`が揃っていることを確認する
- 環境固有の値を変えたいとき(例: productionのレプリカ数)は、**devのファイルを編集して
  通常どおり昇格させる**。productionのファイルだけを直すと、次の昇格で上書きされる

書き換え前後でFleetのレンダリング結果が変わらないことは、Fleet CLI(`fleet apply` →
`fleet target` → `fleet deploy --dry-run`)を実クラスタのラベルに対して実行し、
稼働中のBundleDeploymentの内容と照合して確認した。

## stagingでの確認

devのサイトは新品DB(またはテスト用コンテンツ)のため、**本番相当データでしか出ない問題**
(スキーマ変換の失敗、大量データでの移行時間、プラグイン同士の干渉)は検出できない。
これを本番反映前に拾うため、確認するサイトを**本番と同じ構成でstagingに置き、本番のバックアップを
入れてから**昇格予定の変更(devの構成)を当てて確認する。

- 本番コンテンツをstagingに置くのは**確認の間だけ**。本番へ昇格したら必ず削除する
  (stagingのStorageClassは`Delete`なので、namespaceを消すとNFS上のwp-content・バックアップも消える)
- staging1はメモリに余裕がないため、**同時に置くサイトは4つまで**(`STAGING_MAX_SITES`)。
  一斉更新(チャートの更新等)は4サイトずつ回す
- stagingのサイトもFleet管理(Git経由)。名前はdev・本番と同じ(`wordpress-<site>`)で、
  ホスト名は`<site>.staging.ibid.lan`(DNSのワイルドカード`*.staging.ibid.lan`)。
  Secretはstaging用に毎回新しいパスワードで封印し、片付けで消す
- 以下の1.〜5.は `scripts/wordpress-pipeline.sh` の `staging-start <site>`(1.〜3.)・
  `staging-upgrade <site>`(4.。基準との比較も行う)・`promote-production <site>`・`staging-cleanup <site>`(5.)で
  まとめて実行できる(Rundeckのプロジェクト `WordPressControl` のジョブ `2-staging` 等。[manual-rundeck.md](manual-rundeck.md))。
  以下はその中身の説明を兼ねた手動手順
- 本番にまだ無い新規サイトは、devの構成でstagingに置いて確認する(本番データは無いので3.と4.は不要)

### 1. 本番のバックアップを取得する

本番サイトの日次バックアップ(`/data/nfs/backup/production/wordpress-<site>/`)をそのまま使う。
新しいものが必要なら、その場で1つ取る(どちらも
[manual-wordpress-restore.md](manual-wordpress-restore.md)「日次バックアップ」)。

### 2. stagingに本番と同じ構成で置く

```bash
cp -r envs/production/sites/$SITE envs/staging/sites/$SITE   # 本番と同じ構成(比較の基準)
scripts/seal-site-secrets.sh staging $SITE                    # envs/staging/secrets/<site>.yaml(新規パスワード)
```

この2つを1つのPRにしてマージする(stagingのみの変更なので承認不要)。Fleetがstaging1に
`wordpress-<site>` を本番と同じチャート版・プラグインで作る。

### 3. 本番データをリストアする

```bash
kubectl config use-context staging1
scripts/restore-wordpress.sh $SITE /mnt/ibid-nfs/backup/production/wordpress-$SITE <yyyymmdd_hhmm>
# バックアップNFSを踏み台端末にroでマウントしておく(manual-wordpress-restore.md「日次バックアップ」)
```

スクリプトが最後に表示する手順に従い、URLを本番の公開URL → `https://<site>.staging.ibid.lan` に置換する
(詳細は [manual-wordpress-restore.md](manual-wordpress-restore.md) 6b.)。
この時点で本番と同じ表示になることを確認する(以降の比較の基準)。

### 4. 昇格予定の変更を適用して確認する

```bash
gh workflow run promote.yaml -f to=staging -f name=$SITE   # devの構成(helm.version・plugins等)をstagingへ。auto-merge
```

マージされると、本番昇格時と同じ順序で、本番データに対してチャート更新と
プラグイン同期Jobが走る。確認すること:

- プラグイン同期Job(`plugin-sync`)が成功したか、所要時間
  (`kubectl --context staging1 -n wordpress-<site> logs job/<Job名>`)
- WordPressのDB更新(管理画面の「データベースの更新が必要です」が出るなら実行し、所要時間を記録)
- MariaDBのイメージが変わったとき: システムテーブルのアップグレードが済んだか
  (`kubectl --context staging1 -n wordpress-<site> exec wordpress-<site>-mariadb-0 -c mariadb -- cat /bitnami/mariadb/data/mariadb_upgrade_info`
  がイメージのバージョンと一致するか。チャート0.6.3より前は、Bitnamiイメージの不具合で
  メジャー更新しても実行されていなかった。charts/ibid-wordpress/values.yaml の `extraVolumes` 参照)
- 記事表示、管理画面操作、プラグイン固有の画面
- エラーログ(`kubectl logs` のPHPエラー)

問題があればdevで修正して手順4をやり直す。結果(所要時間、気づいた点)は本番への昇格PRに書く。
問題なければ本番へ昇格する(上記「基本サイクル」3.)。

### 5. stagingから削除する

本番へ昇格したら(または昇格をやめたら)削除する。

1. Git側: `envs/staging/sites/<site>/` と `envs/staging/secrets/<site>.yaml` を削除するPRを作成・マージ
2. クラスタ側(手動。`keepResources: true`のためGit側の削除だけではリソースは消えない。
   **マージ後に**行うこと。先に消すとFleetが再作成する):
   ```bash
   kubectl --context staging1 delete namespace wordpress-<site>   # PVC(nfs-external/nfs-backup/harvester)も削除される
   ```
   PV(NFSのディレクトリ・mariadbのHarvesterのボリューム)は数十秒〜数分遅れて消える
   (2026-08にHarvesterをv1.8系へ上げてから、[roadmap.md](roadmap.md) 項目8のCSIの問題は起きていない)

## Harvester物理層の容量

新規サイトやstagingのサイトのPVC作成がスケジュール待ちで詰まる場合は、
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

1. fleet.yamlから該当エントリを消すPR(dev→staging→productionへ通常どおり昇格)
2. **各環境でwp-cliによる無効化・削除を手動実行**
   ([manual-wordpress.md](manual-wordpress.md) 参照)

の両方が必要。2.を忘れるとGitと実環境が乖離したままになるので、
昇格PRの本文に手動作業のチェックリストを書いておくとよい。
