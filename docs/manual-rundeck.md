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
  確認まで続ける。オペレータやマシンユーザー(promoteワークフロー)が作った本番PRは、
  Code Ownerの承認が無いとマージできない(下記「実行アカウント」)。待ち時間を過ぎるとジョブは失敗で終わる(PRは残るので、マージ後に
  `9-check` / `wordpress/tools/check` で確認する)
- **devだけに触れるPRはauto-merge**する(イメージ更新、リハーサルサイトの追加・削除)
- **同じクローンを使うジョブは排他する**。gitのブランチを切り替える処理は
  `.git/ibid-pipeline.lock` のロック(`scripts/lib/pr.sh` の `pr_lock_repo`)を取ってから行う。
  本番PRのマージ待ちやリストアの間はロックを手放すので、その間も他のジョブは動ける
- **秘密情報はジョブで扱わない**。GHCR pull用SealedSecret(PAT)の作成はジョブにしない
  (アプリの初回昇格のときだけ人が実行する)。リハーサルサイトの新規パスワードは
  ログに出さない(`SEAL_HIDE_PASSWORDS=1`)

## 前提

- ジョブは踏み台端末(`rancher`ホスト、Rundeckノードタグ `rancher`)へ、**ジョブを実行した人のOSユーザー**
  としてSSHで実行する(ノードの `username` が `${job.username}`。Rundeckのログイン名=サーバーのユーザー名)。
  GitHub・kubectlの操作もその人自身のアカウントで行われる(下記「実行アカウント」)
- 各ユーザーのホームに `~/ibid-fleet-config` のクローンがあり、そのユーザーで `git`/`gh`/`kubectl`/
  `kubeseal`/`flock` が使え、`gh auth status` が本人のGitHubアカウントで認証済み、`~/.kube/config` に
  `dev1`/`prod1` があること([manual-tooling-setup.md](manual-tooling-setup.md))
- WordPressのジョブ(dev-refresh・リハーサル)は、バックアップNFSを踏み台端末に**読み取り専用で
  マウント**しておく(`/mnt/ibid-nfs`。[manual-wordpress-restore.md](manual-wordpress-restore.md)
  「日次バックアップ」)。再起動で外れるので、外れていたらジョブが案内を出して止まる:
  ```bash
  sudo mkdir -p /mnt/ibid-nfs && sudo mount -t nfs -o ro,nfsvers=4.1 192.168.1.1:/data/nfs /mnt/ibid-nfs
  ```
  リストアはwp-contentを踏み台端末の `/tmp` で展開し直すため、最大のサイトのwp-content
  (2026-10時点で圧縮470MB)の数倍の空きが要る
- リハーサルの比較の基準は `/var/lib/ibid-fleet-config/rehearsal`(FreeIPAのグループ `wpadmins` で共有)に置く。
  始めた人と続き(`2a-rehearsal-upgrade`・`2b-rehearsal-cleanup`)を実行する人が違ってもよい
- クローンのパス(`$HOME/ibid-fleet-config`)とノードフィルタ(`tags: rancher`)は `generate-jobs.py` の
  `REPO_PATH`・`NODE_FILTER`。別ホストへ持っていくときはそこを変えて再生成する
- ロック(`.git/ibid-pipeline.lock`)はクローンごと。別の人のジョブ同士は排他しないが、同じジョブの
  同時実行はRundeck(`multipleExecutions: false`)が止める
- Rundeck本体の設定(プロジェクト・ノード登録・SSH鍵・ACL)はこのリポジトリでは扱わない(下記に必要な設定だけ書く)

## 実行アカウント

2026-10-16から、Rundeckのジョブは**実行した人自身のOSユーザー・GitHubアカウント・kubeconfig**で動く。
それまでは誰が実行しても `uchida` ユーザー=管理者 `silver198545` のトークンで動いており、全操作が
管理者の操作として記録され、本番PRも「作成者=唯一のCode Owner」なので承認なしでマージできた。

- **オペレータが作った本番PR(`envs/production/` に触れるPR)は、Code Owner(`@silver198545`)の
  承認(Approve)がないとマージできない**。オペレータはwrite権限のcollaboratorでCode Ownerではなく、
  ルールセットの管理者バイパスも使えない。本番パイプラインはPRを作ってこの承認・マージを待つ
  (承認者はPRを開いて **Approve → Merge**)。管理者自身がRundeckで実行したPRは管理者のPRなので、従来どおり承認は不要
