# 自作アプリを更新する

対象: `envs/<env>/apps/` のアプリ(brc-advanced-search、riken-diips、sparqlist、metadatabase-v2、brc-cross-search-xsearch、brc-cross-search-resource、member-gateway)
詳しい説明: [manual-apps.md](../manual-apps.md)、Rundeckから実行する場合: [manual-rundeck.md](../manual-rundeck.md)

更新は「devに入れる → devで確認 → stagingへ昇格して確認 → 本番へ昇格」の順。本番へは必ずstagingを通す
(自作アプリはstagingに常駐している)。

Rundeck(プロジェクト `Rancher-AppControll`)では、手順1〜2がジョブ `<app>/1-dev-update`(`src_ref` は空欄で最新)、
手順3が `<app>/2-staging-update`、手順4〜5が `<app>/3-production-update`(PRを作って人のマージを待ち、
マージ後に本番を確認する)で1回ずつになる。

## 1. 新しいソースをdevに入れる

```bash
APP=<app>
git checkout main && git pull
scripts/update-app-image.sh latest-src-ref $APP      # 取り込み元の最新コミットを表示
```

表示されたコミットが取り込みたいものなら、そのSHAで実行する:

```bash
scripts/update-app-image.sh set-image $APP <SHA>
```

これ1回で、イメージのPR → マージ → ビルド → devへ反映するPR → マージ → devの確認 まで進む(10〜20分)。
最後に「OK: … は200を返しました。」と出れば完了。

- タグは自動で採番される(例: `2.0.0-r7` → `2.0.0-r8`)。指定したいときは `set-image $APP <tag> <SHA>`
- 途中で止まったら、止まったところから再開できる:
  - ビルドの後で止まった → `scripts/update-app-image.sh deploy-dev $APP`
  - 確認だけやり直す → `scripts/update-app-image.sh check-dev $APP`

## 2. devで確認する

ブラウザで `https://<app>.dev.ibid.lan/` を開いて動作を見る。

- sparqlist の SPARQLet(`repository/`)は dev と本番で同じものを共有しているので、dev でも本番と同じデータで確かめられる
  (dev では読むだけ。SPARQLet の作成・編集は本番の管理画面で行う)

## 3. stagingへ昇格して確認する

```bash
scripts/update-app-image.sh deploy-staging $APP
```

昇格PR(`gh workflow run promote.yaml -f kind=apps -f to=staging -f name=$APP` と同じ)が作られ、
自動でマージされて、stagingの確認とQA([qa/checks.yaml](../../qa/checks.yaml) の代表URLの応答・中身)まで進む。
ブラウザで `https://<app>.staging.ibid.lan/` を開いて動作を見る
(stagingはproductionに近い設定。ただしmetadatabase-v2はdevと同じ設定、共有NFSは読み取り専用)。
QAに通らなければ直してdevからやり直す(単独の再確認は `scripts/qa.sh staging apps $APP`)。

## 4. 本番へ昇格する

```bash
scripts/update-app-image.sh deploy-production $APP
```

stagingでQAし、通れば昇格PRが作られる(`gh workflow run promote.yaml -f kind=apps -f to=production -f name=$APP` と同じ。昇格元はstaging)。
PRの差分が、stagingで確認した変更(イメージのタグなど)だけであること、`qa-gate` のチェックが通っていることを見てマージする
([operations-flow.md](../operations-flow.md)「QAゲート」)。

## 5. 本番で確認する(マージの数分後)

```bash
git pull
scripts/update-app-image.sh check-production $APP
```

「OK: … は200を返しました。」と出ればよい。ブラウザでも `https://<app>.production.ibid.lan/` を開く
(metadatabase-v2 の本番は `/bioresource/`)。

## マニフェスト(設定)だけを変えるとき

1. `envs/dev/apps/<app>/` のファイルを編集する。stagingだけ・本番だけ変える値は `overlays/staging/`・`overlays/production/` に書く
2. PRを作ってマージ → devで確認
3. 手順3〜5と同じ

問題があったら: [troubleshooting.md](troubleshooting.md)
