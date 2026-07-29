# Rundeckによるapps/イメージ更新ワークフロー

`scripts/update-app-image.sh`(`envs/<env>/apps/<app>`の自作アプリのイメージ更新〜
dev→staging→production昇格を補助するスクリプト。詳細は`docs/manual-apps.md`参照)を
Rundeckから実行するためのジョブ定義。定義本体は
[rundeck/jobs/update-app-image.yaml](../rundeck/jobs/update-app-image.yaml)。

## 設計方針

`update-app-image.sh`は「1サブコマンド実行→人が結果(PR URL・CI結果・rollout状況・
WEB疎通)を確認→次のサブコマンドを手動実行」という運用を前提にしている
(スクリプト冒頭コメント参照)。PRの自動マージやSealedSecret作成の自動化は意図的に
行っていない(ブランチ保護の承認必須・PATの秘匿のため)。

このため、Rundeck側もサブコマンドごとに独立したジョブとして定義し、全体を1本の
自動ワークフローに連結することはしていない。各ジョブの実行順序・確認事項は
`scripts/update-app-image.sh`冒頭コメントの使用例と同一。

## 前提

- Rundeckからのジョブ実行は、普段このスクリプトを手動実行している踏み台/作業端末へ
  SSH実行する想定(`git`/`gh`/`kubectl`が使え、`gh auth status`が認証済み、
  `~/.kube/config`に`dev1`/`staging1`/`prod1`が登録済みであること。
  `docs/manual-tooling-setup.md`参照)。
- Rundeck自体の認証情報(SSH鍵等)は既存のRundeck運用に従う。このリポジトリでは
  Rundeck本体の設定(プロジェクト作成・ノード登録・Key Storage等)は扱わない。

## 取り込み手順

現状の設定値(全ジョブ共通):
- `nodefilters.filter: "tags: rancher"` — 踏み台端末(`rancher`ホスト)のRundeckノードタグ
- option `repo_path`の`value`: `/home/uchida/ibid-fleet-config`

別環境(別ホスト・別クローンパス)へ持っていく場合は、`rundeck/jobs/update-app-image.yaml`の
この2箇所を編集してから取り込む。

```bash
rd jobs load -p <プロジェクト名> -f rundeck/jobs/update-app-image.yaml --format yaml
```

## ジョブ一覧と実行順序

Rundeck上のグループは`app-image-update`直下に環境非依存のジョブ(`01-sync-repo`・
`02-latest-src-ref`・`03-set-image`)を置き、`app-image-update/dev`・
`app-image-update/staging`・`app-image-update/production`に環境ごとのジョブをまとめている
(`05-cleanup-staging`はstaging側の後始末なので`staging`グループ)。ジョブ名の先頭番号は
同じグループ内での実行順を表す(グループを跨いだ通し番号ではない)。

`app`オプションは`brc-advanced-search`/`riken-diips`を選択肢として登録しているが、
新規アプリ追加時にも使えるよう自由入力も許可している(`enforced: false`)。

