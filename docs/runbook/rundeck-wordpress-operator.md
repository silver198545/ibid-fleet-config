# Rundeck WordPress運用 オペレータ手順書

> オペレータ(Rundeckでジョブを実行する人)向けの手順書。Redmine用のTextile版は [textile/rundeck-wordpress-operator.textile](textile/rundeck-wordpress-operator.textile)。
> 内容を変えるときは両方を直す。管理者向けの設定・仕組みは [manual-rundeck.md](../manual-rundeck.md)。

## 概要

Rundeck のプロジェクト **`WordPressControl`** から、WordPress サイト(全34サイト。日本語版 `<site>` と英語版 `<site>-en`)を運用する手順です。
次の3つの作業を、それぞれジョブ1つで最後まで進めます。

| 作業 | ジョブ | 何が起きるか |
|---|---|---|
| 開発環境のコンテンツを本番と同じにする | `1-dev-refresh` | 本番のバックアップを dev の同名サイトに戻す(**dev の内容は上書き**) |
| 本番データでリハーサルする | `2-rehearsal` | dev1 に本番のコピー `<site>-rh` を作り、昇格予定の更新を当てて、表示を比べる |
| 本番へ昇格する | `3-production-promote` | 本番 PR を作り、管理者の承認とマージを待って、本番を確認する |

ジョブは **あなた自身のアカウント** で動きます(サーバーのユーザー、GitHub、Rancher の権限)。GitHub の PR もあなたの名前で作られます。
WordPress 本体・プラグインの新しい版を dev に入れる作業は、毎週月曜 9:00 に自動で行われます(このジョブでは行いません)。

サイトの確認先(`<site>` はサイト名。例: `abc`):

| 環境 | 日本語版 | 英語版 |
|---|---|---|
| dev | `https://<site>.dev.ibid.lan/ja/` | `https://<site>.dev.ibid.lan/en/` |
| 本番 | `https://<site>.production.ibid.lan/ja/` | `https://<site>.production.ibid.lan/en/` |
| リハーサル | `https://<site>-rh.dev.ibid.lan/ja/` | (英語版はリハーサルしない) |

外部公開のドメインは、本番が `https://<site>.brc.riken.jp/`、dev が `https://wpdev1.brc.riken.jp/`(外部の nginx で表示するサイトを切り替える)です。dev・リハーサルのページ内のリンクは `wpdev1.brc.riken.jp` を指します。

## 前提条件

| 項目 | 内容 |
|---|---|
| FreeIPA | 自分のアカウントがグループ `wpadmins` に入っていること |
| サーバー | 踏み台(`knowledge.brc.riken.jp`)経由で `rancher`(192.168.1.149)に、自分のアカウントで SSH ログインできること |
| GitHub | 自分の GitHub アカウントが `silver198545/ibid-fleet-config` の collaborator であること(招待を承諾済み)。2要素認証を有効にしていること |
| Rundeck | FreeIPA のアカウントでログインでき、プロジェクト `WordPressControl` が見えること |
| SSH 鍵 | Rundeck 用の SSH 鍵が登録済みであること(管理者が Key Storage の `keys/users/<自分のユーザー名>/<自分のユーザー名>_ed25519` に登録) |
| Rancher | Rancher(`https://rancher.brc.riken.jp/`)に FreeIPA でログインでき、`dev1`・`prod1` のプロジェクト `Wordpress` が見えること |
| バックアップ | rancher にバックアップの NFS がマウントされていること(管理者が行う。外れているとジョブが止まって知らせる) |

権限は次のとおりです。

| 場所 | できること |
|---|---|
| dev1(開発クラスタ) | サイトの namespace を操作できる(Project Member) |
| prod1(本番クラスタ) | **見るだけ**(Read-only)。本番のバックアップを「今すぐ」取ることはできない |
| GitHub | PR を作れる。dev の PR は自動でマージされる。**本番の PR は管理者の承認(Approve)が必要** |
| Rundeck | `WordPressControl` のジョブの実行だけ(Commands 画面は使えない) |

## 初回設定(1回だけ)

自作アプリの手順書で初回設定を済ませている人は、**「4. 動作確認」だけ**行ってください(同じクローン・認証・kubeconfig を使います)。

### 1. サーバーにログインする

手元の PC の `~/.ssh/config` に次を書きます(`<自分のユーザー名>` は FreeIPA のユーザー名。踏み台(Bastion)にも自分のアカウントで入ります)。

