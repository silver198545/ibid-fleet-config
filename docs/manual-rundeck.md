# Rundeckのパイプライン(自作アプリ・WordPress)

日常の更新作業を、Rundeckのジョブ1つ(=パイプライン1本)で最後まで流せるようにしたもの。
ジョブの定義は [rundeck/jobs/apps.yaml](../rundeck/jobs/apps.yaml) と
[rundeck/jobs/wordpress.yaml](../rundeck/jobs/wordpress.yaml) で、どちらも
[rundeck/generate-jobs.py](../rundeck/generate-jobs.py) が生成する(**直接編集しない**)。

オペレータ向けの手順書(ジョブの使い方だけ。Redmine用のTextile版もある):
[runbook/rundeck-app-operator.md](runbook/rundeck-app-operator.md)(自作アプリ)、
[runbook/rundeck-wordpress-operator.md](runbook/rundeck-wordpress-operator.md)(WordPress)。
ジョブやスクリプトの動きを変えたら、これらも直す。

Rundeckのプロジェクトは担当ごとに分けている(2026-10-17から)。以下、ジョブは「プロジェクト内のグループ/ジョブ名」で書く。

| Rundeckのプロジェクト | 定義ファイル | 実行する人(FreeIPAのグループ) |
|---|---|---|
| `Rancher-AppControll` | `rundeck/jobs/apps.yaml` | `publicdb_developer` |
| `WordPressControl` | `rundeck/jobs/wordpress.yaml` | `wpadmins`(オペレータは未整備。2026-10-17時点で管理者のみ) |

| パイプライン | Rundeckのジョブ | 中身(手動でも同じことができる) |
|---|---|---|
| 自作アプリの開発環境更新 | `Rancher-AppControll` の `<app>/1-dev-update` | `scripts/update-app-image.sh dev-update <app>` |
| 自作アプリのstaging更新 | `Rancher-AppControll` の `<app>/2-staging-update` | `scripts/update-app-image.sh staging-update <app>` |
| 自作アプリの本番環境更新 | `Rancher-AppControll` の `<app>/3-production-update` | `scripts/update-app-image.sh release-production <app>` |
| WordPressの開発環境更新(本番コンテンツ → dev) | `WordPressControl` の `1-dev-refresh` | `scripts/wordpress-pipeline.sh dev-refresh <site>...` |
| WordPressのstagingでの確認(本番データ) | `WordPressControl` の `2-staging` | `scripts/wordpress-pipeline.sh staging-start` / `staging-upgrade <site>` |
| WordPressのstagingの後片付け | `WordPressControl` の `4-staging-cleanup` | `scripts/wordpress-pipeline.sh staging-cleanup <site>` |
| WordPressの本番昇格 | `WordPressControl` の `3-production-promote` | `scripts/wordpress-pipeline.sh promote-production <site...\|all>` |

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
  `<app>/9-check` / `tools/check` で確認する)
- **dev・stagingだけに触れるPRはauto-merge**する(イメージ更新、stagingへのサイトの追加・昇格・削除)
- **同じクローンを使うジョブは排他する**。gitのブランチを切り替える処理は
  `.git/ibid-pipeline.lock` のロック(`scripts/lib/pr.sh` の `pr_lock_repo`)を取ってから行う。
  本番PRのマージ待ちやリストアの間はロックを手放すので、その間も他のジョブは動ける
- **秘密情報はジョブで扱わない**。GHCR pull用SealedSecret(PAT)の作成はジョブにしない
  (アプリの初回昇格のときだけ人が実行する)。stagingのサイトの新規パスワードは
  ログに出さない(`SEAL_HIDE_PASSWORDS=1`)

## 前提

- ジョブは踏み台端末(`rancher`ホスト、Rundeckノードタグ `rancher`)へ、**ジョブを実行した人のOSユーザー**
  としてSSHで実行する(ノードの `username` が `${job.username}`。Rundeckのログイン名=サーバーのユーザー名)。
  GitHub・kubectlの操作もその人自身のアカウントで行われる(下記「実行アカウント」)
