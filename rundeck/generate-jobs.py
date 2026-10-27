#!/usr/bin/env python3
"""Rundeckのジョブ定義(rundeck/jobs/*.yaml)を、リポジトリの現状から生成する。

ジョブの中身はscripts/のサブコマンドを呼ぶだけで、パイプラインの処理そのものは
scripts/update-app-image.sh(自作アプリ)と scripts/wordpress-pipeline.sh(WordPress)にある。
アプリは envs/dev/apps/<app> ごとにジョブを作り、WordPressのサイトは選択肢として並べる。
生成内容は envs/dev/ と scripts/update-app-image.sh だけで決まる(本番への昇格PRで変わらないように、
envs/production/ は見ない。本番に有る・無いはジョブ実行時にスクリプトが確かめる)。
アプリ・サイトを追加・削除したら再生成してRundeckへ取り込み直す(docs/manual-rundeck.md)。

使い方:
  python3 rundeck/generate-jobs.py           # rundeck/jobs/*.yaml を書き出す
  python3 rundeck/generate-jobs.py --check   # 生成結果とファイルが一致するか確認する(validateワークフロー用)
"""

import argparse
import re
import sys
import uuid
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "rundeck" / "jobs"

# ジョブを実行するRundeckノードと、そこでのクローンのパス。
# ノード(rancherホスト、タグ rancher)は username: ${job.username} で、ジョブを実行した人の
# OSユーザーとしてSSHする。GitHub・kubectlもその人の認証で動く(docs/manual-rundeck.md「実行アカウント」)。
# クローンは各ユーザーのホームに置く。別ホストへ持っていく場合はここを変えて再生成する。
NODE_FILTER = "tags: rancher"
REPO_PATH = '"$HOME/ibid-fleet-config"'

# ジョブのUUIDはグループ・名前から決める(再生成・再取り込みしても同じジョブを更新するため)
UUID_NS = uuid.UUID("6f1c0d7e-3b51-4f6a-9a51-6f1b8a2c9d40")

MERGE_WAIT_VALUES = ["60", "120", "240", "480"]

# staging1でWordPressのオペレータ(wpadmins)が触れるRancherのプロジェクト(<クラスタID>:<プロジェクトID>)。
# staging-startが作るnamespaceにこの注釈を付ける。空ならプロジェクトの外に作られ、管理者しか触れない
# (docs/manual-rundeck.md「WordPressのオペレータ」)。staging1のクラスタIDは c-m-qqhsg9c2
STAGING_PROJECT_ID = "c-m-qqhsg9c2:p-vk6k8"  # staging1の Wordpress プロジェクト(2026-10-25作成)

# 出力ファイル → 取り込み先のRundeckプロジェクト(2026-10-17に分けた。docs/manual-rundeck.md)
PROJECTS = {
    "rundeck/jobs/apps.yaml": "Rancher-AppControll",
    "rundeck/jobs/wordpress.yaml": "WordPressControl",
}


class Literal(str):
    """複数行の文字列を | のブロックで書き出すための印"""


class Dumper(yaml.SafeDumper):
    # 共通のステップ(SYNC_MAIN)をアンカー・エイリアスにせず、ジョブごとに展開して書く
    def ignore_aliases(self, data):
        return True


Dumper.add_representer(
    Literal, lambda d, v: d.represent_scalar("tag:yaml.org,2002:str", v, style="|")
)


def script(body):
    """Rundeckのインラインスクリプトステップ(bashで実行)。リポジトリのルートで動く。
    PIPELINE_ACTOR(Rundeckでジョブを実行した人)は、スクリプトがPRに書き残す(scripts/lib/pr.sh)。
    RUNDECK_EXEC_URL(この実行のログのURL)は、scripts/qa.sh がGitHubに記録するQA結果のリンクにする。
    実行者本人のアカウントで動くのでGitHub上も本人の操作になるが、Rundeckからの実行であることを残す。"""
    return Literal("set -euo pipefail\ncd " + REPO_PATH + "\n"
                   "export PIPELINE_ACTOR='@job.username@'\n"
                   "export RUNDECK_EXEC_URL='@job.url@'\n" + body.strip() + "\n")