```
Host Bastion
    HostName knowledge.brc.riken.jp
    User <自分のユーザー名>
    IdentityFile ~/.ssh/<自分の鍵>

Host rancher
    HostName 192.168.1.149
    User <自分のユーザー名>
    IdentityFile ~/.ssh/<自分の鍵>
    ProxyCommand ssh -W %h:%p Bastion
```

```
ssh rancher
```

以降の 2〜4 は、rancher にログインした状態で行います。

### 2. リポジトリを置いて GitHub に認証する

ジョブは **ホームの `~/ibid-fleet-config`** を使います。場所と名前を変えないでください。

```
git clone https://github.com/silver198545/ibid-fleet-config.git ~/ibid-fleet-config
cd ~/ibid-fleet-config
git config user.name '<GitHubのアカウント名>'
git config user.email '<ID>+<GitHubのアカウント名>@users.noreply.github.com'
gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git
gh auth status
```

`user.email` に入れる値は、GitHub の Settings → Emails の「Keep my email addresses private」の下に出ています。
`gh auth status` で `Logged in to github.com account <自分のアカウント>` と出れば OK です。

### 3. kubeconfig を置く

1. ブラウザで Rancher(`https://rancher.brc.riken.jp/`)に FreeIPA のアカウントでログインする
2. クラスタ一覧で `dev1` を開き、右上の「Download KubeConfig」で保存する。`prod1` も同じようにする
3. 2つを1つにまとめて、rancher の `~/.kube/config` に置く

```
mkdir -p ~/.kube
KUBECONFIG=~/dev1.yaml:~/prod1.yaml kubectl config view --flatten > ~/.kube/config
chmod 600 ~/.kube/config
rm ~/dev1.yaml ~/prod1.yaml
```

確認(どちらも Pod の一覧が出れば OK):

```
kubectl --context dev1 -n wordpress-abc get pods
kubectl --context prod1 -n wordpress-abc get pods
```

**kubeconfig は 30 日で期限が切れます。** ジョブが `Unauthorized` で止まったら、同じ手順で取り直してください。

### 4. 動作確認

Rundeck で `tools/check` を `env=dev`、`sites=abc` で実行し、次のように出れば完了です。

```
abc            200  https://abc.dev.ibid.lan/ja/
全サイト正常です。
```

## ジョブ一覧

| ジョブ | 内容 | 使う場面 |
|---|---|---|
| `1-dev-refresh` | 本番のコンテンツ(記事・メディア・設定・ユーザー)を dev の同名サイトに戻す | dev を本番と同じ状態にして確認したいとき |
| `2-rehearsal` | 本番のコピー `<site>-rh` を dev1 に作り、昇格予定の更新を当てて、表示を比べる | WordPress 本体・MariaDB・プラグインの大きな更新を本番に出す前 |
| `2a-rehearsal-upgrade` | 既にある `<site>-rh` に、dev の今の構成を当て直して比べる | リハーサルで見つかった問題を dev で直したあと |
| `2b-rehearsal-cleanup` | `<site>-rh` を削除する | リハーサルが終わったら**必ず** |
| `3-production-promote` | dev と差分のあるサイトの本番 PR を作り、承認・マージ後に本番を確認する | dev(とリハーサル)で確認できたあと |
| `tools/check` | 各サイトの WEB の応答(200 か)と Pod の状態を確認する(読むだけ) | いつでも |
| `tools/backup` | 今すぐバックアップを取る | dev のみ(本番は管理者が実行) |

### オプション

| ジョブ | オプション | 既定値 | 説明 |
|---|---|---|---|
| `1-dev-refresh` | `sites` | (なし) | 対象サイト(複数選択可) |
| `1-dev-refresh`・`2-rehearsal` | `fresh_backup` | `yes` | 本番のバックアップを今すぐ取るか。**オペレータは本番の権限が無いので、`yes` でも自動で最新の日次バックアップ(毎日 3:00)を使います** |
| `2-rehearsal`・`2a`・`2b` | `site` | (なし) | リハーサルするサイト(日本語版の名前。例: `abc`) |
| `2-rehearsal` | `upgrade` | `yes` | 続けて dev の構成に切り替えて比べる。`no` なら本番のコピーを作るところまで |
| `3-production-promote` | `sites` | `all` | 昇格するサイト。`all` は本番にある全サイトのうち dev と差分のあるもの |
| `3-production-promote` | `merge_wait_minutes` | `240` | 本番 PR の承認・マージを待つ時間(分) |
| `tools/check`・`tools/backup` | `env` / `sites` | `production` / `all` | 環境と対象サイト |

