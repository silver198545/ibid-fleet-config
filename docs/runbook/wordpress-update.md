# WordPressを更新する

詳しい説明: [operations-flow.md](../operations-flow.md)、[manual-multi-env.md](../manual-multi-env.md) 4章

更新は「devに入れる → devで確認 → 本番へ昇格」の順。devに入れるところは自動化されている。

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

PRの本文に「**メジャー更新**」「**メジャーリリース**」と出たら、本番の前に手順Bのリハーサルを行う。

### プラグインだけを手で更新する

```bash
git checkout main && git pull
scripts/bump-plugins.sh            # 先に中身だけ見たいときは --dry-run
```

### プラグインを追加・削除する

1. `envs/dev/sites/<site>/fleet.yaml` の `plugins:` に追加する(`name` と `version`)
2. PRを作ってマージする(devに自動で入る)
3. 削除は一覧から消すだけでは消えない。devと本番でそれぞれ手で消す:
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
for s in $(ls envs/dev/sites); do printf '%-8s %s\n' $s "$(curl -sk -o /dev/null -w '%{http_code}' https://$s.dev.ibid.lan/)"; done   # 全部 200
kubectl --context dev1 get pods -A | grep wordpress- | grep -v -E 'Running|Completed'                                                 # 何も出ない
```

- 主なサイト(web・dna)の表示と管理画面をブラウザで見る
- プラグインを更新したときは、そのプラグインを使っている画面も見る

## B. 本番データリハーサル(メジャー更新のときだけ)

WordPress本体のメジャーリリース(7.0→7.1 など)、MariaDBのメジャー更新、プラグインの大きな更新のときに行う。
本番のコピーで更新を試す。手順: [operations-flow.md](../operations-flow.md)「本番データリハーサル」

## C. 本番へ昇格する

1. 本番のバックアップを取る([README.md](README.md)「本番のバックアップ」)
2. 昇格PRを作る:
   ```bash
   gh workflow run promote.yaml -f name=all
   ```
3. PRの差分が、devで確認した変更(`helm.version`、プラグインの `version`)だけであることを見てマージする
4. 5〜10分後に本番を確認する:
   ```bash
   for s in $(ls envs/production/sites); do printf '%-8s %s\n' $s "$(curl -sk -o /dev/null -w '%{http_code}' https://$s.production.ibid.lan/)"; done
   kubectl --context prod1 get pods -A | grep wordpress- | grep -v -E 'Running|Completed'
   ```
5. MariaDBのイメージを更新したときは、アップグレードが済んだか確認する(全サイトがイメージの版と同じになっていればよい):
   ```bash
   for s in $(ls envs/production/sites); do echo "$s $(kubectl --context prod1 -n wordpress-$s exec wordpress-$s-mariadb-0 -c mariadb -- cat /bitnami/mariadb/data/mariadb_upgrade_info)"; done
   ```

問題があったら: [troubleshooting.md](troubleshooting.md)