def step(description, body):
    return {
        "description": description,
        "script": script(body),
        "scriptInterpreter": "/bin/bash",
    }


# 他のジョブが同じクローンを使っていないことを確かめて(scripts/lib/pr.sh pr_lock_repoと同じロック)、
# mainをorigin/mainに揃える。
SYNC_MAIN = step(
    "mainを最新化",
    """
exec 9>"$(git rev-parse --git-dir)/ibid-pipeline.lock"
flock -w 3600 9
if [ -n "$(git status --porcelain)" ]; then
  echo "エラー: 作業ツリーに未コミットの変更があります(初回昇格の途中など)。確認してから再実行してください。" >&2
  git status --short >&2
  exit 1
fi
git checkout -q main
git pull -q --ff-only origin main
echo "main: $(git log -1 --format='%h %s')"
""",
)


def opt(name, description, value=None, values=None, required=False, enforced=False,
        regex=None, multivalued=False):
    o = {"name": name, "description": description}
    if required:
        o["required"] = True
    if value is not None:
        o["value"] = value
    if values is not None:
        o["values"] = values
        o["valuesListDelimiter"] = ","
        o["enforced"] = enforced
    if regex:
        o["regex"] = regex
    if multivalued:
        o["multivalued"] = True
        o["delimiter"] = " "
    return o


def yes_no(name, description, default):
    return opt(name, description, value=default, values=["yes", "no"], required=True, enforced=True)


def merge_wait_opt():
    return opt("merge_wait_minutes",
               "本番PRのレビュー・マージを待つ時間(分)。過ぎたらジョブは失敗で終わる(PRはそのまま残る)",
               value="240", values=MERGE_WAIT_VALUES, required=True, enforced=True)


def job(path, name, description, options, steps, timeout, schedule=None):
    """path は「プロジェクト/グループ」(apps/<app>、wordpress、wordpress/tools)。
    Rundeckのプロジェクトはアプリ・WordPressで分けている(PROJECTS)ので、先頭(プロジェクト分)を除いた
    残りをRundeck上のグループにする。UUIDは2026-10-16までの定義(1プロジェクトでグループ apps/・wordpress/)
    と同じ値を保つため path から計算する(取り込み直すと同じジョブが更新される)。
    schedule は定期実行の (曜日, 時, 分)(JST)。定期実行はジョブを取り込んだ人として動く
    (docs/manual-rundeck.md「定期実行」)。"""
    group = path.partition("/")[2]
    j = {"name": name}
    if group:
        j["group"] = group
    j.update({
        "uuid": str(uuid.uuid5(UUID_NS, path + "/" + name)),
        "description": Literal(description.strip() + "\n"),
        "loglevel": "INFO",
        "executionEnabled": True,
        "scheduleEnabled": True,
        "multipleExecutions": False,
        "timeout": timeout,
        "nodefilters": {"filter": NODE_FILTER},
        "nodesSelectedByDefault": True,
        "options": options,
        "sequence": {"keepgoing": False, "strategy": "node-first", "commands": steps},
    })
    if schedule:
        day, hour, minute = schedule
        j["schedule"] = {"month": "*", "time": {"hour": f"{hour:02d}", "minute": f"{minute:02d}", "seconds": "0"},
                         "weekday": {"day": day}, "year": "*"}
        j["timeZone"] = "Asia/Tokyo"
    return j


# 週次の脆弱性チェック(scripts/vuln-scan.sh --notify。docs/manual-vuln-scan.md)。アプリ・WordPressの
# プロジェクトにそれぞれ置く。Trivyのキャッシュを取り合わないよう時刻をずらす
VULN_SCHEDULE = {"apps": ("MON", 8, 0), "sites": ("MON", 8, 30)}


