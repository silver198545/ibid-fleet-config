#!/usr/bin/env bash
# devのサイトのプラグインの状態を調べて知らせる(読むだけ。Gitもクラスタも変えない)。
#
# 2026-11-09から、プラグインは自動では更新しない。サイトの管理者(wpadmins)がdevの管理画面で更新して動作を
# 確かめ、Rundeckの 0-dev-plugin-capture(scripts/capture-plugins.sh)でGitに取り込み、staging → 本番へ昇格する。
# このスクリプトはその判断材料を出す。毎週月曜9:00(JST)にRundeckの tools/plugin-check が --notify all で実行し、
# Slackへ送る。
#
# devのPodの wp plugin list(実際に入っている版)を基準に、新しい版があるもの、devで変更したがGitに取り込んで
# いないものを出す。脆弱性(Wordfence IntelligenceのCritical・High。判定は scripts/lib/vuln_report.py と同じ)の
# ある版を使っているものは先頭で強調し、本番(envs/production/sites/<site>/fleet.yaml)の版に脆弱性があり
# devでは直っているものも出す。詳細は標準出力(Rundeckのログ)とSlackにだけ出す。
# このリポジトリはpublicなので、GitHubには出さない。
#
# 使い方(Gitは変えないので、どのブランチでも実行できる。最新のmainで見ること):
#   scripts/plugin-check.sh all                 # 全サイト。結果を表示するだけ
#   scripts/plugin-check.sh abc abc-en          # サイトを指定
#   scripts/plugin-check.sh --notify all        # Slackへも送る
#
# 認証情報(実行ユーザーのファイル。権限600。置き方は docs/manual-vuln-scan.md「準備」。vuln-scan.sh と共用):
#   ~/.config/ibid-fleet-config/slack-webhook      Slack Incoming WebhookのURL(--notify 用)
#   ~/.config/ibid-fleet-config/wordfence-api-key  Wordfence IntelligenceのAPIキー(無ければ脆弱性を調べない)
#
# 前提: curl、jq、python3とPyYAML、kubectlのコンテキスト dev1(読めないサイトはGitの版で判定する)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/dockerhub.sh
source "$SCRIPT_DIR/lib/dockerhub.sh"
# shellcheck source=lib/slack.sh
source "$SCRIPT_DIR/lib/slack.sh"
# shellcheck source=lib/wordfence.sh
source "$SCRIPT_DIR/lib/wordfence.sh"

die() { echo "エラー: $*" >&2; exit 1; }
usage() { die "使い方: $0 [--notify] <site...|all>"; }

NOTIFY=0
if [[ "${1:-}" == --notify ]]; then
  NOTIFY=1
  shift
fi
[[ $# -ge 1 ]] || usage

for cmd in curl jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' が見つかりません。"
done

files=()
if [[ "$*" == all ]]; then
  files=(envs/dev/sites/*/fleet.yaml)
else
  for s in "$@"; do
    [[ "$s" =~ ^[a-z0-9-]+$ ]] || die "サイト名は英小文字・数字・ハイフンのみ: $s"
    [[ -f "envs/dev/sites/$s/fleet.yaml" ]] || die "envs/dev/sites/$s/fleet.yaml がありません。"
    files+=("envs/dev/sites/$s/fleet.yaml")
  done
fi

SLACK_URL=""
if [[ $NOTIFY -eq 1 ]]; then
  SLACK_URL="$(slack_webhook_url)" || exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# チャートで固定しているWordPressイメージに入っているWordPressのバージョン(bump-plugins.sh と同じ基準)
wp_version="$(image_version bitnami/wordpress "$(pinned_digest charts/ibid-wordpress/values.yaml bitnami/wordpress)")"
[[ -n "$wp_version" ]] || die "固定しているWordPressイメージのバージョンが読めません。"
echo "WordPress ${wp_version} を基準に、${#files[@]}サイトのプラグインを確認します..."

# devに実際に入っているプラグイン
mkdir -p "$WORK/installed"
for f in "${files[@]}"; do
  s="$(basename "$(dirname "$f")")"
  kubectl --context dev1 -n "wordpress-$s" exec "deploy/wordpress-$s" -c wordpress -- \
    wp --path=/opt/bitnami/wordpress --skip-plugins --skip-themes plugin list --format=json --fields=name,version,status \
    >"$WORK/installed/$s.json" 2>/dev/null \
    || { rm -f "$WORK/installed/$s.json"; echo "警告: devの ${s} のプラグイン一覧を取得できません(Gitの版で判定します)。" >&2; }
done

args=(--check-out "$WORK/report.json" --installed-dir "$WORK/installed")
feed="$(wordfence_feed "$WORK")"
if [[ -n "$feed" ]]; then
  args+=(--wordfence "$feed")
else
  echo "警告: Wordfenceのフィードを使えないため(キーが無い・取得に失敗)、脆弱性は調べません(docs/manual-vuln-scan.md「準備」)。" >&2
fi
python3 "$SCRIPT_DIR/lib/plugin_updates.py" "${args[@]}" "$wp_version" "${files[@]}"

echo ""
python3 "$SCRIPT_DIR/lib/plugin_notify.py" --report "$WORK/report.json" --url "${RUNDECK_EXEC_URL:-}" \
  --payload-out "$WORK/slack.json"

if [[ $NOTIFY -eq 1 ]]; then
  echo ""
  if slack_post "$SLACK_URL" "$WORK/slack.json" "$WORK"; then
    echo "Slackへ通知しました。"
  else
    die "Slackへ通知できませんでした。"
  fi
fi
