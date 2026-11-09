#!/usr/bin/env bash
# devのサイトのプラグインを、WordPress.orgの最新版へ上げるPRを作ってマージする。
#
# envs/dev/sites/<site>/fleet.yaml の plugins: にある version 固定を、WordPress.orgの最新の
# 安定版へ書き換える(scripts/lib/plugin_updates.py)。次のものは上げない:
#   - 最新版が今のWordPress(チャートで固定しているイメージの版)より新しいWordPressを必要とするもの
#   - WordPress.orgで公開停止されたもの(警告だけ出す。継続利用するか要検討)
# PRはvalidate通過後にauto-mergeし、devのFleetがプラグイン同期Jobで適用する。
# productionへは触らない。devで確認後、通常どおり promote ワークフローで昇格する。
#
# 2026-11-09から自動では実行しない。通常の運用は、サイトの管理者(wpadmins)がdevの管理画面で更新して確かめ、
# scripts/capture-plugins.sh(Rundeckの 0-dev-plugin-capture)でGitに取り込む。このスクリプトは、管理画面を
# 通さずGit側でまとめて最新版へ上げたいときの運用者向けの手段として残す。
#
# 使い方(mainブランチ・origin/mainと同期した状態で実行):
#   scripts/bump-plugins.sh abc abc-en        # サイトを指定(そのサイトのプラグインをすべて最新へ)
#   scripts/bump-plugins.sh all               # devの全サイト
#   scripts/bump-plugins.sh --dry-run abc     # 書き換えだけ行い、PRは作らない(差分は git diff で見る)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/pr.sh
source "$SCRIPT_DIR/lib/pr.sh"
# shellcheck source=lib/dockerhub.sh
source "$SCRIPT_DIR/lib/dockerhub.sh"

usage() { echo "使い方: $0 [--dry-run] <site...|all>" >&2; exit 1; }
dry_run=false
if [[ "${1:-}" == --dry-run ]]; then
  dry_run=true
  shift
fi
[[ $# -ge 1 ]] || usage

sites=()
if [[ "$*" == all ]]; then
  for f in envs/dev/sites/*/fleet.yaml; do
    sites+=("$(basename "$(dirname "$f")")")
  done
else
  for s in "$@"; do
    [[ "$s" =~ ^[a-z0-9-]+$ ]] || { echo "エラー: サイト名は英小文字・数字・ハイフンのみ: $s" >&2; exit 1; }
    [[ -f "envs/dev/sites/$s/fleet.yaml" ]] || { echo "エラー: envs/dev/sites/$s/fleet.yaml がありません。" >&2; exit 1; }
    # 重複は除く(Rundeckで同じサイトを2回選んだ場合など)
    [[ " ${sites[*]:-} " == *" $s "* ]] || sites+=("$s")
  done
fi
files=()
for s in "${sites[@]}"; do
  files+=("envs/dev/sites/$s/fleet.yaml")
done

for cmd in git gh python3 curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "エラー: '$cmd' が見つかりません。" >&2; exit 1; }
done

# Rundeckの他のジョブと同じクローンでブランチを切り替え合わないよう、PRを作り終えるまでロックする
$dry_run || pr_lock_repo
pr_ensure_clean_worktree
$dry_run || pr_require_main_uptodate

# チャートで固定しているWordPressイメージに入っているWordPressのバージョン
wp_version="$(image_version bitnami/wordpress "$(pinned_digest charts/ibid-wordpress/values.yaml bitnami/wordpress)")"
[[ -n "$wp_version" ]] || { echo "エラー: 固定しているWordPressイメージのバージョンが読めません。" >&2; exit 1; }
echo "WordPress ${wp_version} を基準にプラグインの最新版を確認します..."

summary="$(python3 "$SCRIPT_DIR/lib/plugin_updates.py" "$wp_version" "${files[@]}")"
if [[ -z "$summary" ]]; then
  echo "更新できるプラグインはありません。"
  exit 0
fi
echo "更新するプラグイン:"
echo "$summary"
if $dry_run; then
  echo "(--dry-run のためPRは作りません。元に戻す: git checkout -- ${files[*]})"
  exit 0
fi

# PRのタイトル・ブランチ名に入れる対象(全サイトや多数なら件数で書く)
if [[ "$*" == all ]]; then
  target="devの全サイト" label="all"
elif [[ ${#sites[@]} -le 3 ]]; then
  target="$(printf '%s・' "${sites[@]}")" label="$(IFS=-; echo "${sites[*]}")"
  target="devの${target%・}"
else
  target="devの${#sites[@]}サイト" label="${#sites[@]}sites"
fi
branch="plugins/dev-${label}-$(date +%Y%m%d%H%M%S)"
git checkout -b "$branch"
git add "${files[@]}"
pr_commit_push_create "chore: ${target}のWordPressプラグインを最新版へ更新" "$(cat <<EOF
## 内容
\`scripts/bump-plugins.sh\` で作成。${target}のプラグインを、WordPress.orgの最新版
(WordPress ${wp_version} で動くもの)へ更新する。

${summary}

マージ後、devのFleetが各サイトのプラグイン同期Jobで適用する。
メジャー更新を含む場合は各プラグインの変更履歴を確認し、必要ならstagingで本番データを入れて確かめる
(docs/operations-flow.md)。devで確認後、サイトごとにstagingを通してproductionへ昇格する(docs/runbook/wordpress-update.md)。
EOF
)" || exit 1
pr_unlock_repo
pr_automerge_and_wait "$PR_URL"
echo "devへの反映が始まりました(各サイトのプラグイン同期Jobが数分で適用します)。"
