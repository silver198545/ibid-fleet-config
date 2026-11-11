# WordPressを更新する

詳しい説明: [operations-flow.md](../operations-flow.md)、[manual-multi-env.md](../manual-multi-env.md) 4章

更新は「devに入れる → devで確認 → stagingで本番データを使って確認 → 本番へ昇格 → stagingから削除」の順。
devに入れるのは、WordPress本体・MariaDBは自動。プラグインはサイトの管理者がdevの管理画面で更新して確かめ、RundeckでGitに取り込む。
本番へは必ずstagingを通す(stagingに同時に置けるのは4サイトまで)。

Rundeck(プロジェクト `WordPressControl`)では、手順Aのプラグインの取り込みが `0-dev-plugin-capture`、手順B(staging)がジョブ `2-staging`、
手順C(バックアップ → 昇格PR → 人がマージ → 本番の確認)が `3-production-promote`、
手順D(stagingから削除)が `4-staging-cleanup` で1回ずつになる(どのジョブも複数のサイトをまとめて選べる)。
devのサイトに本番のコンテンツを入れ直したいときは `1-dev-refresh`([manual-rundeck.md](../manual-rundeck.md))。

## A. devへの反映(どれか)

### WordPress本体・MariaDB: 自動(毎週月曜 9:00)

`auto-update` ワークフローが、WordPress本体・MariaDBのイメージの新しい版をdevへ自動で入れる。
何もしなくてよい。結果はGitHubの Actions → `auto-update`、または作られたPRで見る。
すぐ実行したいとき:

```bash
gh workflow run auto-update.yaml
```

### プラグイン: サイトの管理者がdevの管理画面で更新し、Gitに取り込む(2026-11-09〜)

プラグインは自動では上がらない。毎週月曜 9:00 に Rundeck の `tools/plugin-check` が、新しい版があるもの・
Gitに取り込んでいないものを Slack へ知らせる。**:rotating_light: が付いたもの(脆弱性のある版を使っている)は早めに**更新する。

1. devのサイトの管理画面(`https://<site>.dev.ibid.lan/<ja|en>/wp-admin/`)でプラグインを更新する(追加・削除・有効/無効の切り替えも同じ)
2. devのサイトで表示・管理画面・プラグイン固有の画面を確認する(下の「devで確認する」)
3. Rundeck(`WordPressControl`)の `0-dev-plugin-capture` を開き、`sites` でサイトを選んで実行する
   (devに入っている版がGitに取り込まれ、自動でマージされる。devは変わらない)
4. 手順B(staging)→ 手順C(本番)へ進む

- すぐ確認したいときは `tools/plugin-check` を手で実行する(`notify=no` ならSlackへは送らない)
- 取り込む前に月曜の `auto-update`(WordPress本体の更新)が動いても、devで上げた版は戻らない(チャート0.7.7〜)
- WordPress.orgに無いプラグイン(例: `cell` の `biz-calendar`)はGitで管理できない。各環境の管理画面で更新する
- WordPress.orgで配布されていない古い版は取り込めない。管理画面で配布中の版へ更新してから取り込む
- **本番・stagingの管理画面ではプラグインを更新しない**(Gitの版とずれる。本番へは必ずdevで確かめて昇格する)

### WordPress本体・MariaDBだけを手で更新する

```bash
git checkout main && git pull
scripts/bump-chart.sh --update-images "feat: WordPress/MariaDBイメージを最新のdigestへ更新"
```

PRの本文に「**メジャー更新**」「**メジャーリリース**」と出たら、手順Bの確認を特に念入りに行う。

### プラグインを端末から取り込む・上げる(Rundeckを使わない場合)

```bash
git checkout main && git pull
scripts/plugin-check.sh all             # 状態を見るだけ
scripts/capture-plugins.sh web          # devに入っている版をGitに取り込む(all で全サイト。--dry-run で書き換えだけ)
scripts/bump-plugins.sh web             # 管理画面を通さず、Git側で最新版へ上げる(運用者向け)
```

### プラグインを追加・削除する

1. devの管理画面で追加・削除して確かめ、`0-dev-plugin-capture` で取り込む(上の手順)。
   手でGitに書くときは `envs/dev/sites/<site>/fleet.yaml` の `plugins:` に `name` と `version`(無効なら `activate: false`)