## 実行方法

### A. 開発環境のコンテンツを本番と同じにする(`1-dev-refresh`)

**dev の記事・設定・ユーザーは、本番のもので上書きされます。** dev で作業中の内容が無いか、先に確認してください。

1. Rundeck にログインし、プロジェクト `WordPressControl` を開く
2. `1-dev-refresh` を開き、`sites` で対象サイトを選んで「Run Job Now」
3. 1サイトにつき数分〜数十分(サイトの大きさによる)。最後に次の行が出れば成功
   ```
   devの abc abc-en を本番のコンテンツで更新しました。表示・管理画面をブラウザで確認してください。
   ```
4. dev の確認先をブラウザで開き、表示を確認する。管理画面には**本番のアカウント**でログインする

上書き前の dev の状態は、ジョブが最初にバックアップしています(戻すときは管理者に依頼)。

### B. 本番データでリハーサルする(`2-rehearsal` → `2b-rehearsal-cleanup`)

WordPress 本体のメジャー更新(例: 7.0 → 7.1)、MariaDB のメジャー更新、プラグインの大きな更新のときに行います。
**リハーサルサイトは同時に1つまで**です。

1. `2-rehearsal` を開き、`site`(例: `web`)を選んで「Run Job Now」(`upgrade=yes` のまま)
2. ジョブが次を順に行う(サイトの大きさによって数十分以上かかる)
   * 本番と同じ構成の `<site>-rh` を dev1 に作る(PR は自動でマージされる)
   * 本番のバックアップを戻し、**比較の基準**(各ページの応答、WordPress・プラグインの版)を記録する
   * dev の構成(昇格予定の更新)に切り替え、プラグインの更新・DB の更新の所要時間を測る
   * 基準と比べて、応答が変わったページ・PHP のエラーを報告する
3. 出力の「基準(本番と同じ構成)との比較」を見る。成功なら次の行が出る
   ```
   HTTPステータスが変わったページはありません(11ページ)。
   ```
4. ブラウザで `https://<site>-rh.dev.ibid.lan/ja/` を開き、記事・管理画面・プラグインの画面を確認する
5. 結果(所要時間・気づいた点)を、本番昇格の PR に書く
6. **終わったら必ず `2b-rehearsal-cleanup`** を同じ `site` で実行する(本番データのコピーを消す)

問題が見つかったら、dev で直してから `2a-rehearsal-upgrade` で切り替えからやり直します。

### C. 本番へ昇格する(`3-production-promote`)

dev(と必要ならリハーサル)で確認できてから行います。

1. `3-production-promote` を開き、`sites=all` のまま「Run Job Now」
2. ジョブが本番 PR を作り、CI を待ってから PR に次のコメントを付け、**待ち状態** になる
   ```
   本番バックアップは未取得です(実行者に本番でJobを作る権限が無いため)。
   ```
3. **管理者に PR の URL を伝えて、「バックアップ → 承認(Approve)→ マージ」を依頼する**
   (本番のバックアップは、承認する管理者がマージの直前に取ります)
4. マージされると、ジョブが自動で続きを行い、本番の確認まで進む。最後に次の行が出れば成功
   ```
   本番への昇格が完了しました: abc abc-en ...
   ```
5. 本番の確認先をブラウザで開き、表示を確認する

dev と本番に差分が無いときは、PR は作らず本番の確認だけ行って終わります。

## 動作の仕組み

### `1-dev-refresh`

1. 本番の最新の日次バックアップ(毎日 3:00)を選ぶ
2. dev の今の状態をバックアップする(上書き前の控え)
3. 本番の wp-content と DB を dev の同名サイトに戻す
4. DB の中の本番の URL(`<site>.brc.riken.jp`)を dev の URL(`wpdev1.brc.riken.jp`)に置き換える
5. 各サイトの応答(200 か)を確かめる

### `2-rehearsal`

1. 本番と同じ構成のリハーサルサイト `<site>-rh` を作る PR を作り、自動でマージする
2. dev1 にサイトができるのを待ち、本番のバックアップを戻して URL を置き換える
3. トップと最近更新された10ページの応答、WordPress・プラグイン・テーマの版を「基準」として記録する
4. (`upgrade=yes`)dev の構成に切り替える PR を作り、自動でマージする
5. プラグイン同期の Job、DB の更新(`wp core update-db`)、MariaDB のアップグレードを確かめる
6. 同じページの応答を取り直して基準と比べ、PHP のエラーを表示する

### `3-production-promote`

