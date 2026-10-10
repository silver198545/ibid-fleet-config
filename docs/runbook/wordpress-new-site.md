# WordPressの新規サイトを作る

詳しい説明: [manual-wordpress.md](../manual-wordpress.md)

## 1. devに作る

```bash
SITE=<site>
git checkout main && git pull
git checkout -b feat/new-site-$SITE
scripts/new-wordpress-site.sh dev $SITE      # envs/dev/sites/<site>/fleet.yaml
scripts/seal-site-secrets.sh dev $SITE       # envs/dev/secrets/<site>.yaml
```

- `seal-site-secrets.sh` の最後に表示される**管理者パスワードを控える**(ここでしか表示されない)
- プラグインを入れる場合は、`fleet.yaml` の `plugins:` のコメントを外して書く(書き方は既存の `envs/dev/sites/web/fleet.yaml`)

```bash
git add envs/dev && git commit -m "feat: devにWordPressサイト${SITE}を追加"
git push -u origin HEAD && gh pr create --fill
```

PRのCIが通ったらマージする。

## 2. devで確認する(5〜10分後)

```bash
kubectl --context dev1 -n wordpress-$SITE get pods            # 全部 Running / READY 1/1
kubectl --context dev1 -n wordpress-$SITE get certificate     # READY が True
curl -sI https://$SITE.dev.ibid.lan/ | head -1                # 200
kubectl --context dev1 -n wordpress-$SITE logs deploy/wordpress-$SITE | grep ibid-fix-wp-home
```

- 最後の行に「`https://… に直しました`」と出ていればよい
- 初回はWordPressのPodが1〜2回再起動することがある(DBの準備待ち。自然に直る)
- 管理画面: `https://<site>.dev.ibid.lan/wp-admin/`(ユーザー `admin`、パスワードは手順1で控えたもの)

## 3. 本番に出す

```bash
scripts/seal-site-secrets.sh production $SITE    # 本番用のパスワード(devとは別)。控える
git checkout -b feat/new-site-$SITE-production
git add envs/production/secrets && git commit -m "feat: 本番にWordPressサイト${SITE}のSecretを追加"
git push -u origin HEAD && gh pr create --fill
```

このPRをマージしてから、昇格PRを作る:

```bash
gh workflow run promote.yaml -f name=$SITE
```

できた昇格PRの差分が `envs/production/sites/<site>/` の追加だけであることを確認してマージする。

## 4. 本番で確認する

手順2と同じことを `--context prod1`・`$SITE.production.ibid.lan` で行う。
本番はWordPressのPodが2つ(READY 1/1 が2行)になる。

- 何サイトも続けて作るときは、**前のサイトが全部 Running になってから次をマージする**(同時に作るとDBの初期化が遅くなり失敗することがある)
- 中身(コンテンツ)を別の環境から移す場合: [manual-wordpress-restore.md](../manual-wordpress-restore.md)
