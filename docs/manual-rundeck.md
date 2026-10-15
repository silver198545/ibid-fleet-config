# Rundeckのパイプライン(自作アプリ・WordPress)

日常の更新作業を、Rundeckのジョブ1つ(=パイプライン1本)で最後まで流せるようにしたもの。
ジョブの定義は [rundeck/jobs/apps.yaml](../rundeck/jobs/apps.yaml) と
[rundeck/jobs/wordpress.yaml](../rundeck/jobs/wordpress.yaml) で、どちらも
[rundeck/generate-jobs.py](../rundeck/generate-jobs.py) が生成する(**直接編集しない**)。

| パイプライン | Rundeckのジョブ | 中身(手動でも同じことができる) |
|---|---|---|
| 自作アプリの開発環境更新 | `apps/<app>/1-dev-update` | `scripts/update-app-image.sh dev-update <app>` |
| 自作アプリの本番環境更新 | `apps/<app>/2-production-update` | `scripts/update-app-image.sh release-production <app>` |
| WordPressの開発環境更新(本番コンテンツ → dev) | `wordpress/1-dev-refresh` | `scripts/wordpress-pipeline.sh dev-refresh <site>...` |
| WordPressの本番データリハーサル | `wordpress/2-rehearsal` | `scripts/wordpress-pipeline.sh rehearsal-start` / `rehearsal-upgrade <site>` |
| WordPressの本番昇格 | `wordpress/3-production-promote` | `scripts/wordpress-pipeline.sh promote-production <site...\|all>` |

(2026-10-15に、サブコマンドを1つずつジョブにしていた旧定義 `rundeck/jobs/update-app-image.yaml`
(グループ `app-image-update`)から作り直した。)

## 設計方針

- **処理はスクリプトに置き、ジョブは呼ぶだけ**。パイプラインの各段は `scripts/` のサブコマンドで、
  Rundeckが無くても端末から同じ順序で実行できる。ジョブの各ステップの出力がそのまま作業記録になる
- **自作アプリはアプリごとにジョブを作る**(`apps/<app>/`)。WordPressは34サイトあるため、
  サイトはジョブのオプション(選択肢)で選ぶ
- **本番に触れるPRはマージしない**。本番のパイプラインはPRを作ったあと**人がGitHubでレビュー
  (Code OwnerのApprove)・マージするのを待ち**(既定240分。オプション `merge_wait_minutes`)、マージを検知したら反映の
  確認まで続ける。PRの作成者はパイプライン用のマシンユーザーなので、Code Ownerの承認が
  無いとマージできない(下記「実行アカウント」)。待ち時間を過ぎるとジョブは失敗で終わる(PRは残るので、マージ後に
  `9-check` / `wordpress/tools/check` で確認する)
- **devだけに触れるPRはauto-merge**する(イメージ更新、リハーサルサイトの追加・削除)
- **同じクローンを使うジョブは排他する**。gitのブランチを切り替える処理は
  `.git/ibid-pipeline.lock` のロック(`scripts/lib/pr.sh` の `pr_lock_repo`)を取ってから行う。
  本番PRのマージ待ちやリストアの間はロックを手放すので、その間も他のジョブは動ける
- **秘密情報はジョブで扱わない**。GHCR pull用SealedSecret(PAT)の作成はジョブにしない
  (アプリの初回昇格のときだけ人が実行する)。リハーサルサイトの新規パスワードは
  ログに出さない(`SEAL_HIDE_PASSWORDS=1`)

## 前提

- ジョブは踏み台端末(`rancher`ホスト)の**パイプライン専用OSユーザー `ibidops`** へSSHで実行する
  (Rundeckノードタグ `ibid-ops`)。GitHubの操作はすべて**パイプライン用のマシンユーザー**
  (下記「実行アカウント」)で行われ、オペレータ個人や管理者(`silver198545`)のアカウントは使わない
- `ibidops` で `git`/`gh`/`kubectl`/`kubeseal`/`flock` が使え、`gh auth status` がマシンユーザーで
  認証済み、`~/.kube/config` に `dev1`/`prod1` があること([manual-tooling-setup.md](manual-tooling-setup.md))
