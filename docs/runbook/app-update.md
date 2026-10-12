# 自作アプリを更新する

対象: `envs/<env>/apps/` のアプリ(brc-advanced-search、riken-diips、sparqlist、metadatabase-v2)
詳しい説明: [manual-apps.md](../manual-apps.md)、Rundeckから実行する場合: [manual-rundeck-app-image.md](../manual-rundeck-app-image.md)

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

- sparqlist のように永続データを持つアプリで、本番と同じデータで確かめたいとき:
  `scripts/update-app-image.sh sync-dev-data $APP`(**devのデータは本番のデータで上書きされる**)

## 3. 本番へ昇格する

```bash
scripts/update-app-image.sh deploy-production $APP
```

昇格PRが作られる(`gh workflow run promote.yaml -f kind=apps -f name=$APP` と同じ)。
PRの差分が、devで確認した変更(イメージのタグなど)だけであることを見てマージする。

## 4. 本番で確認する(マージの数分後)

```bash
git pull
scripts/update-app-image.sh check-production $APP
```

「OK: … は200を返しました。」と出ればよい。ブラウザでも `https://<app>.production.ibid.lan/` を開く
(metadatabase-v2 の本番は `/bioresource/`)。

## マニフェスト(設定)だけを変えるとき

1. `envs/dev/apps/<app>/` のファイルを編集する。本番だけ変える値は `overlays/production/` に書く
2. PRを作ってマージ → devで確認
3. 手順3・4と同じ

問題があったら: [troubleshooting.md](troubleshooting.md)
