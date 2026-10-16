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
    実行者本人のアカウントで動くのでGitHub上も本人の操作になるが、Rundeckからの実行であることを残す。"""
    return Literal("set -euo pipefail\ncd " + REPO_PATH + "\n"
                   "export PIPELINE_ACTOR='@job.username@'\n" + body.strip() + "\n")


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


def job(group, name, description, options, steps, timeout):
    return {
        "name": name,
        "group": group,
        "uuid": str(uuid.uuid5(UUID_NS, group + "/" + name)),
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
    }


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

devでブラウザ確認したら「2-production-update」で本番へ。
""", dev_options, dev_steps, "90m"))

    jobs.append(job(group, "2-production-update", f"""
【本番環境更新パイプライン】{app}

envs/production/apps/{app} を dev と同じ内容にする昇格PRを promote ワークフローで作り、
**人がPRをレビュー・マージするのを待つ(このジョブはマージしない)**。マージされたら
mainを取り込み、Fleetの適用を待って本番のrollout・WEB疎通を確認する。
devと本番に差分が無ければPRは作らず、確認だけ行う。

PRのdiffはイメージタグに限らずdevに入っている変更すべて。内容を見てからマージすること。
マージ待ちの間、クローンのロックは手放すので他のジョブは動ける。
本番にまだ無いアプリはエラーになる(初回は「3-first-promote-prepare」)。
""", [merge_wait_opt()], [
        SYNC_MAIN,
        step("昇格PR作成 → 人のマージ待ち → 本番の確認",
             "MERGE_WAIT_MINUTES='@option.merge_wait_minutes@' "
             "scripts/update-app-image.sh release-production " + app),
    ], "10h"))

    jobs.append(job(group, "3-first-promote-prepare", f"""
【本番への初回昇格 1/2】{app}(本番にまだ無いときだけ。既にあれば「2-production-update」を使う)

envs/dev/apps/{app} を envs/production/apps/{app} へコピーするブランチを作る(コミットはしない)。
出力に表示されるkubesealコマンド(PATを扱うためジョブ化しない)を踏み台端末で人が実行し、
envs/production/secrets/{app}.yaml を作ってから「4-first-promote-finish」を実行する。

**finishまでの間、クローンは未コミットのまま残る**。他のジョブは「mainを最新化」で止まる。
""", [], [
        SYNC_MAIN,
        step("productionへのコピー(コミットしない)",
             "scripts/update-app-image.sh promote-production " + app),
    ], "30m"))

    jobs.append(job(group, "4-first-promote-finish", f"""
【本番への初回昇格 2/2】{app}

kubesealでSealedSecretを作った後に実行。コミット・PR作成まで行う。
マージはレビューのうえ人が行い、マージ後に「9-check」(env=production)で確認する。
""", [], [
        step("コミット・PR作成",
             "scripts/update-app-image.sh promote-production-finish " + app),
    ], "30m"))

    jobs.append(job(group, "9-check", f"""
{app} のrollout状況とWEB疎通(readinessProbeのpathで200か)を確認する(読み取りのみ)。
""", [opt("env", "確認する環境", value="dev", values=["dev", "production"], required=True, enforced=True)], [
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
                   "yes: 本番のバックアップを今すぐ取ってそれを使う / no: 最新の日次バックアップ(JST 3:00)を使う",
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

        job(group, "2-rehearsal", """
【本番データのリハーサル】

dev1に一時サイト <site>-rh を本番と同じ構成で作り(devだけのPRなのでauto-merge)、本番の最新
コンテンツをリストアして比較の基準(各ページのHTTPステータス・WordPress/プラグインの版)を記録する。
upgrade=yes なら続けて <site>-rh をdevの構成(昇格予定の helm.version・plugins)へ切り替え、
プラグイン同期Job・DB更新(wp core update-db)の所要時間、MariaDBのアップグレード、
ページの表示、PHPエラーを基準と比べて報告する。

WordPress本体のメジャー更新・MariaDBのメジャー更新・プラグインの大きな更新の前に行う
(docs/operations-flow.md「本番データリハーサル」)。dev1のメモリの都合で同時に1サイトまで。
結果は昇格PRに書き、終わったら「2b-rehearsal-cleanup」で必ず削除する。
""", [
            sites_opt(both, "リハーサルする本番のサイト", multi=False),
            fresh,
            yes_no("upgrade", "yes: 続けてdevの構成へ切り替えて確認する / no: 本番のコピーを作るところまで", "yes"),
        ], [
            SYNC_MAIN,
            step("リハーサルサイト作成 → 本番データのリストア → 基準の記録",
                 fresh_env + " scripts/wordpress-pipeline.sh rehearsal-start '@option.site@'"),
            step("devの構成へ切り替え → 基準と比較(upgrade=yesのとき)",
                 "if [ '@option.upgrade@' = yes ]; then\n"
                 "  scripts/wordpress-pipeline.sh rehearsal-upgrade '@option.site@'\n"
                 "else\n"
                 "  echo 'upgrade=no のため切り替えません。あとで 2a-rehearsal-upgrade を実行できます。'\n"
                 "fi"),
        ], "6h"),

        job(group, "2a-rehearsal-upgrade", """
【本番データのリハーサル: 切り替えのやり直し】

既にある <site>-rh を、devの現在の構成へ切り替えて基準と比べる。リハーサルで見つかった問題を
devで直したあとや、2-rehearsal を upgrade=no で実行したあとに使う。
""", [sites_opt(both, "リハーサル中のサイト(<site>-rh の <site>)", multi=False)], [
            SYNC_MAIN,
            step("devの構成へ切り替え → 基準と比較",
                 "scripts/wordpress-pipeline.sh rehearsal-upgrade '@option.site@'"),
        ], "3h"),

        job(group, "2b-rehearsal-cleanup", """
【本番データのリハーサル: 後片付け】

<site>-rh をGitから削除するPRを作ってauto-mergeし、マージ後にdev1の wordpress-<site>-rh
namespace(本番データのコピー)を削除する。harvesterのPVがReleasedで残ったら警告を出す。
""", [sites_opt(both, "削除するリハーサルサイトの元のサイト名(<site>-rh の <site>)", multi=False)], [
            SYNC_MAIN,
            step("Gitから削除 → namespace削除",
                 "scripts/wordpress-pipeline.sh rehearsal-cleanup '@option.site@'"),
        ], "1h"),

        job(group, "3-production-promote", """
【本番昇格パイプライン】

devと本番で差分のあるサイトの昇格PRを promote ワークフローで作り、CI通過後に対象サイトの
本番バックアップを取って(結果はPRにコメントする)、**人がPRをレビュー・マージするのを待つ
(このジョブはマージしない)**。マージされたらFleetの適用(Helmリビジョンの更新とrollout)を待ち、
本番のHTTP 200・Pod・MariaDBのアップグレード状況を確認する。差分が無ければ確認だけ行う。

all は本番に既にあるサイトだけが対象。devにしか無いサイトを本番へ追加するときはサイト名を選ぶ
(先に scripts/seal-site-secrets.sh production <site> のSecretをmainへ入れておくこと)。
DBマイグレーションを伴う更新なら、先に「2-rehearsal」を済ませておく。
""", [
            sites_opt(["all"] + dev_sites, "昇格するサイト(all、または複数選択)", default="all"),
            merge_wait_opt(),
        ], [
            SYNC_MAIN,
            step("昇格PR作成 → 本番バックアップ → 人のマージ待ち → 反映確認",
                 "MERGE_WAIT_MINUTES='@option.merge_wait_minutes@' "
                 "scripts/wordpress-pipeline.sh promote-production @option.sites@"),
        ], "10h"),

        job(group + "/tools", "backup", """
日次バックアップのCronJobから今すぐ1つ取る(完了まで待つ)。出力はNFSの backup/<env>/wordpress-<site>/。
""", [
            opt("env", "環境", value="production", values=["production", "dev"], required=True, enforced=True),
            sites_opt(["all"] + every, "サイト(all、または複数選択)", default="all"),
        ], [
            SYNC_MAIN,
            step("バックアップ", "scripts/wordpress-pipeline.sh backup '@option.env@' @option.sites@"),
        ], "2h"),

        job(group + "/tools", "check", """
各サイトのHTTPステータス(200か)と、正常でないPodが無いかを確認する(読み取りのみ)。
""", [
            opt("env", "環境", value="production", values=["production", "dev"], required=True, enforced=True),
            sites_opt(["all"] + every, "サイト(all、または複数選択)", default="all"),
        ], [
            SYNC_MAIN,
            step("確認", "scripts/wordpress-pipeline.sh check '@option.env@' @option.sites@"),
        ], "15m"),
    ]


HEADER = """# 自動生成ファイル。直接編集せず rundeck/generate-jobs.py を直して再生成すること。
# 取り込み: rd jobs load -p <プロジェクト名> -f {path} --format yaml
# 説明: docs/manual-rundeck.md
"""


def render(jobs, path):
    body = yaml.dump(jobs, Dumper=Dumper, allow_unicode=True, sort_keys=False, width=1000)
    return HEADER.format(path=path) + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="ファイルが生成結果と一致するか確認する")
    args = ap.parse_args()

    data_apps = persistent_data_apps()
    apps = []
    for app in dirs("envs/dev/apps"):
        apps += app_jobs(app, app in data_apps)

    dev_sites = [s for s in dirs("envs/dev/sites") if not s.endswith("-rh")]

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