- WordPressのジョブ(dev-refresh・リハーサル)は、バックアップNFSを踏み台端末に**読み取り専用で
  マウント**しておく(`/mnt/ibid-nfs`。[manual-wordpress-restore.md](manual-wordpress-restore.md)
  「日次バックアップ」)。再起動で外れるので、外れていたらジョブが案内を出して止まる:
  ```bash
  sudo mkdir -p /mnt/ibid-nfs && sudo mount -t nfs -o ro,nfsvers=4.1 192.168.1.1:/data/nfs /mnt/ibid-nfs
  ```
  リストアはwp-contentを踏み台端末の `/tmp` で展開し直すため、最大のサイトのwp-content
  (2026-10時点で圧縮470MB)の数倍の空きが要る
- クローンのパス(`/home/ibidops/ibid-fleet-config`)とノードフィルタ(`tags: ibid-ops`)は
  `generate-jobs.py` の `REPO_PATH`・`NODE_FILTER`。別ホスト・別ユーザーへ持っていくときはそこを変えて再生成する
- Rundeck本体の設定(プロジェクト・ノード登録・SSH鍵・ACL)はこのリポジトリでは扱わない(下記に必要な設定だけ書く)

## 実行アカウント(マシンユーザー)

2026-10-16から、Rundeckのジョブは専用のGitHubアカウント(マシンユーザー。以下 `<bot>`。例: `ibid-ops-bot`)で
動く。それまでは踏み台端末の `uchida` ユーザー=管理者の `silver198545` のトークンで動いており、
オペレータが実行しても全操作が管理者の操作として記録され、本番PRも「作成者=唯一のCode Owner」なので
承認なしでマージできた。

マシンユーザーに替えたことで:

- **botが作った本番PR(`envs/production/` に触れるPR)は、Code Owner(`@silver198545`)の承認(Approve)が
  ないとマージできない**。botはwrite権限なので、ルールセットの管理者バイパスも使えない。
  本番パイプラインはPRを作ってこの承認・マージを待つ(承認者はPRを開いて **Approve → Merge**)
- devだけに触れるPRは、Code Ownerの対象外なので今までどおりbotがauto-mergeする
- **誰が実行したか**はGitHub上ではbotになるため、パイプラインはRundeckの実行者名
  (`PIPELINE_ACTOR`。`generate-jobs.py` が `@job.username@` を渡す)をPR本文(promoteワークフローが
  作るPRはコメント)に書き残す
- promoteワークフローが作るPRの作成者は `PROMOTE_TOKEN` の持ち主になる。これをbotのトークンに
  替えたので、**管理者が自分で `gh workflow run promote.yaml` した本番PRも承認が要る**
  (自分のPRではないのでApproveできる)。管理者が手元で `update-app-image.sh promote-production-finish`
  等を実行して作ったPRは、従来どおり管理者のPRで承認なしにマージできる

### 初回の設定(1回だけ。管理者が行う)

1. **GitHubのマシンユーザーを作る**(個人ごとに1つまで無料。GitHubの規約上、マシンアカウントは
   作成した人が責任を持つ)。2要素認証を有効にする
2. **このリポジトリのcollaboratorに招待する**(Settings → Collaborators → Add people、権限 **Write**)。
   botでログインして招待を承諾する。CODEOWNERSには**入れない**(入れると本番の承認ゲートにならない)
3. **非公開の取り込み元リポジトリに、botを読み取り(Read)で追加してもらう**。`1-dev-update` が
   最新コミットを取りに行く(`latest-src-ref`)ため。無いアプリは、ジョブの `src_ref` にSHAを
   指定すれば動く(取得を飛ばす)
   | 取り込み元 | 持ち主 |
   |---|---|
   | `silver198545/metadatabase-v2` | 管理者(自分で追加できる) |
   | `PENQEinc/riken_brc_advanced_search`・`PENQEinc/riken-diips` | PENQEinc(依頼する) |
   | `d-usuda/brc-cross-search` | d-usuda(依頼する) |
   | `dbcls/sparqlist` | 公開のため不要 |
4. **踏み台端末に専用OSユーザーを作る**:
   ```bash
   sudo adduser --disabled-password --gecos 'ibid-fleet-config pipeline' ibidops
   sudo install -m 755 ~uchida/.local/bin/kubeseal /usr/local/bin/kubeseal   # ibidopsからも使えるように
   sudo -iu ibidops
   git clone https://github.com/silver198545/ibid-fleet-config.git ~/ibid-fleet-config
   cd ~/ibid-fleet-config
   git config user.name '<bot>'
   git config user.email '<botのID>+<bot>@users.noreply.github.com'   # GitHubの設定 → Emails に出る値
   gh auth login --hostname github.com --git-protocol https --web   # ブラウザでbotとしてログイン
   gh auth setup-git
   gh auth status                                                   # botで、repo・workflow スコープがあること
   ```
   fine-grained PATは他人(個人アカウント)のリポジトリのcollaboratorとしては使えないため、
   `gh auth login`(またはbotのclassic PAT。スコープ `repo`・`workflow`・`read:org`)を使う
