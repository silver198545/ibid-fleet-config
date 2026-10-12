# 自作アプリを新しく展開する

詳しい説明: [manual-apps.md](../manual-apps.md)「新しいアプリを追加する手順」。
ひな形には既存の `brc-advanced-search` を使う。以下 `<app>` はアプリ名(英小文字・数字・ハイフン)。

## 1. イメージのビルド定義を作る

1. `images/<app>/` を作り、次のファイルを置く
   - `Dockerfile`
   - `TAG`: 公開するイメージのタグ(例: `1.0.0-r0`。`<版>-r<番号>` の形にすると以後自動で採番される)
   - `SRC_REF`: 取り込むソースのコミットSHA
2. `.github/workflows/build-brc-advanced-search-image.yaml` をコピーして `build-<app>-image.yaml` を作り、アプリ名・取り込み元リポジトリを置き換える
3. 取り込み元が非公開リポジトリなら:
   - 取り込み元リポジトリに読み取り専用の Deploy Key(SSH)を登録する
   - その秘密鍵をこのリポジトリの Actions Secrets に登録する(例: `<APP>_DEPLOY_KEY`)
   - `.gitignore` に `/images/<app>/app/` を追加する
4. `scripts/update-app-image.sh` の次の3か所にアプリを追加する
   - `upstream_repo_for`(取り込み元リポジトリ)
   - `upstream_branch_for`(取り込むブランチ)
   - `ghcr_secret_needed_for`(イメージを非公開にするなら `yes`)

## 2. devのバンドルを作る

1. `envs/dev/apps/brc-advanced-search/` を `envs/dev/apps/<app>/` にコピーし、名前・イメージ・ポート・ヘルスチェックのパスを書き換える
   - namespace はアプリ名と同じにする
   - ホスト名は `<app>.dev.ibid.lan`(本番の値は次の `overlays/production/` に書く)
2. `overlays/production/` に本番だけの値を書く
   - `ingress_patch.yaml`: ホスト名 `<app>.production.ibid.lan`(`tls` と `rules` を丸ごと書く)
   - `deployment_patch.yaml`: `replicas: 2` など
3. イメージを非公開にする場合は、GHCRのpull用Secretを作る(`read:packages` だけのPATを使う):
   ```bash
   kubectl create secret docker-registry ghcr-<app> -n <app> \
     --docker-server=ghcr.io --docker-username=<GitHubユーザー名> --docker-password=<PAT> \
     --docker-email=unused@example.com --dry-run=client -o json \
   | kubeseal --context dev1 --format yaml > envs/dev/secrets/<app>.yaml
   ```
   Deployment の `imagePullSecrets` に `ghcr-<app>` を入れる。**PATの期限の日を控えておく**
4. `README.md` の「現在の構成」の表と、ワークフロー一覧の `build-<app>-image` の行にアプリ名を足す

## 3. devに出す

```bash
git checkout -b feat/new-app-<app>
git add images .github envs/dev scripts README.md .gitignore
git commit -m "feat: 自作アプリ<app>をdevに追加"
git push -u origin HEAD && gh pr create --fill
```

マージすると、イメージのビルドが走り、devに展開される。

- イメージを公開してよい場合は、初回のビルド後に GitHub の Packages → `<app>` → Package settings で **Public** にする
- 確認:
  ```bash
  git checkout main && git pull
  scripts/update-app-image.sh check-dev <app>
  ```

## 4. 本番に出す(初回だけ専用の手順)

```bash
scripts/update-app-image.sh promote-production <app>
```

表示された `kubeseal` のコマンド(本番用のSecret作成)を実行してから:

```bash
scripts/update-app-image.sh promote-production-finish <app>
```

できたPRの差分を見てマージし、確認する:

```bash
git checkout main && git pull
scripts/update-app-image.sh check-production <app>
```

2回目以降の更新は [app-update.md](app-update.md)。