2. 削除は一覧から消えるだけで、他の環境のプラグインは消えない。本番では手で消す(stagingは片付けで消えるので不要):
   ```bash
   kubectl --context <dev1|prod1> -n wordpress-<site> exec deploy/wordpress-<site> -c wordpress -- \
     sh -c 'cd /opt/bitnami/wordpress && wp plugin deactivate <name> && wp plugin delete <name>'
   ```

### 全サイト共通の設定(チャート)を変える

`charts/ibid-wordpress/` を編集し、コミットしないまま実行する:

```bash
scripts/bump-chart.sh "fix: <変更内容>"
```

## devで確認する

```bash
for f in envs/dev/sites/*/fleet.yaml; do h=$(grep -oP 'hostname: \K[a-z0-9-]+' $f); p=$(grep -oP '^    sitePath: \K\S+' $f); printf '%-12s %s\n' $(basename $(dirname $f)) "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.dev.ibid.lan$p/)"; done   # 全部 200
kubectl --context dev1 get pods -A | grep wordpress- | grep -v -E 'Running|Completed'                                                 # 何も出ない
```

- 主なサイト(web・dna)の表示と管理画面をブラウザで見る
- プラグインを更新したときは、そのプラグインを使っている画面も見る

## B. stagingで本番データを使って確認する

本番へ出すサイトを本番と同じ構成でstagingに置き、本番データを入れてから、devの構成(昇格予定の変更)へ切り替えて
基準と比べる。手順の説明: [operations-flow.md](../operations-flow.md)「stagingでの確認」

```bash
scripts/wordpress-pipeline.sh staging-start <site>...  # stagingへ追加 → 本番データをリストア → 基準を記録
scripts/wordpress-pipeline.sh staging-upgrade <site>...  # devの構成へ切り替え → 基準と比較 → QA
```

- 出力の「HTTPステータスが変わったページ」「PHPエラー」「QA」(本番とタイトル・サイト名が一致するか等。
  [operations-flow.md](../operations-flow.md)「QAゲート」)を見て、stagingのサイト(`https://<site>.staging.ibid.lan/ja/`)を
  ブラウザでも確認する。問題があればdevで直して `staging-upgrade` をやり直す
- WordPress本体のメジャーリリース(7.0→7.1 など)、MariaDBのメジャー更新、プラグインの大きな更新のときは特に念入りに
- 全サイトを更新するときは、4サイトずつ B → C → D を繰り返す

## C. 本番へ昇格する

stagingに載っている内容を本番へ昇格する。

1. 本番のバックアップを取る([README.md](README.md)「本番のバックアップ」)
2. 昇格PRを作る(`all` はstagingに載っている、本番にある全サイト):
   ```bash
   gh workflow run promote.yaml -f to=production -f name=all
   ```
   (1.〜5.は `scripts/wordpress-pipeline.sh promote-production <site...|all>` でまとめて実行できる。
   こちらはPRを作る前にstagingのQAを行い、通らなければ止まる)
3. PRの差分が、stagingで確認した変更(`helm.version`、プラグインの `version`)だけであること、
   `qa-gate` のチェックが通っていることを見てマージする(落ちていたら `scripts/qa.sh staging sites <site...>`)
4. 5〜10分後に本番を確認する:
   ```bash
   for f in envs/production/sites/*/fleet.yaml; do h=$(grep -oP 'hostname: \K[a-z0-9-]+' $f); p=$(grep -oP '^    sitePath: \K\S+' $f); printf '%-12s %s\n' $(basename $(dirname $f)) "$(curl -sk -o /dev/null -w '%{http_code}' https://$h.production.ibid.lan$p/)"; done
   kubectl --context prod1 get pods -A | grep wordpress- | grep -v -E 'Running|Completed'
   ```
5. MariaDBのイメージを更新したときは、アップグレードが済んだか確認する(全サイトがイメージの版と同じになっていればよい):
   ```bash
   for s in $(ls envs/production/sites); do echo "$s $(kubectl --context prod1 -n wordpress-$s exec wordpress-$s-mariadb-0 -c mariadb -- cat /bitnami/mariadb/data/mariadb_upgrade_info)"; done
   ```

## D. stagingから削除する

本番へ昇格したら必ず削除する(本番データのコピーを残さない。staging1のメモリを空ける):

```bash
scripts/wordpress-pipeline.sh staging-cleanup <site>...
```

問題があったら: [troubleshooting.md](troubleshooting.md)