5. **kubeconfigを置く**: `dev1`/`prod1` のコンテキストを `~ibidops/.kube/config`(パーミッション600)に置く
   ([manual-tooling-setup.md](manual-tooling-setup.md))。クラスタ側の権限はそのkubeconfigのトークンの
   持ち主のものになる(Rancherにパイプライン用のユーザーを作って分けるのは今後の課題)
6. **`PROMOTE_TOKEN` をbotのトークンに替える**(promoteワークフローのPRの作成者をbotにするため):
   botでclassic PAT(スコープ `repo`・`workflow`、期限付き)を作り、
   `gh secret set PROMOTE_TOKEN --repo silver198545/ibid-fleet-config` で登録する
   ([manual-multi-env.md](manual-multi-env.md)「1. GitHub側の初期設定」)。期限が切れる前に作り直す
7. **Rundeckのノードを追加する**: `rancher.ibid.lan` に `ibidops` でSSHするノード(例: `rancher-ops`、
   タグ `ibid-ops`)を登録し、その公開鍵を `~ibidops/.ssh/authorized_keys` に置く。既存の `uchida` の
   ノード(タグ `rancher`)はジョブから使わなくなる
8. **ジョブを取り込み直す**(下記「取り込み・更新」)。実行先が `ibid-ops` タグのノードに替わる
9. **オペレータのRundeck権限をジョブの実行だけにする**。アドホックコマンド(Commands画面)を許すと、
   オペレータが `ibidops` として任意のコマンドを実行でき、botのトークンやkubeconfigを直接使えてしまう。
   プロジェクトのACLの例(グループ名は実際のものに合わせる):
   ```yaml
   description: オペレータはジョブの閲覧・実行のみ
   context:
     project: Rancher-AppControll
   for:
     resource:
       - equals: { kind: job }
         allow: [read]
       - equals: { kind: node }
         allow: [read]
       - equals: { kind: event }
         allow: [read]
     job:
       - allow: [read, view, view_history, run]
     node:
       - allow: [read, run]
     adhoc:
       - deny: [run]
   by:
     group: ibid-operators
   ```
   (アプリケーション側のACLでプロジェクトの `read` も要る。Rundeckの版によって書式が違うので、
   入れたあとオペレータでログインしてCommands画面が使えないことを確かめる)

### 確認

- `ibidops` で `apps/<app>/9-check` と `wordpress/tools/check` が通る(GitHubを使わない)
- `apps/<app>/1-dev-update` を実行すると、PRの作成者がbot、本文の最後に「実行者: <Rundeckのユーザー>」が入り、
  auto-mergeされる
- `2-production-update` / `3-production-promote` の本番PRが、Approveしないとマージできない
  (Mergeボタンが「Review required」になる)

## 取り込み・更新

```bash
python3 rundeck/generate-jobs.py        # 定義を作り直す(アプリ・サイトの追加・削除のあと)
rd jobs load -p <プロジェクト名> -f rundeck/jobs/apps.yaml --format yaml
rd jobs load -p <プロジェクト名> -f rundeck/jobs/wordpress.yaml --format yaml
```

- ジョブのUUIDはグループ・名前から決まるので、取り込み直すと同じジョブが更新される
- `rd jobs load` は定義から消えたジョブを削除しない。旧定義のグループ `app-image-update` と、
  消したアプリのグループは、Rundeck UIで手動で削除する
- 生成内容は `envs/dev/apps`・`envs/dev/sites`(`-rh`を除く)と `update-app-image.sh` の
  `persistent_data_dir_for` だけで決まる。`validate` ワークフローが生成結果との一致を確かめるので、
  アプリ・サイトを追加したPRでは再生成したファイルも一緒にコミットする
  (`scripts/new-wordpress-site.sh dev <site>` は自動で再生成する)。本番への昇格では変わらない
- rancherホストには `rd` CLIが無い。Rundeck UIの「ジョブのアップロード」(YAML)か、`rd` のある端末で取り込む