def vuln_job(path, kind, targets_opt):
    targets = "@option." + targets_opt["name"] + "@"
    return job(path, "vuln-scan", f"""
脆弱性チェック(docs/manual-vuln-scan.md)。動いているイメージをTrivyで検査し、
{"WordPressのコア・プラグイン・テーマをWordfenceのフィードと照らし合わせ、" if kind == "sites" else "上流の未取り込みのコミットも調べ、"}
ランタイムのEOLも見る。判定の基準と除外は qa/vuln-policy.yaml。
毎週月曜 {VULN_SCHEDULE[kind][1]}:{VULN_SCHEDULE[kind][2]:02d}(JST)に production の全件を検査し、Slackへ通知する
(前回から新たに見つかったものを強調する)。読み取りだけで、クラスタ・Gitは変えない。
env=staging では結果(合否だけ)をGitHubに記録する。stagingのQA(scripts/qa.sh)も同じ検査を自動で行う。
""", [
        opt("env", "検査する環境", value="production", values=["production", "staging", "dev"],
            required=True, enforced=True),
        targets_opt,
        yes_no("notify", "結果をSlackへ通知する", "yes"),
    ], [
        SYNC_MAIN,
        step("脆弱性チェック",
             "scripts/vuln-scan.sh $([ '@option.notify@' = yes ] && echo --notify) '@option.env@' " + kind + " " + targets),
    ], "2h", schedule=VULN_SCHEDULE[kind])


def dirs(path):
    p = REPO / path
    return sorted(d.name for d in p.iterdir() if d.is_dir()) if p.is_dir() else []


def persistent_data_apps():
    """update-app-image.sh の persistent_data_dir_for に登録済みのアプリ(sync-dev-data対象)"""
    src = (REPO / "scripts" / "update-app-image.sh").read_text()
    body = re.search(r"persistent_data_dir_for\(\) \{(.*?)\n\}", src, re.S).group(1)
    apps = set()
    for m in re.finditer(r"^\s+([a-z0-9|-]+)\) echo \"/", body, re.M):
        apps.update(m.group(1).split("|"))
    return apps


# ---------------------------------------------------------------------------
# 自作アプリ(apps/<app>)
# ---------------------------------------------------------------------------

