# Rundeck 自作アプリ更新 オペレータ手順書

> オペレータ(Rundeckでジョブを実行する人)向けの手順書。Redmine用のTextile版は [textile/rundeck-app-operator.textile](textile/rundeck-app-operator.textile)。
> 内容を変えるときは両方を直す。管理者向けの設定・仕組みは [manual-rundeck.md](../manual-rundeck.md)。

## 概要

Rundeck のプロジェクト **`Rancher-AppControll`** から、自作アプリ(下表)を **開発環境(dev)→ 本番環境(production)** の順に更新する手順です。
ジョブ1つで「イメージの作り直し → dev への反映 → 動作確認」、もう1つで「本番への昇格 PR → 管理者の承認待ち → 本番の確認」まで自動で進みます。

ジョブは **あなた自身のアカウント** で動きます(サーバーのユーザー、GitHub、Rancher の権限)。GitHub の PR もあなたの名前で作られます。

| アプリ | dev の確認先 | 本番の確認先 |
|---|---|---|
| `brc-advanced-search` | `https://brc-advanced-search.dev.ibid.lan/advanced/en/` | `https://brc-advanced-search.production.ibid.lan/advanced/en/` |
| `brc-cross-search-xsearch` | `https://brc-cross-search-xsearch.dev.ibid.lan/xsearch/catalog/` | `https://brc-cross-search-xsearch.production.ibid.lan/xsearch/catalog/` |
| `brc-cross-search-resource` | `https://brc-cross-search-resource.dev.ibid.lan/resource/animal/` | `https://brc-cross-search-resource.production.ibid.lan/resource/animal/` |
| `metadatabase-v2` | `https://metadatabase-v2.dev.ibid.lan/tsukuba` | `https://metadatabase-v2.production.ibid.lan/bioresource` |
| `riken-diips` | `https://riken-diips.dev.ibid.lan/ja` | `https://riken-diips.production.ibid.lan/ja` |
| `sparqlist` | `https://sparqlist.dev.ibid.lan/sparqlist/` | `https://sparqlist.production.ibid.lan/sparqlist/` |

## 前提条件

| 項目 | 内容 |
|---|---|
| FreeIPA | 自分のアカウントがグループ `publicdb_developer` に入っていること |
| サーバー | 踏み台(`knowledge.brc.riken.jp`)経由で `rancher`(192.168.1.149)に、自分のアカウントで SSH ログインできること |
| GitHub | 自分の GitHub アカウントが `silver198545/ibid-fleet-config` の collaborator であること(招待を承諾済み)。2要素認証を有効にしていること |
| Rundeck | FreeIPA のアカウントでログインでき、プロジェクト `Rancher-AppControll` が見えること |
| SSH 鍵 | Rundeck 用の SSH 鍵が登録済みであること(管理者が Key Storage の `keys/users/<自分のユーザー名>/<自分のユーザー名>_ed25519` に登録) |
| Rancher | Rancher(`https://rancher.brc.riken.jp/`)に FreeIPA でログインでき、`dev1`・`prod1` のプロジェクト `APPs` が見えること |

権限は次のとおりです。

| 場所 | できること |
|---|---|
| dev1(開発クラスタ) | アプリの namespace を操作できる(Project Member) |
| prod1(本番クラスタ) | **見るだけ**(Read-only) |
| GitHub | PR を作れる。dev の PR は自動でマージされる。**本番の PR は管理者の承認(Approve)が必要** |
| Rundeck | `Rancher-AppControll` のジョブの実行だけ(Commands 画面は使えない) |

## 初回設定(1回だけ)

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
```

`user.email` に入れる値は、GitHub の Settings → Emails の「Keep my email addresses private」の下に出ています。
`gh auth login` では、表示されたコードをブラウザで入力し、自分の GitHub アカウントで許可します。

認証状態の確認:

```
gh auth status
```

`Logged in to github.com account <自分のアカウント>` と、スコープに `repo`・`workflow`・`read:org` があれば OK です。

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
kubectl --context dev1 -n sparqlist get pods
kubectl --context prod1 -n sparqlist get pods
```

**kubeconfig は 30 日で期限が切れます。** ジョブが `Unauthorized` で止まったら、同じ手順で取り直してください。

### 4. 動作確認

Rundeck で `<アプリ名>/9-check` を `env=dev` で実行し、最後に次のような行が出れば初回設定は完了です。

```
OK: sparqlist.dev.ibid.lan/sparqlist/ は200を返しました。
```

## ジョブ一覧

アプリごとにグループがあり、中に次のジョブがあります(例: `sparqlist/1-dev-update`)。

| ジョブ | 内容 | 使う場面 |
|---|---|---|
| `1-dev-update` | 取り込み元の最新コミットでイメージを作り直し、dev に反映して確認する | 開発環境を更新するとき |
| `2-production-update` | dev と同じ内容にする本番 PR を作り、管理者の承認とマージを待って、本番を確認する | dev で確認できたあと、本番を更新するとき |
| `3-first-promote-prepare` / `4-first-promote-finish` | 新しいアプリを初めて本番に出す | **管理者が行います**(使わないでください) |
| `9-check` | dev または本番の稼働状況と WEB の応答を確認する(読むだけ) | いつでも |

### オプション

| ジョブ | オプション | 既定値 | 説明 |
|---|---|---|---|
| `1-dev-update` | `src_ref` | 空欄 | 取り込むコミットの SHA。**空欄なら取り込み元の最新**。特定のコミットを入れたいときだけ指定 |
| `1-dev-update` | `tag` | 空欄 | 新しいイメージのタグ。空欄なら自動で採番(例: `2.0.0-r7` → `2.0.0-r8`) |
| `2-production-update` | `merge_wait_minutes` | `240` | 本番 PR の承認・マージを待つ時間(分) |
| `9-check` | `env` | `dev` | 確認する環境(`dev` / `production`) |

