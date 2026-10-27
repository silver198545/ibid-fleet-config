# 脆弱性チェック

自作アプリとWordPressサイトの既知の脆弱性と、ランタイムのサポート終了(EOL)を調べる仕組み(2026-10-27〜)。
QAゲート([operations-flow.md](operations-flow.md)「QAゲート」)の一部として、stagingで昇格前に調べるのに加え、
**毎週productionの全件を調べてSlackへ通知する**。脆弱性は中身が同じでも、後から新しいCVEが公開されると増えるため。

| 何を | 方法 |
|---|---|
| 動いているイメージ(OSパッケージ、Node・Ruby・PHP等のランタイム、npm・gem等のライブラリ、Bitnamiの部品) | [Trivy](https://github.com/aquasecurity/trivy)(Dockerで実行) |
| WordPressのコア・プラグイン・テーマ | stagingの・本番のPodで `wp core version`・`wp plugin list`・`wp theme list` を取り、[Wordfence Intelligence](https://www.wordfence.com/threat-intel/) のフィードと照らし合わせる(fleet.yamlで宣言していない、wp-content内のプラグインも含む) |
| ランタイム・OSのEOL | [endoflife.date](https://endoflife.date/)(node・ruby・php・mariadb・debian・photon) |
| 自作アプリの取り込み漏れ(週次の通知だけ) | 上流のブランチの最新と `images/<app>/SRC_REF` の比較、本番の版と `images/<app>/TAG` の比較 |

検査するのはクラスタで**実際に動いているイメージ**(Deployment・StatefulSet・CronJob。initContainersを含む)。
読み取りだけで、クラスタ・Gitは変えない(GitHubのcommit statusへの記録を除く)。

## 判定

基準は [qa/vuln-policy.yaml](../qa/vuln-policy.yaml) の先頭にも書いてある(判定は `scripts/lib/vuln_report.py`)。

| 区分 | 扱い |
|---|---|
| 言語パッケージ(npm・gem等)のCRITICALで修正版があるもの | **NG** |
| WordPressのコア・プラグイン・テーマのCriticalで修正版があるもの | **NG** |
| ランタイム・OSのEOLを過ぎたもの | **NG** |
| 言語パッケージ・WordPressのHIGHで修正版があるもの | 警告 |
| OSパッケージのCRITICAL・HIGHで修正版があるもの(イメージを作り直せば直る) | 警告 |
| 修正版の無いWordPressのCritical・High | 警告(プラグイン・テーマの削除・置換を検討) |
| EOLまで `eol_warn_days`(180日)を切ったもの、検査できなかったもの、除外の期限切れ | 警告 |
| 修正版の無いOSパッケージ、MEDIUM以下 | 数えない(件数だけ表示) |

Debian・Photonのパッケージは修正版の無いHIGHが常に数十件あり、これを数えると全アプリが常にNGになるため数えない。

**enforce**: `qa/vuln-policy.yaml` の `enforce` が `false` の間は、NGがあっても記録・通知だけで止めない。
`true` にすると、NG(と検査できないもの)があるとstagingのQA・パイプラインが止まり、本番への昇格PRの `qa-gate` も落ちる。
`qa-gate` はPRではなく**mainの** `qa/vuln-policy.yaml` を読む(昇格PRの中で緩められないように)。

## 結果の置き場所

| どこ | 何を |
|---|---|
| 標準出力(Rundeckのログ) | すべて(パッケージ名・版・CVE・修正版) |
| Slack(週次・`notify=yes`) | 合計、NGのあるもの、**前回から新たに見つかったもの**、更新を促すもの、Rundeckのログへのリンク |
| GitHubのcommit status `vuln/<kind>/<name>`(stagingだけ) | **合否だけ**(OK/NGと警告の件数) |

**このリポジトリはpublicなので、脆弱性の詳細はGitHub(commit status・Actionsのログ・PR)に書かない。**
検査をGitHub Actionsで行わないのもこのため(Actionsのログは誰でも読める)。

## 準備(1回だけ)

検査はRundeckのノード(rancherホスト)で、ジョブを実行した人のOSユーザーとして動く
([manual-rundeck.md](manual-rundeck.md)「実行アカウント」)。週次の定期実行は、ジョブを取り込んだ人として動く。

1. **docker**: 実行する人を `docker` グループに入れ、ログインし直す(`sudo usermod -aG docker <user>`)。
   Trivyのキャッシュ(脆弱性DB)はDockerのボリューム `ibid-trivy-cache` に置く
2. **認証情報**(実行する人のホームに置く。どれもGitには入れない):

   ```bash
   install -d -m 700 ~/.config/ibid-fleet-config
   # Slack: 既存のアラート通知(Alertmanager。manual-monitoring.md)と同じチャンネルのIncoming Webhook URL。
   # SealedSecretからは戻せないので、SlackのアプリのIncoming Webhooksの画面から写す
   ( umask 077; read -rs -p 'Slack Webhook URL: ' v; echo; printf '%s\n' "$v" > ~/.config/ibid-fleet-config/slack-webhook )
   # Wordfence: https://www.wordfence.com/ でアカウントを作り、Wordfence IntelligenceのAPIキー(無料)を発行する
   ( umask 077; read -rs -p 'Wordfence API key: ' v; echo; printf '%s\n' "$v" > ~/.config/ibid-fleet-config/wordfence-api-key )
   ```

   - `slack-webhook` は週次の通知(`--notify`)に必要。無いと `--notify` はエラーで止まる
   - `wordfence-api-key` が無いと、WordPressのコア・プラグイン・テーマの検査を飛ばし、警告を出す
     (フィードは12時間キャッシュする: `~/.cache/ibid-fleet-config/vuln/`)
   - 非公開のGHCRイメージを読めず「検査できませんでした」になるときは、`read:packages` だけのclassic PATを
     `~/.config/ibid-fleet-config/ghcr-read-token` に同じ要領で置く(2026-10-27時点では不要だった)
3. **Rundeckのジョブを取り込む**([manual-rundeck.md](manual-rundeck.md)「取り込み・更新」)。週次の実行は、
   取り込んだ人の認証(kubectl・gh・上の認証情報)で動くので、本番のPodへのexec権限を持つ人が取り込む

## 実行

| 場面 | 何が起こるか |
|---|---|
| stagingのQA(`scripts/qa.sh staging ...`。パイプラインの中でも自動) | QAのあとに検査し、合否を `vuln/<kind>/<name>` に記録する |
| 毎週月曜 8:00(アプリ)・8:30(WordPress)JST | Rundeckの `tools/vuln-scan` がproductionの全件を検査し、Slackへ通知する |
| 手動 | Rundeckの `tools/vuln-scan`(`Rancher-AppControll`・`WordPressControl` のそれぞれ)、または `scripts/vuln-scan.sh` |

```bash
scripts/vuln-scan.sh staging apps riken-diips              # 1つだけ(stagingは結果を記録する)
scripts/vuln-scan.sh --notify production sites all         # 週次と同じ(Slackへ通知)
QA_NO_STATUS=1 scripts/vuln-scan.sh staging sites abc      # 記録せずに試す
```

所要時間の目安: アプリ1つで30秒〜1分(初回は脆弱性DBの取得で数分)。サイトは同じイメージを1回だけ検査するので、
34サイトでも数分。

## 見つかったときの対応

| 何が | 直し方 |
|---|---|
| 自作アプリのライブラリ(npm・gem) | 上流のリポジトリで更新してもらい、`scripts/update-app-image.sh set-image <app> <SHA>` で取り込む([runbook/app-update.md](runbook/app-update.md)) |
| 自作アプリのOSパッケージ・ベースイメージ | `SRC_REF` はそのままで `TAG` だけ上げて作り直す(ベースイメージの最新を取り込む) |
| 自作アプリのランタイムのEOL | `images/<app>/Dockerfile` の `FROM` の版を上げる |
| Bitnami(WordPress・MariaDB)のイメージ | `scripts/bump-chart.sh --update-images`(毎週の `auto-update` でもdevへ入る)→ 各サイトへ昇格 |
| WordPressのプラグイン・テーマ | fleet.yamlの `plugins` で宣言しているものは版を上げる(`scripts/bump-plugins.sh`)。宣言していないもの(wp-content内)は、サイトの管理画面で更新するか、`plugins` で宣言して版を固定する([manual-wordpress.md](manual-wordpress.md)) |
| 修正版が無い | 使っていなければ削除する。使っているなら代わりを探す。すぐ直せないときは下の除外を期限付きで書く |

## 除外

使われていない(例: 実行時に読み込まれない開発用のパッケージ)・攻撃できないと判断したものは、
[qa/vuln-policy.yaml](../qa/vuln-policy.yaml) の `ignore` に**理由と期限**を書いて除く(PRでレビューする)。
期限を過ぎた除外は効かなくなり、警告が出る(`validate` も警告を出す)。enforce: true のときに、急ぎの修正が
既存の脆弱性で止められたら、期限付きの除外を足すPRで通す。

```yaml
ignore:
  - id: CVE-2026-71319            # CVE・GHSA等(Wordfenceの番号はCVEが無ければWordfenceのID)
    targets: [brc-advanced-search] # 省略するとすべてのアプリ・サイト
    pkg: "@nuxt/devtools"          # 省略すると id だけで判定
    reason: 開発用。nuxt start では読み込まれない
    until: 2027-01-31
```

## 導入の段階

| 段階 | 内容 | 止めるか | 状況 |
|---|---|---|---|
| 1 | 週次のproductionの検査とSlackへの通知。除外を整える | 止めない | 2026-10-27〜 |
| 2 | stagingのQAで検査し、`vuln/<kind>/<name>` に記録する(`qa-gate` は表に出すだけ) | 止めない | 2026-10-27〜 |
| 3 | `enforce: true`。修正版のあるCRITICALがあると、昇格を止める | **止める** | 未(週次の結果を見て決める) |

段階3へ進む前に、週次の結果でNGが常に出ているものを片付けるか、除外する(例: 2026-10-27の初回では
riken-diipsのNext.js 15.0.5がNG。上流の管理者の対応待ち)。

## Trivyの更新

`scripts/vuln-scan.sh` の `TRIVY_IMAGE` はタグとdigestで固定している(スキャナ自体を意図せず差し替えられないように)。
脆弱性DBは実行のたびに最新を取るので、普段は上げなくてよい。上げるときはリリースノートとsecurity advisoryを確認し、
リリースから少なくとも2週間たったものを選んで、タグとdigestを一緒に変える。

```bash
docker pull aquasec/trivy:<版> && docker image inspect aquasec/trivy:<版> --format '{{index .RepoDigests 0}}'
```