def app_jobs(app, has_data):
    group = "apps/" + app
    jobs = []

    dev_options = [
        opt("src_ref", "取り込み元のコミットSHA。空欄なら取り込み元ブランチの最新を使う"
            "(現在のimages/" + app + "/SRC_REFと同じなら、イメージは更新せずdevの確認だけ行う)",
            regex="^([0-9a-f]{7,40})?$"),
        opt("tag", "新しいイメージタグ。空欄なら現在のTAG(<version>-r<N>)から自動採番",
            regex="^([0-9A-Za-z._-]+)?$"),
    ]
    dev_steps = [
        SYNC_MAIN,
        step("イメージ更新 → ビルド → devへ反映 → devの確認",
             "scripts/update-app-image.sh dev-update " + app + " '@option.src_ref@' '@option.tag@'"),
    ]
    if has_data:
        dev_options.append(yes_no(
            "sync_prod_data",
            "最後に本番の永続データをdevへコピーし、本番相当データで確認できるようにする(**devの内容は上書きされる**)",
            "no"))
        dev_steps.append(step(
            "本番の永続データをdevへコピー(sync_prod_data=yesのとき)",
            "if [ '@option.sync_prod_data@' = yes ]; then\n"
            "  scripts/update-app-image.sh sync-dev-data " + app + "\n"
            "else\n"
            "  echo 'sync_prod_data=no のためスキップします。'\n"
            "fi"))
    jobs.append(job(group, "1-dev-update", f"""
【開発環境更新パイプライン】{app}

取り込み元の最新コミット(または指定したsrc_ref)でイメージを作り直し、devへ反映して確認する。
イメージPR → auto-merge → ビルド完了待ち → devのdeployment.yamlを更新するPR → auto-merge →
devのrollout・WEB疎通確認、までを1回で行う(devだけのPRなので承認なしでマージされる)。

devでブラウザ確認したら「2-staging-update」でstagingへ。
""", dev_options, dev_steps, "90m"))

    jobs.append(job(group, "2-staging-update", f"""
【staging更新パイプライン】{app}

envs/staging/apps/{app} を dev と同じ内容にする昇格PRを promote ワークフロー(to=staging)で作り、
auto-mergeを待って(stagingだけのPRなので承認不要)、stagingのrollout・WEB疎通とQAを確認する。
devとstagingに差分が無ければPRは作らず、確認だけ行う。

stagingでブラウザ確認したら「3-production-update」で本番へ。本番へは必ずstagingを通す。
stagingにまだ無いアプリはエラーになる(初回は「4-first-promote-prepare」を env=staging で)。
""", [], [
        SYNC_MAIN,
        step("staging昇格PR作成 → auto-merge → stagingの確認",
             "scripts/update-app-image.sh staging-update " + app),
    ], "1h"))

    jobs.append(job(group, "3-production-update", f"""
【本番環境更新パイプライン】{app}

stagingでQAし(通らなければPRを作らない)、
envs/production/apps/{app} を staging と同じ内容にする昇格PRを promote ワークフロー(to=production)で作り、
**人がPRをレビュー・マージするのを待つ(このジョブはマージしない)**。マージされたら
mainを取り込み、Fleetの適用を待って本番のrollout・WEB疎通を確認する。
stagingと本番に差分が無ければPRは作らず、確認だけ行う。

PRのdiffはイメージタグに限らずstagingに入っている変更すべて。内容を見てからマージすること。
マージ待ちの間、クローンのロックは手放すので他のジョブは動ける。
本番にまだ無いアプリはエラーになる(初回は「4-first-promote-prepare」を env=production で)。
""", [merge_wait_opt()], [
        SYNC_MAIN,
        step("昇格PR作成 → 人のマージ待ち → 本番の確認",
             "MERGE_WAIT_MINUTES='@option.merge_wait_minutes@' "
             "scripts/update-app-image.sh release-production " + app),
    ], "10h"))

    env_opt = opt("env", "初回昇格する先(staging: dev→staging / production: staging→production。必ずstagingが先)",
                  value="staging", values=["staging", "production"], required=True, enforced=True)
    jobs.append(job(group, "4-first-promote-prepare", f"""
【初回昇格 1/2】{app}(昇格先にまだ無いときだけ。既にあれば「2-staging-update」「3-production-update」を使う)

昇格元(staging ならdev、production ならstaging)の {app} を昇格先へコピーするブランチを作る(コミットはしない)。
出力に表示されるkubesealコマンド(PATを扱うためジョブ化しない)を踏み台端末で人が実行し、
envs/<env>/secrets/{app}.yaml を作ってから「5-first-promote-finish」を同じ env で実行する。

**finishまでの間、クローンは未コミットのまま残る**。他のジョブは「mainを最新化」で止まる。
""", [env_opt], [
        SYNC_MAIN,
        step("昇格先へのコピー(コミットしない)",
             "scripts/update-app-image.sh promote-@option.env@ " + app),
    ], "30m"))

    jobs.append(job(group, "5-first-promote-finish", f"""
【初回昇格 2/2】{app}

kubesealでSealedSecretを作った後に、prepareと同じ env で実行。コミット・PR作成まで行う。
stagingはauto-mergeしてstagingの確認まで続ける。productionのPRはレビューのうえ人がマージし、
マージ後に「9-check」(env=production)で確認する。
""", [env_opt], [
        step("コミット・PR作成",
             "scripts/update-app-image.sh promote-@option.env@-finish " + app),
    ], "30m"))

    jobs.append(job(group, "8-qa", f"""
{app} のQA(反映の確認と qa/checks.yaml のチェック。docs/operations-flow.md「QAゲート」)。
env=staging では結果をGitHubに記録し、本番への昇格PRの qa-gate がそれを見る
(通ると、失敗していた qa-gate をやり直させる)。「2-staging-update」「3-production-update」も
同じQAを自動で行うので、これは直した後の再確認や、本番PRのqa-gateが落ちたとき用。
""", [opt("env", "QAする環境(結果を記録するのはstagingだけ)", value="staging",
          values=["staging", "dev", "production"], required=True, enforced=True)], [
        SYNC_MAIN,
        step("QA", "scripts/qa.sh '@option.env@' apps " + app),
    ], "30m"))

    jobs.append(job(group, "9-check", f"""
{app} のrollout状況とWEB疎通(readinessProbeのpathで200か)を確認する(読み取りのみ)。
""", [opt("env", "確認する環境", value="dev", values=["dev", "staging", "production"], required=True, enforced=True)], [
        step("確認", "scripts/update-app-image.sh check-@option.env@ " + app),
    ], "10m"))
    return jobs


