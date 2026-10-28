# WordPressの新規サイトを作る

詳しい説明: [manual-wordpress.md](../manual-wordpress.md)、サブパス公開(`/ja`・`/en`)は
[manual-wordpress-restore.md](../manual-wordpress-restore.md) 6b.

サイトは日本語版と英語版を**別々のWordPress**にする。日本語版を `<site>`(`/ja`)、英語版を
`<site>-en`(`/en`)とし、同じホスト名 `<site>.<env>.ibid.lan` の別パスに置く。
(片方の言語しか無いサイトなら、その1つだけ作る)

## 1. devに作る

```bash
SITE=<site>
git checkout main && git pull
git checkout -b feat/new-site-$SITE
for s in $SITE $SITE-en; do
  scripts/new-wordpress-site.sh dev $s      # envs/dev/sites/<s>/fleet.yaml
  scripts/seal-site-secrets.sh dev $s       # envs/dev/secrets/<s>.yaml
done
```

- `seal-site-secrets.sh` の最後に表示される**管理者パスワードを控える**(ここでしか表示されない。2サイト分)
- 生成された2つの `fleet.yaml` を、既存の `envs/dev/sites/abc/fleet.yaml`・`abc-en/fleet.yaml` と同じ形に直す
  (`diff <(sed 's/abc/X/g' envs/dev/sites/abc/fleet.yaml) <(sed "s/$SITE/X/g" envs/dev/sites/$SITE/fleet.yaml)` が
  プラグイン以外で空になればよい):
  - `helm.values` に `sitePath: /ja`(英語版は `/en`)
  - ingressの `hostname` を両方とも `<site>.${ .ClusterLabels.env }.ibid.lan` にし、`path: /ja`(英語版は `/en`)と `pathType: Prefix` を足す
  - `production` のエントリの `helm.values` に `publicHost: <site>.brc.riken.jp`(本番の公開ドメイン。旧サイトと同じ)
- プラグインを入れる場合は、`fleet.yaml` の `plugins:` のコメントを外して書く(書き方は既存の `envs/dev/sites/web/fleet.yaml`)

```bash
git add envs/dev && git commit -m "feat: devにWordPressサイト${SITE}(/ja)と${SITE}-en(/en)を追加"
git push -u origin HEAD && gh pr create --fill
```

PRのCIが通ったらマージする。

## 2. devで確認する(5〜10分後)

Rancherで、dev1の `wordpress-$SITE`・`wordpress-$SITE-en` をプロジェクト `Wordpress` へ移す
(Projects/Namespaces → Move。WordPressのオペレータ(`wpadmins`)がこのサイトを扱えるようにするため。
[manual-rundeck.md](../manual-rundeck.md)「WordPressのオペレータ」)。

```bash
for s in $SITE $SITE-en; do
  kubectl --context dev1 -n wordpress-$s get pods            # 全部 Running / READY 1/1
  kubectl --context dev1 -n wordpress-$s logs deploy/wordpress-$s | grep ibid-fix-wp-home
done
kubectl --context dev1 -n wordpress-$SITE get certificate     # READY が True
curl -sI https://$SITE.dev.ibid.lan/ja/ | head -1             # 200
curl -sI https://$SITE.dev.ibid.lan/en/ | head -1             # 200
```

- ログに「`https://<site>.dev.ibid.lan/ja に直しました`」(英語版は `/en`)と出ていればよい
- ドメイン直下(`https://<site>.dev.ibid.lan/`)は 404 になる(正常。本番では直下からのリダイレクトを外部nginxが行う)
- 初回はWordPressのPodが何回か再起動することがある(DBの準備待ち。自然に直る)。
  何度も `Installing WordPress` の直後に落ちる場合は [troubleshooting.md](troubleshooting.md)
- 管理画面: 確認用デスクトップ([devcon](../manual-devcon.md))のFirefoxで `https://<site>.dev.ibid.lan/ja/wp-admin/`
  (ユーザー `admin`、パスワードは手順1で控えたもの)
- 旧サイトの中身を入れる場合: [manual-wordpress-restore.md](../manual-wordpress-restore.md) 6b.(リストア後のURL置換4種まで)

## 3. 本番に出す

```bash
for s in $SITE $SITE-en; do
  scripts/seal-site-secrets.sh production $s    # 本番用のパスワード(devとは別)。控える
done
git checkout -b feat/new-site-$SITE-production
git add envs/production/secrets && git commit -m "feat: 本番にWordPressサイト${SITE}・${SITE}-enのSecretを追加"
git push -u origin HEAD && gh pr create --fill
```

このPRをマージしてから、昇格PRを作る(2サイトを1つのPRにまとめる):

```bash
gh workflow run promote.yaml -f kind=sites -f name="$SITE $SITE-en"
```

できた昇格PRの差分が `envs/production/sites/<site>/`・`<site>-en/` の追加だけであることを確認してマージする。
本番の公開ドメイン(`publicHost`)は旧サイトと同じ `<site>.brc.riken.jp`(英語版も同じ)。手順1で `fleet.yaml` の `production` のエントリに書いておく(既存の `envs/dev/sites/abc/fleet.yaml` と同じ形)。

## 4. 本番で確認する

手順2と同じことを `--context prod1`・`$SITE.production.ibid.lan` で行う(prod1のnamespaceも `Wordpress` へ移す)。
本番はWordPressのPodが2つ(READY 1/1 が2行)になる。

- 何サイトも続けて作るときは、**前のサイトが全部 Running になってから次をマージする**(同時に作るとDBの初期化が遅くなり失敗することがある)