- 各ユーザーのホームに `~/ibid-fleet-config` のクローンがあり、そのユーザーで `git`/`gh`/`kubectl`/
  `kubeseal`/`flock` が使え、`gh auth status` が本人のGitHubアカウントで認証済み、`~/.kube/config` に
  `dev1`/`staging1`/`prod1` があること([manual-tooling-setup.md](manual-tooling-setup.md))
- WordPressのジョブ(dev-refresh・staging)は、バックアップNFSを踏み台端末に**読み取り専用で
  マウント**しておく(`/mnt/ibid-nfs`。[manual-wordpress-restore.md](manual-wordpress-restore.md)
  「日次バックアップ」)。再起動で外れるので、外れていたらジョブが案内を出して止まる:
  ```bash
  sudo mkdir -p /mnt/ibid-nfs && sudo mount -t nfs -o ro,nfsvers=4.1 192.168.1.1:/data/nfs /mnt/ibid-nfs
  ```
  リストアはwp-contentを踏み台端末の `/tmp` で展開し直すため、最大のサイトのwp-content
  (2026-10時点で圧縮470MB)の数倍の空きが要る
- stagingでの比較の基準は `/var/lib/ibid-fleet-config/rehearsal`(FreeIPAのグループ `wpadmins` で共有。パスは
  dev1のリハーサルサイト時代のまま)に置く。始めた人と続き(`2a-staging-upgrade`・`4-staging-cleanup`)を実行する人が違ってもよい
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
   **ノードの定義は、プロジェクト(`Rancher-AppControll`・`WordPressControl`)ごとに要る**(Rundeckのノードは
   プロジェクト単位のため。同じ内容でよい)。リソース定義(2026-10-23時点の実際の値):
   ```yaml
   rancher:
     nodename: rancher
     hostname: rancher
     ssh-key-storage-path: keys/users/${job.username}/${job.username}_ed25519
     osFamily: unix
     osArch: amd64
     osName: Linux
     description: RancherServer
     ssh-authentication: privateKey
     username: ${job.username}
     tags: rancher
   ```
   **ログインユーザーごとの変数 `${job.username}`** を `username` と `ssh-key-storage-path` に入れるのが要点。
   ジョブを実行したRundeckのログイン名がそのまま入るので、SSHのユーザーも使う鍵も実行者のものになる
   (ノードを人ごとに作らなくてよい)。鍵を他人に使わせないのは、Key Storageの個人ACL(下記「オペレータを追加する」の7)で行う
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
   `keys/users/uchida/uchida_ed25519` にあること。まず `uchida` で `Rancher-AppControll` の `<app>/9-check` を実行し、rancherの
   `journalctl -u ssh` に `Accepted publickey for uchida` と出ることを確かめる
5. ジョブを取り込み直す(下記「取り込み・更新」)

### オペレータを追加する

オペレータは担当ごとにFreeIPAのグループで分け、Rundeck・Rancherの権限もグループに付ける。