# ---------------------------------------------------------------------------
# WordPress
# ---------------------------------------------------------------------------

def wordpress_jobs(dev_sites):
    # 選択肢はdevのサイト一覧。本番に無いサイトを選んだ場合はスクリプトがエラーにする
    group = "wordpress"
    both = every = dev_sites

    def sites_opt(values, description, default=None, multi=True):
        return opt("sites" if multi else "site", description, value=default, values=values,
                   required=True, enforced=True, multivalued=multi)

    fresh = yes_no("fresh_backup",
                   "yes: 本番のバックアップを今すぐ取ってそれを使う(本番の権限が無いオペレータは自動でnoと同じになる) / no: 最新の日次バックアップ(JST 3:00)を使う",
                   "yes")
    fresh_env = "FRESH_BACKUP=$([ '@option.fresh_backup@' = yes ] && echo 1 || echo 0)"

    return [
        job(group, "1-dev-refresh", """
【開発環境更新パイプライン】本番コンテンツ → devの同名サイト

選んだサイトごとに、本番のバックアップ(日次バックアップのCronJobから今すぐ1つ)を取り、
devの現状をバックアップしてから、本番のwp-content・DBをdevへリストアする。
続けてDB内の本番の公開URLをdevの公開URL(wp-config.phpのWP_HOME)へ置換し、HTTP 200を確認する。
gitは触らない。チャート版・プラグイン(構成)はdevのまま変わらない。

**devの記事・設定は本番のもので上書きされる**(上書き前のバックアップはNFSの
backup/dev/wordpress-<site>/ に残る)。全34サイトを選ぶと数時間かかる。
""", [
            sites_opt(both, "コンテンツを本番から戻すdevのサイト(複数選択可)"),
            fresh,
        ], [
            SYNC_MAIN,
            step("本番バックアップ → devバックアップ → リストア → URL置換 → 確認",
                 fresh_env + " scripts/wordpress-pipeline.sh dev-refresh @option.sites@"),
        ], "12h"),

        job(group, "2-staging", """
【stagingで本番データを使って確認する】

選んだサイトを本番と同じ構成でstaging1に置き(stagingだけのPRなのでauto-merge)、本番の最新
コンテンツをリストアして比較の基準(各ページのHTTPステータス・WordPress/プラグインの版)を記録する。
upgrade=yes なら続けてdevの構成(昇格予定の helm.version・plugins)をpromoteワークフローでstagingへ昇格し
(auto-merge)、プラグイン同期Job・DB更新(wp core update-db)の所要時間、MariaDBのアップグレード、
ページの表示、PHPエラーを基準と比べて報告する。本番にまだ無い新規サイトはdevの構成で置くだけ。

本番へはstagingを通して昇格する(docs/operations-flow.md「stagingでの確認」)。staging1のメモリの都合で
同時に4サイトまで。結果は昇格PRに書き、本番へ昇格したら「4-staging-cleanup」で必ず削除する。
""", [
            sites_opt(both, "stagingで確認するサイト", multi=False),
            fresh,
            yes_no("upgrade", "yes: 続けてdevの構成へ切り替えて確認する / no: 本番のコピーを置くところまで", "yes"),
        ], [
            SYNC_MAIN,
            step("stagingへ追加 → 本番データのリストア → 基準の記録",
                 fresh_env + " STAGING_PROJECT_ID='" + STAGING_PROJECT_ID + "'"
                 " scripts/wordpress-pipeline.sh staging-start '@option.site@'"),
            step("devの構成へ切り替え → 基準と比較(upgrade=yesのとき)",
                 "if [ '@option.upgrade@' = yes ]; then\n"
                 "  scripts/wordpress-pipeline.sh staging-upgrade '@option.site@'\n"
                 "else\n"
                 "  echo 'upgrade=no のため切り替えません。あとで 2a-staging-upgrade を実行できます。'\n"
                 "fi"),
        ], "6h"),

        job(group, "2a-staging-upgrade", """
【stagingで確認する: 切り替えのやり直し】

stagingにあるサイトを、devの現在の構成へ切り替えて基準と比べ、QA(本番との比較)を行う。stagingで見つかった問題を
devで直したあとや、2-staging を upgrade=no で実行したあとに使う。
""", [sites_opt(both, "stagingで確認中のサイト", multi=False)], [
            SYNC_MAIN,
            step("devの構成へ切り替え → 基準と比較",
                 "scripts/wordpress-pipeline.sh staging-upgrade '@option.site@'"),
        ], "3h"),

        job(group, "3-production-promote", """
【本番昇格パイプライン】

stagingと本番で差分のあるサイトをstagingでQAし(通らなければPRを作らない)、
昇格PR(staging→production)を promote ワークフローで作り、CI通過後に
対象サイトの本番バックアップを取って(結果はPRにコメントする。本番の権限が無いオペレータが実行した場合は取らず、
「承認する管理者がマージ直前に tools/backup で取る」とPRにコメントする)、**人がPRをレビュー・マージするのを待つ
(このジョブはマージしない)**。マージされたらFleetの適用(Helmリビジョンの更新とrollout)を待ち、
本番のHTTP 200・Pod・MariaDBのアップグレード状況を確認する。差分が無ければ確認だけ行う。

**本番へはstagingに載っている内容を昇格する**(先に「2-staging」で確認しておく)。all はstagingに載っている、
本番にある全サイトが対象。本番に無いサイトを追加するときはサイト名を選ぶ
(先に scripts/seal-site-secrets.sh production <site> のSecretをmainへ入れておくこと)。
終わったら「4-staging-cleanup」でstagingから削除する。
""", [
            sites_opt(["all"] + dev_sites, "昇格するサイト(all、または複数選択)", default="all"),
            merge_wait_opt(),
        ], [
            SYNC_MAIN,
            step("昇格PR作成 → 本番バックアップ → 人のマージ待ち → 反映確認",
                 "MERGE_WAIT_MINUTES='@option.merge_wait_minutes@' "
                 "scripts/wordpress-pipeline.sh promote-production @option.sites@"),
        ], "10h"),

        job(group, "4-staging-cleanup", """
【stagingの後片付け】

サイトをstagingのGitから削除するPRを作ってauto-mergeし、マージ後にstaging1の wordpress-<site>
namespace(本番データのコピー)を削除する。本番へまだ昇格していなければ注意を出す。
harvesterのPVがReleasedで残ったら警告を出す。
""", [sites_opt(both, "stagingから削除するサイト", multi=False)], [
            SYNC_MAIN,
            step("Gitから削除 → namespace削除",
                 "scripts/wordpress-pipeline.sh staging-cleanup '@option.site@'"),
        ], "1h"),

        job(group + "/tools", "backup", """
日次バックアップのCronJobから今すぐ1つ取る(完了まで待つ)。出力はNFSの backup/<env>/wordpress-<site>/。
""", [
            opt("env", "環境", value="production", values=["production", "staging", "dev"], required=True, enforced=True),
            sites_opt(["all"] + every, "サイト(all、または複数選択)", default="all"),
        ], [
            SYNC_MAIN,
            step("バックアップ", "scripts/wordpress-pipeline.sh backup '@option.env@' @option.sites@"),
        ], "2h"),

        job(group + "/tools", "qa", """
QA(反映の確認と qa/checks.yaml のチェック。docs/operations-flow.md「QAゲート」)。
本番にあるサイトは、本番の同じサイトとタイトル等を比べる。env=staging では結果をGitHubに記録し、
本番への昇格PRの qa-gate がそれを見る(通ると、失敗していた qa-gate をやり直させる)。
「2a-staging-upgrade」「3-production-promote」も同じQAを自動で行うので、これは再確認用。
""", [
            opt("env", "環境(結果を記録するのはstagingだけ)", value="staging", values=["staging", "dev", "production"], required=True, enforced=True),
            sites_opt(["all"] + every, "サイト(all、または複数選択)", default="all"),
        ], [
            SYNC_MAIN,
            step("QA", "scripts/qa.sh '@option.env@' sites @option.sites@"),
        ], "30m"),

        vuln_job(group + "/tools", "sites", sites_opt(["all"] + every, "サイト(all、または複数選択)", default="all")),

        job(group + "/tools", "check", """
各サイトのHTTPステータス(200か)と、正常でないPodが無いかを確認する(読み取りのみ)。
""", [
            opt("env", "環境", value="production", values=["production", "staging", "dev"], required=True, enforced=True),
            sites_opt(["all"] + every, "サイト(all、または複数選択)", default="all"),
        ], [
            SYNC_MAIN,
            step("確認", "scripts/wordpress-pipeline.sh check '@option.env@' @option.sites@"),
        ], "15m"),
    ]