- devだけに触れるPRは、Code Ownerの対象外なので今までどおりauto-mergeする
- **promoteワークフローが作るPR**(アプリ・サイトの本番昇格)の作成者は、誰が起動しても `PROMOTE_TOKEN` の
  持ち主になる。管理者のPATだと「作成者=Code Owner」に戻ってしまうため、**マシンユーザー `ibid-ops-bot`**
  (write権限のcollaborator、CODEOWNERS外)のトークンにする。このため**管理者が起動した昇格PRも、
  Approveしてからマージする**(作成者がbotなので自分で承認できる)。botはこのトークン以外には使わない
- PR本文には、Rundeckから実行したことと実行者(`PIPELINE_ACTOR`)も残る

### 最初に1回だけ(管理者)

1. **マシンユーザー `ibid-ops-bot`**(2026-10-16作成・collaborator承諾済み)のclassic PATを作る
   (botでログインし、Settings → Developer settings → Personal access tokens (classic)、スコープ `repo`、
   期限付き。fine-grained PATは他人の個人アカウントのリポジトリでは使えない)。
   `gh secret set PROMOTE_TOKEN --repo silver198545/ibid-fleet-config` で登録する。期限が切れる前に作り直す
2. **基準の置き場所を作る**。ユーザーとグループはFreeIPAで管理しており(SSSD経由)、共有グループには
   FreeIPAのPOSIXグループ `wpadmins` を使う(2026-10-16時点のメンバー: hoge, uchida, iwase, kurihara, namiki, yuhara)。
   `getent group wpadmins` で見えることを確かめてから:
   ```bash
   sudo install -d -m 2775 -g wpadmins /var/lib/ibid-fleet-config/rehearsal
   sudo install -m 755 ~uchida/.local/bin/kubeseal /usr/local/bin/kubeseal   # 全ユーザーで使えるように
   ```
   グループのメンバーはログインした時点で決まるため、追加直後のシェルの `id` には出ない(Rundeckのジョブは
   毎回新しくログインするので問題ない)。グループが見えないときは、FreeIPAでPOSIXグループになっているか
   (`ipa group-show wpadmins` に `GID:` があるか)と、SSSDのキャッシュ(`sudo sss_cache -G`)を確かめる
3. **Rundeckのノード `rancher` のSSHユーザーを実行者にする**。ノード実行はOpenSSHを呼ぶ方式(`ssh-exec`)なので、
   ノードの `username`・鍵はコマンドラインで渡り、Rundeckサーバー(Rundeckが動くOSユーザー)の
   `~/.ssh/config` の `User` より優先される。ホスト名と踏み台はsshconfigから、ユーザーと鍵は実行者から取る形にする。
   リソース定義(2026-10-16時点の実際の値):
   ```yaml
   rancher:
     nodename: rancher
     hostname: rancher
     username: ${job.username}
     tags: rancher
     osFamily: unix
     ssh-authentication: privateKey
     ssh-key-storage-path: keys/users/${job.username}/${job.username}_ed25519
   ```
   Rundeckサーバーの `~/.ssh/config`(`hostname: rancher` に一致させる。**`Host rancher` に `User`・`IdentityFile` を書かない**):
   ```sshconfig
   Host Bastion
       HostName knowledge.brc.riken.jp
       User uchida
       IdentityFile ~/.ssh/uchida_ed25519
       IdentitiesOnly yes

   Host rancher
       HostName 192.168.1.149
       ProxyCommand ssh -W %h:%p Bastion
       IdentitiesOnly yes
   ```
   `IdentitiesOnly yes` はssh-agentや既定の鍵を次々に試して `Too many authentication failures` になるのを防ぐ。
   **踏み台(Bastion)までは全員 `uchida` として転送される**(rancher上の操作は本人の権限。踏み台のログには
   `uchida` と残る)。分けるなら、踏み台に転送専用のアカウントを作り、`authorized_keys` を
   `restrict,port-forwarding,permitopen="192.168.1.149:22" ssh-ed25519 ...` にして `Host Bastion` の `User` をそれにする。
   SSH鍵は人ごとにKey Storageの `keys/users/<ユーザー名>/<ユーザー名>_ed25519` に置き、Rundeckのログイン名と
   サーバーのユーザー名を必ず揃える