## 自作アプリ(`apps/<app>/`)

### 1-dev-update(開発環境更新パイプライン)

1. mainを最新化
2. `src_ref` が空なら取り込み元ブランチの最新コミットを使う。現在の `images/<app>/SRC_REF` と同じなら
   イメージは更新せず、devの確認だけ行って終わる
3. 違えば `set-image`: イメージPR → auto-merge → ビルド完了待ち → devの `deployment.yaml` を更新するPR →
   auto-merge → devのrollout・WEB疎通(readinessProbeのpathで200か)の確認
4. (sparqlistのみ。`sync_prod_data=yes` のとき)本番の永続データ(`repository/`)をdevへコピー。
   **devの内容は上書きされる**。対象は `persistent_data_dir_for` に登録したアプリで、
   登録すると次の再生成でこのオプションが付く

| オプション | 既定 | 説明 |
|---|---|---|
| `src_ref` | 空(最新) | 取り込み元のコミットSHA。特定のコミットを入れたいときだけ指定 |
| `tag` | 空(自動採番) | 現在のTAGが `<version>-r<N>` なら N+1。その形式でないアプリでは指定が要る |

終わったらブラウザでdevを確認してから `2-production-update` へ。

### 2-production-update(本番環境更新パイプライン)

1. mainを最新化
2. devと本番の `<app>` に差分があれば、promoteワークフロー(`kind=apps`)で昇格PRを作り、CIを待つ
   (差分が無ければ4.へ)
3. **人がPRのdiffを見てマージするのを待つ**(イメージタグ以外のdevの変更もすべて昇格対象になる)
4. mainを取り込み、Fleetの適用を待って(60秒)、本番のrollout・WEB疎通を確認する

### 3-first-promote-prepare / 4-first-promote-finish(本番への初回昇格)

本番にまだ無いアプリのときだけ使う(既にあれば `2-production-update`)。
`prepare` はコピーまでで止まり、表示された `kubeseal` コマンドを**踏み台端末で人が実行して**
`envs/production/secrets/<app>.yaml` を作ってから `finish` を実行する(PATを扱うため)。
`finish` が作ったPRは人がマージし、`9-check`(`env=production`)で確認する。

**`prepare` から `finish` までの間、クローンは未コミットの変更を持ったまま残る。** その間、
他のジョブは最初の「mainを最新化」で止まる(壊れることはない)。

### 9-check

devまたは本番のrollout状況とWEB疎通を確認する(読み取りのみ)。

## WordPress(`wordpress/`)

### 1-dev-refresh(開発環境更新パイプライン: 本番コンテンツ → dev)

選んだサイトごとに:

1. 本番のバックアップを今すぐ取る(日次バックアップのCronJobから。`fresh_backup=no` なら最新の
   日次バックアップ(JST 3:00)を使う)
2. devの現状をバックアップする(上書き前の状態。NFSの `backup/dev/wordpress-<site>/` に残る)
3. 本番のwp-content・DBをdevの同名サイトへリストアする(`scripts/restore-wordpress.sh`)
4. DBに残る本番の公開URLを、devの公開URL(`wp-config.php` の `WP_HOME`。devは
   `https://wpdev1.brc.riken.jp/<ja|en>`)へ置換する。ホスト名単位で、`http`/`https`/スキーム無し
   (`//<host>/`)/JSONエスケープ(`https:\/\/<host>`)の形をまとめて置換し、`guid` 列は除く
   ([manual-wordpress-restore.md](manual-wordpress-restore.md) 6b.と同じ)。他サイトのドメインへの
   リンクは置換しない
5. HTTP 200とPodを確認し、成功したら退避した旧wp-content(`wp-content.orig`)を消す。
   確認に失敗したサイトは `wp-content.orig` を残す

gitは触らないので、チャート版・プラグイン(構成)はdevのまま。**devの記事・設定・ユーザーは
本番のもので上書きされる**(ログインも本番のアカウントになる)。全サイトを選ぶと数時間かかる。
前回の `wp-content.orig` が残っているサイトがあると、最初に止まる(中身を確認して消してから再実行)。

### 2-rehearsal(本番データのリハーサル)

WordPress本体・MariaDBのメジャー更新、プラグインの大きな更新を本番へ出す前に行う
([operations-flow.md](operations-flow.md)「本番データリハーサル」の手順をそのまま自動化したもの)。