| グループ | ジョブ名 | 対応サブコマンド | 実行タイミング |
| --- | --- | --- | --- |
| `app-image-update` | `01-sync-repo` | (なし) | PRマージ後、repo_pathのmainを最新化したいとき |
| `app-image-update` | `02-latest-src-ref` | `latest-src-ref` | イメージ更新の起点。取り込み元コミットSHAを確認 |
| `app-image-update` | `03-set-image` | `set-image` | `02-latest-src-ref`確認後。PR作成・CI待ち |
| `app-image-update/dev` | `01-deploy-dev` | `deploy-dev` | `03-set-image`のPRマージ・イメージビルド成功確認後 |
| `app-image-update/dev` | `02-check-dev` | `check-dev` | `01-deploy-dev`のPRマージ後 |
| `app-image-update/staging` | `01-promote-staging` | `promote-staging` | **初回昇格のみ**。dev確認後。実行後は下記「dirty worktree」注意を参照。`envs/staging/apps/<app>`が既にある場合はエラーになるので`03-deploy-staging`を使う |
| `app-image-update/staging` | `02-promote-staging-finish` | `promote-staging-finish` | `01-promote-staging`後、kubesealでSecretを手動作成した後 |
| `app-image-update/staging` | `03-deploy-staging` | `deploy-staging` | **2回目以降**。既にstagingにある`<app>`のイメージタグだけ更新(`deploy-dev`のstaging版) |
| `app-image-update/staging` | `04-check-staging` | `check-staging` | `02-promote-staging-finish`/`03-deploy-staging`のPRマージ後 |
| `app-image-update/production` | `01-promote-production` | `promote-production` | **初回昇格のみ**。staging確認後。実行後は下記「dirty worktree」注意を参照。`envs/production/apps/<app>`が既にある場合はエラーになるので`03-deploy-production`を使う |
| `app-image-update/production` | `02-promote-production-finish` | `promote-production-finish` | `01-promote-production`後、kubesealでSecretを手動作成した後 |
| `app-image-update/production` | `03-deploy-production` | `deploy-production` | **2回目以降**。既にproductionにある`<app>`のイメージタグだけ更新(`deploy-dev`のproduction版)。productionは`05-cleanup-staging`に相当する削除ステップが無く`envs/production/apps/<app>`が昇格後も残り続けるため、2回目以降は必ずこちらを使う |
| `app-image-update/production` | `04-check-production` | `check-production` | `02-promote-production-finish`/`03-deploy-production`のPRマージ後(**CODEOWNERS承認必須、マージは人手**) |
| `app-image-update/staging` | `05-cleanup-staging` | `cleanup-staging` | `04-check-production`確認後 |

## 注意: promote系ジョブの間はrepo_pathがdirty worktreeのまま残る

`01-promote-staging`/`01-promote-production`ジョブ(`cmd_promote_prepare`)は、コピー・
ホスト名書き換えを行った時点でコミットせずに停止する(kubesealでのSecret作成を
待つため)。つまりジョブ終了後もrepo_pathの作業ツリーは`promote/<app>-<from>-to-<to>`
ブランチのまま・未コミット変更が残った状態になる。

- `02-promote-staging-finish`/`02-promote-production-finish`を実行し終えるまで、
  同じ`repo_path`に対する他のジョブ(特に`main`ブランチであることを前提とする
  `01-sync-repo`・`03-set-image`・`01-deploy-dev`・`03-deploy-staging`・
  `03-deploy-production`・`05-cleanup-staging`等)を実行しないこと。
- 同じ`repo_path`を複数人・複数ジョブから同時に使うと、ブランチ状態を壊し合う
  (このスクリプトはもともと単一操作者の1作業ツリーを前提にした設計)。並行して
  別アプリの昇格作業を行う場合は、`repo_path`を分けた別クローンを使うこと。

## 意図的にRundeckジョブ化していないもの

- **GHCR pull用SealedSecretの作成**(`kubectl create secret ... | kubeseal`):
  実行にPersonal Access Token等の秘密情報が必要で、これをRundeckジョブの引数や
  ログに残すことは避けたい。`01-promote-staging`/`01-promote-production`ジョブの出力に
  表示されるコマンド例を、踏み台端末上で人が直接実行する。
- **PRのマージ**: リポジトリのブランチ保護(CODEOWNERSレビュー必須、ソロ運用のため
  自己承認者なし)により、`gh pr merge --auto`は無効、`--admin`によるバイパスは
  意図的なゲートを崩すため使わない。マージは常にGitHub UI(または人手での
  `gh pr merge --squash --admin`判断)に委ねる。
- **`kubectl delete namespace`(05-cleanup-staging後)**: `keepResources: true`により
  Git側の削除だけではリソースが消えないため必要な手動操作だが、`05-cleanup-staging`の
  PRがマージされる前に実行するとFleetがリソースを再作成してしまう
  (`docs/manual-apps.md`の実例参照)。ジョブ出力の指示に従い、必ずPRマージ後に
  人が実行すること。