4. **管理者自身(`uchida`)の鍵を置く**: 公開鍵が `~uchida/.ssh/authorized_keys` にあり、秘密鍵がKey Storageの
   `keys/users/uchida/uchida_ed25519` にあること。まず `uchida` で `apps/<app>/9-check` を実行し、rancherの
   `journalctl -u ssh` に `Accepted publickey for uchida` と出ることを確かめる
5. ジョブを取り込み直す(下記「取り込み・更新」)

### オペレータを追加する

オペレータは担当ごとにFreeIPAのグループで分け、Rundeck・Rancherの権限もグループに付ける。

| 担当 | FreeIPAのグループ | Rundeckで実行できるジョブ | クラスタの権限 |
|---|---|---|---|
| 自作アプリ | `publicdb_developer` | `apps/*` だけ | 下記「自作アプリのオペレータ」 |
| WordPress | `wpadmins` | (未整備。2026-10-16時点で管理者のみ) | (未整備) |

以下は1人ごとの手順(担当によらず共通)。担当ごとの1回だけの設定は、その後の節にある。

`<op>` はオペレータのサーバー上のユーザー名(=Rundeckのログイン名)、`<op-gh>` はそのGitHubアカウント。

1. **GitHub**: `silver198545` で https://github.com/silver198545/ibid-fleet-config/settings/access から `<op-gh>` を招待し、
   本人が承諾する(個人アカウントのリポジトリなので権限はwrite固定)。2要素認証を有効にしてもらう。
   **CODEOWNERSには入れない**(入れると、その人の本番PRが承認なしでマージできてしまう)
2. **非公開の取り込み元**: `1-dev-update` を `src_ref` 空欄(最新を取得)で使うなら、`<op-gh>` に読み取り権限が要る。
   無ければ `src_ref` にSHAを指定すれば動く(取得を飛ばす)
   | 取り込み元 | 持ち主 | 付けられる権限 |
   |---|---|---|
   | `PENQEinc/riken_brc_advanced_search`・`PENQEinc/riken-diips` | 組織(依頼する) | Readを選べる |
   | `d-usuda/brc-cross-search` | 個人(依頼する) | write固定 |
   | `silver198545/metadatabase-v2` | 管理者 | write固定 |
   | `dbcls/sparqlist` | 公開 | 不要 |
3. **サーバーのユーザー**: FreeIPAのユーザー `<op>` がrancherにログインでき(HBAC)、担当のグループに入っていること
   (`ipa group-add-member <グループ> --users=<op>`。`getent group <グループ>` で確かめる)。WordPressのリハーサルを
   実行する人は `wpadmins` にも入れる(比較の基準の置き場所に書くため)
4. **本人のクローンとGitHub認証**(`<op>` でログインして本人が行う):
   ```bash
   git clone https://github.com/silver198545/ibid-fleet-config.git ~/ibid-fleet-config
   cd ~/ibid-fleet-config
   git config user.name '<op-gh>'
   git config user.email '<ID>+<op-gh>@users.noreply.github.com'   # GitHubのSettings → Emails に出る値
   gh auth login --hostname github.com --git-protocol https --web   # 本人のGitHubアカウントで
   gh auth setup-git
   gh auth status                                                   # repo・workflow・read:org スコープがあること
   ```
5. **kubeconfig**: 本人がRancher(https://192.168.1.149、FreeIPAでログイン)にログインし、クラスタ一覧の `dev1`・`prod1`
   それぞれの「Download KubeConfig」で取得して、`~<op>/.kube/config`(パーミッション600)に1つにまとめる。
   コンテキスト名はRancherのクラスタ名(`dev1`・`prod1`)になるので、そのまま使える
   ([manual-tooling-setup.md](manual-tooling-setup.md))。クラスタで何ができるかは、担当のグループに付けた
   Rancherの権限で決まる。**トークンの有効期限は30日**(Rancherの `kubeconfig-default-token-ttl-minutes`=43200)
   なので、切れたら同じ手順で取り直す(ジョブが `Unauthorized` で止まる)
6. **Rundeck**: ログイン名 `<op>` のユーザーを作り、Rundeck用のSSH鍵を作って公開鍵を `~<op>/.ssh/authorized_keys` に、
   秘密鍵をKey Storageの `keys/users/<op>/<op>_ed25519` に登録する
7. **(推奨)Rundeckの権限をジョブの実行に絞る**。アドホックコマンド(Commands画面)を使われても本人の権限で
   動くだけだが、作業の記録をジョブの実行履歴に揃えるため。プロジェクトのACLの例(グループ名は実際のものに合わせる):
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
   入れたあとオペレータでログインして確かめる)