1. dev と本番で差分のあるサイトを調べる
2. promote ワークフローで本番 PR を作る(作成者は `ibid-ops-bot`)
3. 「本番バックアップは管理者がマージ直前に取る」と PR にコメントする
4. **人が PR を承認・マージするのを待つ**(このジョブはマージしない)
5. マージされたら、Fleet の反映を待って(約3分)各サイトの rollout を確かめ、本番の応答と MariaDB の状態を確認する

## ログの確認

Rundeck のジョブの実行画面(Log Output)に、すべての出力が残ります。

| 出力 | 意味 |
|---|---|
| `main: <コミット> <メッセージ>` | リポジトリを最新に揃えた |
| `注意: 本番でバックアップのJobを作る権限が無いため、…最新の日次バックアップを使います。` | オペレータの通常の動き(問題ない) |
| `最新の日次バックアップを使います: production/<site> <日時>` | 使ったバックアップ |
| `URL置換: <本番のURL> → <devのURL>` | URL の置き換え(続く行に件数) |
| `<site>  200  https://...` | サイトの応答(200 なら正常) |
| `全サイト正常です。` | 確認した全サイトが正常 |
| `PR作成: https://...` | 作った PR |
| `HTTPステータスが変わったページ:` | リハーサルで応答が変わったページ(要確認) |

作られた PR は GitHub の Pull requests でも見られます。本文の最後に「実行者: <あなた>(Rundeck、...)」と入ります。

## 注意事項

* **`1-dev-refresh` は dev の内容を上書きします。** dev で作業中の記事や設定があれば消えます。
* dev のコンテンツを本番に送る方法はありません(本番に出るのは構成=バージョンとプラグインだけ)。
* **リハーサルサイトは本番データのコピーです。終わったら必ず `2b-rehearsal-cleanup` で消してください。** 同時に置けるのは1つまでです。
* **本番の PR は自分ではマージできません。** 管理者の承認が必要で、本番のバックアップも管理者が取ります。
* `merge_wait_minutes` を過ぎてもマージされないと、ジョブは失敗で終わります。PR は残るので、マージ後に `tools/check`(`env=production`)で確認してください。
* 同じジョブは同時に1つしか動きません。
* rancher の `~/ibid-fleet-config` を手で編集しないでください。未コミットの変更が残っていると、すべてのジョブが最初で止まります。
* 本番(prod1)は見るだけです。本番での操作が必要なときは管理者に依頼してください。
* kubeconfig は 30 日で期限が切れます。

## トラブルシューティング

| 症状(出力) | 対処 |
|---|---|
| `エラー: /mnt/ibid-nfs/backup/production が見えません。` | バックアップの NFS が外れています。管理者に連絡する |
| `dev/<site> に前回のリストアの退避分 wp-content.orig が残っています。` | 前回の `1-dev-refresh` が途中で失敗しています。表示が正常なら、表示されたコマンド(`kubectl ... rm -rf /bitnami/wordpress/wp-content.orig`)で消してから実行し直す |
| `他のリハーサルサイトがあります: <site>-rh` | 前のリハーサルが残っています。終わっているなら `2b-rehearsal-cleanup` で消す |
| `envs/dev/sites/<site>-rh は既にあります。` | そのサイトのリハーサルが途中です。続けるなら `2a-rehearsal-upgrade`、やり直すなら `2b-rehearsal-cleanup` のあと `2-rehearsal` |
| `リハーサルの基準の置き場所 … 書き込めません。` | `wpadmins` に入っていない、または入った直後。管理者に確認する |
| `…証明書ファイル … もありません。` | 管理者の準備が足りません。管理者に連絡する |
| `HTTPステータスが変わったページ:` | ブラウザでそのページを開いて確認する。dev で直したら `2a-rehearsal-upgrade` |
| `Unauthorized` / `You must be logged in to the server` | kubeconfig の期限切れ。「初回設定 3」で取り直す |
| `エラー: 作業ツリーに未コミットの変更があります` | rancher で `cd ~/ibid-fleet-config && git status` を見る。心当たりが無ければ管理者に相談する |
| `エラー: ...分待ってもマージされませんでした` | PR はそのまま残っています。管理者に依頼し、マージ後に `tools/check`(`env=production`)で確認する |
| `productionでバックアップのJobを作る権限がありません` | 本番のバックアップは管理者が取ります |
| `200以外、または正常でないPodがあります` | ブラウザで確認先を開き、管理者に連絡する |
| `Permission denied (publickey)` | Rundeck の SSH 鍵の設定。管理者に連絡する |