## 実行方法

### 開発環境を更新する(`1-dev-update`)

1. Rundeck にログインし、プロジェクト `Rancher-AppControll` を開く
2. Jobs から `<アプリ名>/1-dev-update` を開く
3. `src_ref` と `tag` は空欄のまま「Run Job Now」
4. 10〜20 分で終わる。最後に次の行が出れば成功
   ```
   OK: <アプリ名>.dev.ibid.lan/... は200を返しました。
   ```
5. 上表の dev の確認先をブラウザで開き、動作を確認する

取り込み元に新しいコミットが無いときは、イメージは作り直さず dev の確認だけ行って終わります。

### 本番環境を更新する(`2-production-update`)

dev で確認できてから行います。

1. `<アプリ名>/2-production-update` を開き、「Run Job Now」
2. ジョブが本番 PR を作り、出力に URL を表示して **待ち状態** になる
   ```
   PR作成: https://github.com/silver198545/ibid-fleet-config/pull/123
   PRのレビュー・マージを待っています(最大240分。マージは人が行う): ...
   ```
3. **管理者に PR の URL を伝えて、承認(Approve)とマージを依頼する**
4. マージされると、ジョブが自動で続きを行い、本番の確認まで進む。最後に次の行が出れば成功
   ```
   OK: <アプリ名>.production.ibid.lan/... は200を返しました。
   ```
5. 上表の本番の確認先をブラウザで開き、動作を確認する

dev と本番に差分が無いときは、PR は作らず本番の確認だけ行って終わります。

## 動作の仕組み

### `1-dev-update`

1. `~/ibid-fleet-config` を GitHub の最新(`main`)に揃える
2. `src_ref` が空欄なら、取り込み元リポジトリの最新コミットを調べる。今のイメージと同じなら 6 へ
3. イメージのタグとコミットを書き換える PR を作り、自動でマージする
4. GitHub Actions がイメージをビルドするのを待つ
5. dev のマニフェストを新しいタグにする PR を作り、自動でマージする(Fleet が dev1 に反映する)
6. dev の rollout と WEB の応答(200 か)を確認する

### `2-production-update`

1. `~/ibid-fleet-config` を最新に揃える
2. dev と本番に差分があれば、promote ワークフローで本番 PR を作る(作成者は `ibid-ops-bot`)
3. **人が PR を承認・マージするのを待つ**(このジョブはマージしない)
4. マージされたら最新を取り込み、Fleet の反映を待って(60 秒)、本番の rollout と WEB の応答を確認する

## ログの確認

Rundeck のジョブの実行画面(Log Output)に、すべての出力が残ります。

| 出力 | 意味 |
|---|---|
| `main: <コミット> <メッセージ>` | リポジトリを最新に揃えた |
| `tag省略のため自動採番しました: A → B` | 新しいイメージのタグ |
| `PR作成: https://...` | 作った PR |
| `マージされました: <SHA>` | PR がマージされた |
| `OK: ... は200を返しました。` | WEB の応答が正常 |
| `images/<app>/SRC_REF は既に ... です` | 新しいコミットが無いので dev の確認だけ行った |

作られた PR は GitHub の Pull requests でも見られます。本文の最後に「実行者: <あなた>(Rundeck、...)」と入ります。

## 注意事項

* **本番の PR は自分ではマージできません。** 管理者の承認が必要です。
* `merge_wait_minutes` を過ぎてもマージされないと、ジョブは失敗で終わります。PR は残るので、マージ後に `9-check` を `env=production` で実行して確認してください。
* 同じジョブは同時に1つしか動きません(実行中は待たされます)。
* rancher の `~/ibid-fleet-config` を手で編集しないでください。未コミットの変更が残っていると、すべてのジョブが最初で止まります。
* 本番(prod1)は見るだけです。
* kubeconfig は 30 日で期限が切れます。
* 非公開の取り込み元(PENQEinc など)に自分の GitHub アカウントの読み取り権限が無いと、`src_ref` 空欄では動きません。その場合は、取り込むコミットの SHA を `src_ref` に入れてください。

## トラブルシューティング

| 症状(出力) | 対処 |
|---|---|
| `エラー: <リポジトリ>の最新コミット取得に失敗しました。` | 取り込み元の読み取り権限がありません。`src_ref` にコミットの SHA を入れて実行する。権限が要るなら管理者に相談する |
| `Unauthorized` / `You must be logged in to the server` | kubeconfig の期限切れ。「初回設定 3」で取り直す |
| `エラー: 作業ツリーに未コミットの変更があります` | rancher で `cd ~/ibid-fleet-config && git status` を見る。心当たりが無ければ管理者に相談する |
| `このクローンは他のジョブが使用中です。空くのを待っています` | 自分の別のジョブが動いています。終わるまで待つ |
| `エラー: ...分待ってもマージされませんでした` | PR はそのまま残っています。管理者に承認・マージを依頼し、マージ後に `9-check`(`env=production`)で確認する |
| `警告: 200以外です。` | ブラウザで確認先を開き、管理者に連絡する |
| `forbidden`(本番) | 本番は見るだけです。本番を操作する作業は管理者に依頼する |
| `Permission denied (publickey)` | Rundeck の SSH 鍵の設定。管理者に連絡する |
| `gh: To get started with GitHub CLI, please run: gh auth login` | GitHub 認証が切れています。「初回設定 2」の `gh auth login` をやり直す |