1. mainを最新化
2. **rehearsal-start**: `envs/production/sites/<site>` と同じ構成の `<site>-rh` をdev1に作るPR
   (`rehearsal-site.sh <site> production` + `seal-site-secrets.sh dev <site>-rh`)→ auto-merge →
   Fleetの適用待ち → 本番のバックアップ → `<site>-rh` へリストア・URL置換 →
   **比較の基準**を記録する(トップと最近更新された10ページのHTTPステータス、WordPress・プラグイン・
   テーマの版、`mariadb_upgrade_info`)
3. **rehearsal-upgrade**(`upgrade=yes` のとき): `<site>-rh` をdevの構成(昇格予定の `helm.version`・
   `plugins`)へ切り替えるPR → auto-merge → Helmリビジョンの更新とrolloutを待つ →
   プラグイン同期Jobの成否と所要時間 → `wp core update-db`(管理画面の「データベースの更新」と同じ)の
   所要時間 → 基準との比較(版の差分、HTTPステータスが変わったページ)→ 直近のPHPエラー

devと本番の構成に差分が無ければ、3.は何もせず終わる。HTTPステータスが変わったページ・
プラグイン同期Jobの失敗があるとジョブは失敗になる。結果(所要時間・気づいた点)は昇格PRに書く。
ブラウザでの確認(記事表示・管理画面・プラグイン固有の画面)も行うこと。

- dev1のメモリの都合で、**リハーサルサイトは同時に1つまで**(他の `-rh` があると止まる)
- 比較の基準は踏み台端末の `~/.local/state/ibid-fleet-config/rehearsal/<site>-rh/` に置く
- 問題があればdevで直し、`2a-rehearsal-upgrade` で切り替えからやり直す
  (`2-rehearsal` を `upgrade=no` で実行した場合もこれで続ける)
- **終わったら必ず `2b-rehearsal-cleanup`**: `<site>-rh` をGitから消すPR(auto-merge)→ マージ後に
  `wordpress-<site>-rh` namespaceを削除(本番データのコピーが消える)。harvesterのPVが
  `Released` のまま残ったら警告が出るので [roadmap.md](roadmap.md) 項目8の手順で片付ける

### 3-production-promote(本番昇格パイプライン)

1. mainを最新化
2. 選んだサイト(`all` は本番に既にある全サイト)のうち、devと本番で差分のあるものの昇格PRを
   promoteワークフローで作り、CIを待つ。差分が無ければ確認だけ行って終わる
3. **対象サイトの本番バックアップを取り**(本番反映前のバックアップ。
   [operations-flow.md](operations-flow.md))、取得したファイル名をPRにコメントする
4. **人がPRのdiffを見てマージするのを待つ**(diffが devで確認した `helm.version`・`plugins` の
   `version` 等だけであること)。バックアップから長く時間が空いた場合は、マージの前に
   `wordpress/tools/backup` で取り直す
5. mainを取り込み、各サイトのHelmリビジョンが上がってrolloutが終わるのを待つ
6. 本番のHTTP 200・Pod・MariaDBのアップグレード状況(`mariadb_upgrade_info`)を確認する

devにしか無いサイトを本番へ追加するときは、サイト名を選ぶ(`all` では追加されない)。
先に `scripts/seal-site-secrets.sh production <site>` のSecretをmainに入れておくこと(無いと止まる)。
DBマイグレーションを伴う更新なら、先に `2-rehearsal` を済ませておく。

### tools/backup・tools/check

- `backup`: 日次バックアップのCronJobから今すぐ1つ取る(完了まで待つ)
- `check`: HTTPステータスと正常でないPodの確認(読み取りのみ)

## ジョブにしていないもの

- **GHCR pull用SealedSecretの作成**(アプリの初回昇格)、本番サイトの新規Secret
  (`seal-site-secrets.sh production`、パスワードを控える必要がある): 人が端末で実行する
- **本番に触れるPRのマージ**: 常に人がGitHubで行う(パイプラインは待つだけ)
- **WordPressのチャート・プラグインの更新をdevに入れる作業**: `auto-update` ワークフローが毎週行う
  ([runbook/wordpress-update.md](runbook/wordpress-update.md))。手で入れるときは `bump-chart.sh`・
  `bump-plugins.sh`
- **プラグインの削除**、外部nginxの切り替え: 手順書どおり手で行う