### 自作アプリのオペレータ(グループ `publicdb_developer`)の1回だけの設定

`apps/<app>/` のジョブ(dev更新・本番更新・初回昇格・確認)だけを実行できるようにする。2026-10-16時点のメンバーは
`uchida, kushida, usuda, hoge, manalili, yuki`(最初に追加するオペレータは usuda)。

1. **Rancherに「apps」プロジェクトを作り、アプリのnamespaceを移す**(dev1・prod1 それぞれ)。
   Rancher UIで クラスタ → **Projects/Namespaces** → Create Project(名前 `apps`)→ 次のnamespaceを
   「Move」で `apps` へ移す:
   `brc-advanced-search`、`brc-cross-search-resource`、`brc-cross-search-xsearch`、`metadatabase-v2`、`riken-diips`、`sparqlist`。
   - 割り当てはRancherがnamespaceに付ける注釈(`field.cattle.io/projectId`)で、Gitでは管理していない
     (バンドルは `defaultNamespace` でnamespaceを作るだけで、Namespaceのマニフェストを持たないため、Fleetが外すことはない)。
     **アプリを新しく追加したとき**([runbook/app-new.md](runbook/app-new.md))と、**DR等でnamespaceを作り直したとき**は移し直す
2. **プロジェクト `apps` のメンバーにFreeIPAのグループ `publicdb_developer` を加える**(Project → Members → Add、
   グループを検索して選ぶ):
   | クラスタ | ロール | できること |
   |---|---|---|
   | `dev1` | **Project Member** | Podへのexecを含めて、アプリのnamespaceを操作できる |
   | `prod1` | **Read-only** | 見るだけ(rollout・Podの確認、`9-check`、本番更新パイプラインの最後の確認) |

   prod1がRead-onlyなので、**sparqlistの `1-dev-update` を `sync_prod_data=yes` で実行すると、本番Podへのexecで止まる**
   (本番データのコピーは管理者が行う)。WordPressのnamespaceやSealed Secretsの鍵には触れられない
3. **RundeckのACL**(RundeckもFreeIPAでログインするので、グループ名がそのままRundeckのロールになる)。
   `apps/` 以下のジョブだけを許し、WordPressのジョブとアドホックコマンドは許さない。プロジェクトのACL:
   ```yaml
   description: publicdb_developer は自作アプリ(apps/)のジョブの閲覧・実行のみ
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
       - match: { group: '^apps(/.*)?$' }
         allow: [read, view, view_history, run]
     node:
       - allow: [read, run]
     adhoc:
       - deny: [run]
   by:
     group: publicdb_developer
   ```
   アプリケーションのACL(プロジェクトを見られることと、**自分の**SSH鍵だけを使えること。人を足すたびに `storage` に1行足す):
   ```yaml
   description: publicdb_developer のプロジェクト参照と鍵の利用
   context:
     application: rundeck
   for:
     project:
       - equals: { name: Rancher-AppControll }
         allow: [read]
     storage:
       - match: { path: '^keys/users/usuda(/.*)?$' }
         allow: [read]
   by:
     group: publicdb_developer
   ```
   (`storage` の `read` は、ジョブの中で鍵を使う権限で、秘密鍵の中身を表示できるわけではない。他人の鍵を
   読めないよう、パスはユーザーごとに書く。Rundeckの版によって書式が違うので、入れたあと本人でログインし、
   `apps/` のジョブだけが見えること、`wordpress/` とCommands画面が使えないことを確かめる)

### 確認(オペレータを追加したら)

- `<op>` で `apps/<app>/9-check` と `wordpress/tools/check` が通る(SSH・kubeconfigの確認)
- `apps/<app>/1-dev-update` を実行すると、PRの作成者が `<op-gh>` になり、auto-mergeされる
- `2-production-update` / `3-production-promote` の本番PRが、`@silver198545` がApproveしないとマージできない
  (Mergeボタンが「Review required」になる)
- (自作アプリのオペレータ)本人のkubeconfigで `kubectl --context prod1 -n sparqlist delete pod --dry-run=server -l app=sparqlist`
  が `forbidden` になり、`kubectl --context dev1 get ns` にWordPressのnamespaceが出ない

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