HEADER = """# 自動生成ファイル。直接編集せず rundeck/generate-jobs.py を直して再生成すること。
# 取り込み先のRundeckプロジェクト: {project}
# 取り込み: rd jobs load -p {project} -f {path} --format yaml
# 説明: docs/manual-rundeck.md
"""


def render(jobs, path):
    body = yaml.dump(jobs, Dumper=Dumper, allow_unicode=True, sort_keys=False, width=1000)
    return HEADER.format(path=path, project=PROJECTS[path]) + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="ファイルが生成結果と一致するか確認する")
    args = ap.parse_args()

    data_apps = persistent_data_apps()
    apps = []
    for app in dirs("envs/dev/apps"):
        apps += app_jobs(app, app in data_apps)
    apps.append(vuln_job("apps/tools", "apps", opt(
        "apps", "アプリ(all、または複数選択)", value="all", values=["all"] + dirs("envs/dev/apps"),
        required=True, enforced=True, multivalued=True)))

    dev_sites = dirs("envs/dev/sites")

    outputs = {
        "rundeck/jobs/apps.yaml": render(apps, "rundeck/jobs/apps.yaml"),
        "rundeck/jobs/wordpress.yaml": render(wordpress_jobs(dev_sites), "rundeck/jobs/wordpress.yaml"),
    }

    stale = []
    for rel, text in outputs.items():
        p = REPO / rel
        if args.check:
            if not p.exists() or p.read_text() != text:
                stale.append(rel)
        else:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
            print("書き出しました:", rel)
    if stale:
        print("エラー: Rundeckのジョブ定義が envs/ の現状と合っていません: " + ", ".join(stale), file=sys.stderr)
        print("python3 rundeck/generate-jobs.py で再生成してコミットしてください。", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
