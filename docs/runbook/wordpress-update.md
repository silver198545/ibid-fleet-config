# WordPressを更新する

詳しい説明: [operations-flow.md](../operations-flow.md)、[manual-multi-env.md](../manual-multi-env.md) 4章

更新は「devに入れる → devで確認 → stagingで本番データを使って確認 → 本番へ昇格 → stagingから削除」の順。
devに入れるところは自動化されている。本番へは必ずstagingを通す(stagingに同時に置けるのは4サイトまで)。

Rundeck(プロジェクト `WordPressControl`)では、手順B(staging)がジョブ `2-staging`、
手順C(バックアップ → 昇格PR → 人がマージ → 本番の確認)が `3-production-promote`、
手順D(stagingから削除)が `4-staging-cleanup` で1回ずつになる。
devのサイトに本番のコンテンツを入れ直したいときは `1-dev-refresh`([manual-rundeck.md](../manual-rundeck.md))。

## A. devへの反映(どれか)

### 自動(毎週月曜 9:00)

`auto-update` ワークフローが、WordPress本体・MariaDBのイメージとプラグインの新しい版をdevへ自動で入れる。
何もしなくてよい。結果はGitHubの Actions → `auto-update`、または作られたPRで見る。
すぐ実行したいとき:

```bash
gh workflow run auto-update.yaml
```

### WordPress本体・MariaDBだけを手で更新する

```bash
git checkout main && git pull
scripts/bump-chart.sh --update-images "feat: WordPress/MariaDBイメージを最新のdigestへ更新"
```

PRの本文に「**メジャー更新**」「**メジャーリリース**」と出たら、手順Bの確認を特に念入りに行う。

### プラグインだけを手で更新する

```bash
git checkout main && git pull
scripts/bump-plugins.sh            # 先に中身だけ見たいときは --dry-run
```

### プラグインを追加・削除する

1. `envs/dev/sites/<site>/fleet.yaml` の `plugins:` に追加する(`name` と `version`)
2. PRを作ってマージする(devに自動で入る)
3. 削除は一覧から消すだけでは消えない。devと本番でそれぞれ手で消す(stagingは片付けで消えるので不要):
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
scripts/wordpress-pipeline.sh staging-start <site>     # stagingへ追加 → 本番データをリストア → 基準を記録
scripts/wordpress-pipeline.sh staging-upgrade <site>   # devの構成へ切り替え → 基準と比較 → QA
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
scripts/wordpress-pipeline.sh staging-cleanup <site>
```

問題があったら: [troubleshooting.md](troubleshooting.md)
