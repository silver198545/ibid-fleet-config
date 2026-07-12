# 3環境の日常運用フロー(変更のテストと昇格)

プラグインの追加・更新、チャート/イメージのバージョンアップといった日常の変更を、
dev → staging → production の3環境でどうテストし、どう本番へ反映するかの運用フロー。

環境そのものの構築・昇格の操作手順は [manual-multi-env.md](manual-multi-env.md)、
サイト管理を他チームへ委譲する際の受付フローは
[wordpress-site-delegation.md](wordpress-site-delegation.md) を参照。

## 各環境の役割

| 環境 | 役割 | コンテンツ |
|---|---|---|
| dev | 全サイトのプラグイン・バージョンアップの**互換性テスト**(インストール・有効化できるか、サイトが壊れないか) | テスト用(本番とは無関係) |
| staging | 本番反映前の最終確認。**本番からリストアしたコンテンツに対する結合テスト**(テスト終了後はリセット) | 本番のコピー(一時的) |
| production | staging合格後の反映のみ。直接の試行錯誤はしない | 本番データ |

stagingの結合テストは、WordPressコア・プラグイン・MariaDBの**DBマイグレーションを
本番相当データで事前に踏める唯一の機会**。devの新品DBでは検出できない問題
(スキーマ変換の失敗、大量データでの移行時間、プラグイン同士の干渉)をここで拾う。

## 基本サイクル: 変更はバッチにまとめて一方向に流す

promoteワークフローは環境ディレクトリをそのままコピーするため、
「**stagingでテストした構成を、一切手を加えずにproductionへ昇格する**」が大原則。
stagingが結合テスト中にdev→stagingの昇格を重ねるとテストの土台が動いてしまうので、
変更は次の1サイクルにまとめて順に流す。

1. **devで変更・互換性テスト**: `envs/dev/` のfleet.yaml(プラグイン一覧、
   `helm.version`)や `charts/`・`images/` を変更するPRを出しマージ。
   全サイトの表示・管理画面を確認する
2. **dev → staging 昇格**: promoteワークフロー(手動dispatch)でPRを生成しマージ
3. **stagingで結合テスト**:
   1. 対象サイトへ本番のバックアップをリストアする
      ([manual-wordpress-restore.md](manual-wordpress-restore.md)。
      URL置換 `<site>.production.ibid.lan` → `<site>.staging.ibid.lan` を忘れない)
   2. プラグイン・バージョンアップ後の動作、記事表示、管理画面操作を確認する
   3. **テスト終了後はサイトをリセットする**(下記「stagingのリセット手順」)。
      本番コンテンツをstagingに残置しない
4. **staging → production 昇格**: promoteワークフローでPRを生成。
   マージの**直前に必ず本番のバックアップを取得**(下記「本番反映前のバックアップ」)。
   CODEOWNERS承認のうえマージし、反映後に監視(HTTP probe)とサイト表示を確認する

## stagingのリセット手順(結合テスト後)

wp-config.phpはボリューム上に永続化され再生成されないため、「素の状態に戻す」は
**WordPressとMariaDBのPVCを削除して作り直す**ことを意味する(中途半端にDBだけ消すと
設定が残留する)。手順は [manual-wordpress-restore.md](manual-wordpress-restore.md) の
PVC再作成の項を参照。要点:

- 事前に対象BundleをFleetでpausedにする(Fleetの再同期が手動操作を打ち消すため。
  [manual-storage-migration.md](manual-storage-migration.md) で判明した注意点)
- 完了済みplugin-sync JobがPVCを掴んで削除をブロックすることがある
  → Jobを削除すれば解消(Fleetが再同期時に再作成するので実害なし)
- リセット後はFleetの再同期でチャートが再インストールされ、新品のサイトに戻る

なお、staging(3ノード運用)へ本番コンテンツをリストアすると実ディスク使用量が
一時的に増える。Longhornはthin-provisioningのため予約枠上は見えない消費であり、
実容量の逼迫はLonghorn容量アラート([manual-monitoring.md](manual-monitoring.md))で
検知する前提。大きいサイトをリストアする際は意識すること。

## 本番反映前のバックアップ(必須)

プラグイン更新・コア更新はDBスキーマを書き換えるため、
**fleet.yamlのバージョンピンをrevertしてもDBは元に戻らない**
(ロールバックはGit revertだけでは完結しない)。
production昇格PRをマージする直前に、対象サイトの

- Longhornバックアップ(wp-content)
- DBダンプ(mysqldump)

を必ず取得する。障害時はこのバックアップからの復元
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