| 担当 | FreeIPAのグループ | Rundeckで実行できるジョブ | クラスタの権限 |
|---|---|---|---|
| 自作アプリ | `publicdb_developer` | プロジェクト `Rancher-AppControll` のジョブ | 下記「自作アプリのオペレータ」 |
| WordPress | `wpadmins` | プロジェクト `WordPressControl` のジョブ | 下記「WordPressのオペレータ」 |

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
   (`ipa group-add-member <グループ> --users=<op>`。`getent group <グループ>` で確かめる)。WordPressのstagingでの確認を
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
5. **kubeconfig**: 本人がRancher(https://rancher.brc.riken.jp/ 、FreeIPAでログイン)にログインし、クラスタ一覧の `dev1`・`staging1`・`prod1`
   それぞれの「Download KubeConfig」で取得して、`~<op>/.kube/config`(パーミッション600)に1つにまとめる。
   コンテキスト名はRancherのクラスタ名(`dev1`・`staging1`・`prod1`)になるので、そのまま使える
   ([manual-tooling-setup.md](manual-tooling-setup.md))。クラスタで何ができるかは、担当のグループに付けた
   Rancherの権限で決まる。**トークンの有効期限は30日**(Rancherの `kubeconfig-default-token-ttl-minutes`=43200)
   なので、切れたら同じ手順で取り直す(ジョブが `Unauthorized` で止まる)
6. **Rundeck**: ログイン名 `<op>` のユーザーを作り、Rundeck用のSSH鍵を作って公開鍵を `~<op>/.ssh/authorized_keys` に、
   秘密鍵をKey Storageの `keys/users/<op>/<op>_ed25519` に登録する
7. **Rundeckの権限**: 担当のプロジェクトのジョブだけを実行できるようにする(プロジェクトのACLとシステム側のACLは
   グループ単位で、担当ごとの節に書く。人を足すだけなら触らない)。アドホックコマンド(Commands画面)は許さない。
   使われても本人の権限で動くだけだが、作業の記録をジョブの実行履歴に揃えるため。
   **鍵は本人のもの(`keys/users/<op>/...`)だけを使えるようにする**: 人ごとに、システム側(アプリケーション)の
   ACLを1つ作る(System → Access Control、ファイル名は例えば `<op>-keys.aclpolicy`。`by` が `username` なので
   グループに足しただけでは鍵を使えない)。usudaの実際の値:
   ```yaml
   description: usuda - read own keys
   context:
     application: 'rundeck'
   for:
     storage:
       - match:
           path: 'keys/users/usuda/.*'
         allow: [read]
       - equals:
           path: 'keys/users/usuda'
         allow: [read]
       - equals:
           path: 'keys/users'
         allow: [read]
       - equals:
           path: 'keys'
         allow: [read]
   by:
     username: usuda
   ```
   - `keys/users/<op>/.*` が鍵そのもの(ノードの `ssh-key-storage-path` が `${job.username}` で指す先)。
     `keys/users/<op>`・`keys/users`・`keys` は親のディレクトリで、Key Storageの画面で自分の鍵まで辿るためのもの
     (`equals` なので、親を読めても他人の鍵 `keys/users/<他人>/...` は読めない)
   - `storage` の `read` は、ジョブの中で鍵を使う権限で、秘密鍵の中身を表示できるわけではない
   - 担当(自作アプリ・WordPress)によらず同じ形。`usuda` の4か所を `<op>` に置き換える

### 自作アプリのオペレータ(グループ `publicdb_developer`)の1回だけの設定

`apps/<app>/` のジョブ(dev更新・本番更新・初回昇格・確認)だけを実行できるようにする。2026-10-16時点のメンバーは
`uchida, kushida, usuda, hoge, manalili, yuki`(最初に追加するオペレータは usuda)。

1. **Rancherに `APPs` プロジェクトを作り、アプリのnamespaceを移す**(dev1・prod1 それぞれ。2026-10-17に作成済み。
   staging1は2026-10-25の再導入後、各アプリのstagingへの初回昇格のあとに作る)。
   Rancher UIで クラスタ → **Projects/Namespaces** → Create Project(名前 `APPs`)→ 次のnamespaceを
   「Move」で `APPs` へ移す:
   `brc-advanced-search`、`brc-cross-search-resource`、`brc-cross-search-xsearch`、`metadatabase-v2`、`riken-diips`、`sparqlist`。
   - 割り当てはRancherがnamespaceに付ける注釈(`field.cattle.io/projectId`)で、Gitでは管理していない
     (バンドルは `defaultNamespace` でnamespaceを作るだけで、Namespaceのマニフェストを持たないため、Fleetが外すことはない)。
     **アプリを新しく追加したとき**([runbook/app-new.md](runbook/app-new.md))と、**DR等でnamespaceを作り直したとき**は移し直す
2. **プロジェクト `APPs` のメンバーにFreeIPAのグループ `publicdb_developer` を加える**(Project → Members → Add、
   グループを検索して選ぶ):
   | クラスタ | ロール | できること |
   |---|---|---|
   | `dev1` | **Project Member** | Podへのexecを含めて、アプリのnamespaceを操作できる |
   | `staging1` | **Read-only** | 見るだけ(`2-staging-update` の最後の確認、`9-check`) |
   | `prod1` | **Read-only** | 見るだけ(rollout・Podの確認、`9-check`、本番更新パイプラインの最後の確認) |

   prod1がRead-onlyなので、`sync_prod_data=yes` のような本番Podへのexecを伴う操作はできない
   (本番データのコピーは管理者が行う)。WordPressのnamespaceやSealed Secretsの鍵には触れられない
3. **RundeckのACL**(RundeckもFreeIPAでログインするので、グループ名がそのままRundeckのロールになる)。
   プロジェクトを分けてあるので、`Rancher-AppControll` のジョブをすべて許し、アドホックコマンドは許さない
   (`adhoc` を書かなければ既定で拒否される)。`WordPressControl` には何も許さない(プロジェクトごと見えない)。
   ACLは3種類あり、グループ単位の2つはここで1回だけ作る(人ごとの鍵のACLは上記「オペレータを追加する」の7)。
   | ACL | 置き場所 | 単位 | 中身 |
   |---|---|---|---|
   | プロジェクトのACL | `Rancher-AppControll` のプロジェクト設定 → Access Control | グループ | ジョブ・ノードの閲覧と実行 |
   | システム側のACL | System → Access Control(`context.application: rundeck`) | グループ | プロジェクトが見えること |
   | 個人のKey Storage用ACL | System → Access Control(`context.application: rundeck`) | ユーザー | 自分のSSH鍵だけ読めること |

   プロジェクトのACL(2026-10-23時点の実際の値。プロジェクト設定から入れるので `context` は書かない):
   ```yaml
   description: publicdb_developer - run jobs in Rancher-AppControll
   for:
     resource:
       - equals:
           kind: job
         allow: [read]
       - equals:
           kind: node
         allow: [read, refresh]
       - equals:
           kind: event
         allow: [read]
     job:
       - allow: [read, view, run]
     node:
       - allow: [read, run]
   by:
     group: publicdb_developer
   ```
   (`node` の `refresh` はノード一覧の再読み込み。`node` の `run` が無いと、ジョブがノード `rancher` で動かない)

   システム側のACL(見られるプロジェクトの一覧。`publicdb_developer` は `Rancher-AppControll` のほかに、
   このリポジトリの管理外の `DatabaseJobs`・`LocalNetworkSevers` も見られる):
   ```yaml
   description: Allow publicdb_developper to see their projects
   context:
     application: 'rundeck'
   for:
     project:
       - match:
           name: '^(Rancher-AppControll|DatabaseJobs|LocalNetworkSevers)$'
         allow: [read]
   by:
     group: publicdb_developer
   ```
   入れたあと本人でログインし、プロジェクト一覧に上の3つだけが出る(`WordPressControl` が出ない)こと、
   Commands画面が使えないこと、`<app>/9-check` が通る(=自分の鍵でSSHできる)ことを確かめる

### WordPressのオペレータ(グループ `wpadmins`)の1回だけの設定

プロジェクト `WordPressControl` のジョブ(本番コンテンツ→dev、stagingでの確認、本番昇格、バックアップ・確認)を
実行できるようにする。2026-10-16時点のメンバーは `hoge, uchida, iwase, kurihara, namiki, yuhara`。

1. **Rancherの `Wordpress` プロジェクト**(dev1・prod1 それぞれ。2026-10-17に作成済みで、全34サイトの
   `wordpress-<site>` が入っている)のメンバーに `wpadmins` を加える:
   | クラスタ | ロール | できること |
   |---|---|---|
   | `dev1` | **Project Member** | サイトのnamespaceのSecret・exec・Job、プロジェクト内のnamespaceの削除 |
   | `prod1` | **Read-only** | 見るだけ(Secret・exec・Jobの作成はできない) |

   新しいサイトを作ったとき(`new-wordpress-site.sh`)とDRのときは、namespaceを `Wordpress` へ移す。
   **staging1**(2026-10-25〜): stagingのサイトは確認のたびに作っては消すので、staging1に `Wordpress` プロジェクトを作って
   `wpadmins` を **Project Member** にし、そのプロジェクトID(`<クラスタID>:<プロジェクトID>`。staging1のクラスタIDは
   `c-m-qqhsg9c2`)を `rundeck/generate-jobs.py` の `STAGING_PROJECT_ID` に書いて再生成する
   (2026-10-25に作成済み: `Wordpress` = `c-m-qqhsg9c2:p-vk6k8`、`APPs` = `c-m-qqhsg9c2:p-5ppgz`。
   staging1の `APPs` は `publicdb_developer` を **Read-only**、7アプリのnamespaceを移動済み)。パイプラインが
   staging-startで作るnamespaceにその注釈を付ける(空ならプロジェクトの外に作られ、管理者しか触れない)
2. **staging1のSealed Secretsの公開証明書を置く**(stagingのサイトのSecretを封印するため。オペレータは
   kube-systemのSealed Secretsのコントローラに届かない)。公開証明書なので秘密ではない:
   ```bash
   kubeseal --context staging1 --fetch-cert | sudo tee /var/lib/ibid-fleet-config/sealed-secrets-staging1.pem >/dev/null
   sudo chmod 644 /var/lib/ibid-fleet-config/sealed-secrets-staging1.pem
   ```
   コントローラの鍵は30日ごとに追加されるが、古い鍵でも復号できるので、作り直しはstaging1を作り直したとき
   (鍵が変わったとき)だけでよい。dev1のリハーサルサイト用に置いていた `sealed-secrets-dev1.pem` は不要になった
3. **RundeckのACL**。自作アプリの節と同じ形で作る:
   - プロジェクトのACL(`WordPressControl` のプロジェクト設定 → Access Control): `description` を変え、`by.group` を `wpadmins` にする
   - システム側のACL: `project` の `name` を `'^WordPressControl$'`(ほかに見せるプロジェクトがあれば足す)、`by.group` を `wpadmins` にする
   - 個人のKey Storage用ACL: 上記「オペレータを追加する」の7のとおり人ごと(両方の担当の人も1つでよい)
4. 実行する人を `wpadmins` に入れる(stagingでの比較の基準 `/var/lib/ibid-fleet-config/rehearsal` を書けるようにするためでもある)

**prod1がRead-onlyなので、オペレータが実行すると次のように動く**(`scripts/wordpress-pipeline.sh` が権限を
`kubectl auth can-i` で確かめて切り替える):

| ジョブ | 管理者が実行したとき | オペレータが実行したとき |
|---|---|---|
| `1-dev-refresh`・`2-staging`(`fresh_backup=yes`) | 本番のバックアップを今すぐ取って使う | 最新の日次バックアップ(JST 3:00)を使う |
| `3-production-promote` | PRができたら本番のバックアップを取り、PRにコメントする | バックアップは取らず、「承認する管理者がマージ直前に `tools/backup`(`env=production`)で取る」とPRにコメントする |
| `3-production-promote` のマージ後 | Helmのリビジョンが上がるのを待ってrolloutを確認 | 180秒待ってからrolloutを確認(Helmの履歴を読めないため) |
| `tools/backup`(`env=production`) | 取れる | 権限が無いと表示して止まる |

本番PRを承認するときは、PRのコメントを見て、未取得なら**マージの直前に** `tools/backup` を実行してから Approve・マージする。

### 確認(オペレータを追加したら)

- `<op>` で担当のプロジェクトの確認ジョブ(`<app>/9-check`、WordPressは `tools/check`)が通る(SSH・kubeconfigの確認)
- (自作アプリ)`<app>/1-dev-update` を実行すると、PRの作成者が `<op-gh>` になり、auto-mergeされる
- `3-production-update` / `3-production-promote` の本番PRが、`@silver198545` がApproveしないとマージできない
  (Mergeボタンが「Review required」になる)
- (自作アプリのオペレータ)本人のkubeconfigで `kubectl --context prod1 -n sparqlist delete pod --dry-run=server -l app=sparqlist`
  が `forbidden` になり、`kubectl --context dev1 get ns` にWordPressのnamespaceが出ない

## 取り込み・更新

```bash
python3 rundeck/generate-jobs.py        # 定義を作り直す(アプリ・サイトの追加・削除のあと)
rd jobs load -p Rancher-AppControll -f rundeck/jobs/apps.yaml --format yaml
rd jobs load -p WordPressControl -f rundeck/jobs/wordpress.yaml --format yaml
```

- **取り込み先を間違えない**(各ファイルの先頭のコメントにも書いてある)。RundeckのジョブUUIDはサーバー全体で一意なので、
  別のプロジェクトへ取り込むと失敗するか、既存のジョブが移ってしまう
- ジョブのUUIDはグループ・名前から決まるので、取り込み直すと同じジョブが更新される。2026-10-17にグループ名から
  先頭の `apps/`・`wordpress/` を外したが、UUIDは外す前と同じ値のまま(`generate-jobs.py` の `job()`)なので、
  取り込み直すと既存のジョブのグループ名が変わるだけで、重複はしない
- `rd jobs load` は定義から消えたジョブを削除しない。旧定義のグループ `app-image-update`、
  自作アプリの `<app>/2-production-update`・`<app>/3-first-promote-prepare`(2026-10-25にジョブ名を変えた)、
  消したアプリのグループ、WordPressの `2-rehearsal`・`2a-rehearsal-upgrade`・`2b-rehearsal-cleanup`
  (2026-10-25にstagingのジョブへ置き換え)は、Rundeck UIで手動で削除する
- 生成内容は `envs/dev/apps`・`envs/dev/sites` と `update-app-image.sh` の
  `persistent_data_dir_for` だけで決まる。`validate` ワークフローが生成結果との一致を確かめるので、
  アプリ・サイトを追加したPRでは再生成したファイルも一緒にコミットする
  (`scripts/new-wordpress-site.sh dev <site>` は自動で再生成する)。本番への昇格では変わらない
- rancherホストには `rd` CLIが無い。Rundeck UIの「ジョブのアップロード」(YAML)か、`rd` のある端末で取り込む

## 自作アプリ(プロジェクト `Rancher-AppControll`、グループ `<app>/`)

### 1-dev-update(開発環境更新パイプライン)

1. mainを最新化
2. `src_ref` が空なら取り込み元ブランチの最新コミットを使う。現在の `images/<app>/SRC_REF` と同じなら
   イメージは更新せず、devの確認だけ行って終わる
3. 違えば `set-image`: イメージPR → auto-merge → ビルド完了待ち → devの `deployment.yaml` を更新するPR →
   auto-merge → devのrollout・WEB疎通(readinessProbeのpathで200か)の確認
4. (`persistent_data_dir_for` に登録したアプリのみ。`sync_prod_data=yes` のとき)本番の永続データをdevへコピー。
   **devの内容は上書きされる**。登録すると次の再生成でこのオプションが付く。現状は登録なし
   (sparqlistは2026-10-21から `repository/` をdevと本番で共有しているため外した)

| オプション | 既定 | 説明 |
|---|---|---|
| `src_ref` | 空(最新) | 取り込み元のコミットSHA。特定のコミットを入れたいときだけ指定 |
| `tag` | 空(自動採番) | 現在のTAGが `<version>-r<N>` なら N+1。その形式でないアプリでは指定が要る |

終わったらブラウザでdevを確認してから `2-staging-update` へ。

自作アプリはstagingに常駐させている(2026-10-25〜。WordPressと違い載せ降ろししない)。本番へは必ずstagingを通す。

### 2-staging-update(staging更新パイプライン)

1. mainを最新化
2. devとstagingの `<app>` に差分があれば、promoteワークフロー(`kind=apps`、`to=staging`)で昇格PRを作り、
   auto-mergeを待つ(stagingはCODEOWNERSの対象外で承認不要)。差分が無ければ3.へ
3. Fleetの適用を待って(60秒)、stagingのrollout・WEB疎通を確認する
4. **QA**(`scripts/qa.sh staging apps <app>`。[operations-flow.md](operations-flow.md)「QAゲート」)。
   結果はGitHubに記録され、本番PRの `qa-gate` がそれを見る

終わったらブラウザでstaging(`https://<app>.staging.ibid.lan/`)を確認してから `3-production-update` へ。

### 3-production-update(本番環境更新パイプライン)

1. mainを最新化
2. stagingと本番の `<app>` に差分があれば、stagingでQAし(**通らなければ止まる**)、
   promoteワークフロー(`kind=apps`、`to=production`)で昇格PRを作り、CIを待つ
   (差分が無ければ4.へ。devにstagingで未確認の変更があれば注意を出す)
3. **人がPRのdiffを見てマージするのを待つ**(イメージタグ以外のstagingの変更もすべて昇格対象になる)
4. mainを取り込み、Fleetの適用を待って(60秒)、本番のrollout・WEB疎通を確認する

### 4-first-promote-prepare / 5-first-promote-finish(初回昇格)

昇格先(`env`: `staging` か `production`)にまだ無いアプリのときだけ使う(既にあれば `2-staging-update`・
`3-production-update`)。必ず `env=staging` を先に行う(本番への昇格元はstaging)。
`prepare` はコピーまでで止まり、表示された `kubeseal` コマンドを**踏み台端末で人が実行して**
`envs/<env>/secrets/<app>.yaml` を作ってから、同じ `env` で `finish` を実行する(PATを扱うため)。
`env=staging` の `finish` はPRをauto-mergeしてstagingの確認まで続ける。`env=production` の `finish` が
作ったPRは人がマージし、`9-check`(`env=production`)で確認する。

**`prepare` から `finish` までの間、クローンは未コミットの変更を持ったまま残る。** その間、
他のジョブは最初の「mainを最新化」で止まる(壊れることはない)。

### 8-qa

QA(反映の確認と [qa/checks.yaml](../qa/checks.yaml) のチェック)を単独で行う。`env=staging` では結果をGitHubに記録し、
通ると、失敗していた本番PRの `qa-gate` をやり直させる。`2-staging-update`・`3-production-update` も同じQAを自動で
行うので、これは直した後の再確認や、`qa-gate` が落ちたとき用。

### 9-check

dev・staging・本番のいずれかのrollout状況とWEB疎通を確認する(読み取りのみ)。

## WordPress(プロジェクト `WordPressControl`)

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

### 2-staging(stagingで本番データを使って確認する)

本番へ出すサイトは、必ずstagingで確認してから昇格する
([operations-flow.md](operations-flow.md)「stagingでの確認」の手順をそのまま自動化したもの)。

1. mainを最新化
2. **staging-start**: `envs/production/sites/<site>` を `envs/staging/sites/<site>` へコピーし、
   `seal-site-secrets.sh staging <site>`(新規パスワード)と一緒にPR → auto-merge(stagingはCODEOWNERSの対象外)→
   Fleetの適用待ち → 本番のバックアップ → stagingの `<site>` へリストア・URL置換 →
   **比較の基準**を記録する(トップと最近更新された10ページのHTTPステータス、WordPress・プラグイン・
   テーマの版、`mariadb_upgrade_info`)。本番にまだ無い新規サイトはdevの構成で置き、本番データは入れない
3. **staging-upgrade**(`upgrade=yes` のとき): promoteワークフロー(`to=staging`)でdevの構成(昇格予定の
   `helm.version`・`plugins`)をstagingへ昇格するPR → auto-merge → Helmリビジョンの更新とrolloutを待つ →
   プラグイン同期Jobの成否と所要時間 → `wp core update-db`(管理画面の「データベースの更新」と同じ)の
   所要時間 → 基準との比較(版の差分、HTTPステータスが変わったページ)→ 直近のPHPエラー →
   **QA**(本番の同じサイトとタイトル・サイト名が一致するか等。結果はGitHubに記録され、本番PRの `qa-gate` が見る)

devとstagingの構成に差分が無ければ、3.は何もせず終わる。HTTPステータスが変わったページ・
プラグイン同期Jobの失敗・QAの失敗があるとジョブは失敗になる。結果(所要時間・気づいた点)は本番への昇格PRに書く。
ブラウザでの確認(`https://<site>.staging.ibid.lan/ja/`。記事表示・管理画面・プラグイン固有の画面)も行うこと。

- staging1のメモリの都合で、**stagingに同時に置けるサイトは4つまで**(`STAGING_MAX_SITES`。超えると止まる)
- 比較の基準は `/var/lib/ibid-fleet-config/rehearsal/staging-<site>/` に置く(パスはリハーサルサイト時代のまま)
- 問題があればdevで直し、`2a-staging-upgrade` で切り替えからやり直す
  (`2-staging` を `upgrade=no` で実行した場合もこれで続ける)

### 3-production-promote(本番昇格パイプライン)

1. mainを最新化
2. 選んだサイト(`all` は本番に既にあり、stagingに載っている全サイト)のうち、stagingと本番で差分のあるものの
   stagingでQAし(**通らなければ止まる**)、昇格PRをpromoteワークフロー(`to=production`)で作り、CIを待つ。
   差分が無ければ確認だけ行って終わる。
   **stagingに無いサイトを選ぶと止まる**(本番へはstagingを通す)。devにstagingで未確認の変更があれば注意を出す
3. **対象サイトの本番バックアップを取り**(本番反映前のバックアップ。
   [operations-flow.md](operations-flow.md))、取得したファイル名をPRにコメントする
4. **人がPRのdiffを見てマージするのを待つ**(diffが stagingで確認した `helm.version`・`plugins` の
   `version` 等だけであること)。バックアップから長く時間が空いた場合は、マージの前に
   `tools/backup` で取り直す
5. mainを取り込み、各サイトのHelmリビジョンが上がってrolloutが終わるのを待つ
6. 本番のHTTP 200・Pod・MariaDBのアップグレード状況(`mariadb_upgrade_info`)を確認する

本番に無いサイトを追加するときは、サイト名を選ぶ(`all` では追加されない)。
先に `scripts/seal-site-secrets.sh production <site>` のSecretをmainに入れておくこと(無いと止まる)。

### 4-staging-cleanup(stagingの後片付け)

本番へ昇格したら(または昇格をやめたら)**必ず実行する**。`<site>` をstagingのGitから消すPR(auto-merge)→
マージ後にstaging1の `wordpress-<site>` namespaceを削除する(本番データのコピーが消える。
stagingのStorageClassは`Delete`なので、NFS上のwp-content・バックアップも消える)。
stagingの構成が本番へまだ昇格していなければ注意を出す。PVが消えるのを最大3分待ち、残ったら警告を出す
([runbook/troubleshooting.md](runbook/troubleshooting.md)「PV が Released のまま残る」)

### tools/backup・tools/qa・tools/check

- `backup`: 日次バックアップのCronJobから今すぐ1つ取る(完了まで待つ)
- `qa`: QAを単独で行う(アプリの `8-qa` と同じ。`env=staging` では結果を記録し、落ちていた `qa-gate` をやり直させる)
- `check`: HTTPステータスと正常でないPodの確認(読み取りのみ)

## ジョブにしていないもの

- **GHCR pull用SealedSecretの作成**(アプリの初回昇格)、本番サイトの新規Secret
  (`seal-site-secrets.sh production`、パスワードを控える必要がある): 人が端末で実行する
- **本番に触れるPRのマージ**: 常に人がGitHubで行う(パイプラインは待つだけ)
- **WordPressのチャート・プラグインの更新をdevに入れる作業**: `auto-update` ワークフローが毎週行う
  ([runbook/wordpress-update.md](runbook/wordpress-update.md))。手で入れるときは `bump-chart.sh`・
  `bump-plugins.sh`
- **プラグインの削除**、外部nginxの切り替え: 手順書どおり手で行う
