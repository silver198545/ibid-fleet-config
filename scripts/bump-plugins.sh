#!/usr/bin/env bash
# devの全サイトのプラグインを、WordPress.orgの最新版へ上げるPRを作ってマージする。
#
# envs/dev/sites/*/fleet.yaml の plugins: にある version 固定を、WordPress.orgの最新の
# 安定版へ書き換える(scripts/lib/plugin_updates.py)。次のものは上げない:
#   - 最新版が今のWordPress(チャートで固定しているイメージの版)より新しいWordPressを必要とするもの
#   - WordPress.orgで公開停止されたもの(警告だけ出す。継続利用するか要検討)
# PRはvalidate通過後にauto-mergeし、devのFleetがプラグイン同期Jobで適用する。
# productionへは触らない。devで確認後、通常どおり promote ワークフローで昇格する。
#
# 手元からも .github/workflows/auto-update.yaml(毎週の定期実行)からも使う。
#
# 使い方(mainブランチ・origin/mainと同期した状態で実行):
#   scripts/bump-plugins.sh
#   scripts/bump-plugins.sh --dry-run   # 書き換えだけ行い、PRは作らない(差分は git diff で見る)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/pr.sh
source "$SCRIPT_DIR/lib/pr.sh"
# shellcheck source=lib/dockerhub.sh
source "$SCRIPT_DIR/lib/dockerhub.sh"

dry_run=false
case "${1:-}" in
  --dry-run) dry_run=true ;;
  "") ;;
  *) echo "使い方: $0 [--dry-run]" >&2; exit 1 ;;
esac

for cmd in git gh python3 curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "エラー: '$cmd' が見つかりません。" >&2; exit 1; }
done

pr_ensure_clean_worktree
$dry_run || pr_require_main_uptodate

# チャートで固定しているWordPressイメージに入っているWordPressのバージョン
wp_version="$(image_version bitnami/wordpress "$(pinned_digest charts/ibid-wordpress/values.yaml bitnami/wordpress)")"
[[ -n "$wp_version" ]] || { echo "エラー: 固定しているWordPressイメージのバージョンが読めません。" >&2; exit 1; }
echo "WordPress ${wp_version} を基準にプラグインの最新版を確認します..."

summary="$(python3 "$SCRIPT_DIR/lib/plugin_updates.py" "$wp_version" envs/dev/sites/*/fleet.yaml)"
if [[ -z "$summary" ]]; then
  echo "更新できるプラグインはありません。"
  exit 0
fi
echo "更新するプラグイン:"
echo "$summary"
if $dry_run; then
  echo "(--dry-run のためPRは作りません。元に戻す: git checkout -- envs/dev/sites)"
  exit 0
fi

branch="plugins/dev-$(date +%Y%m%d%H%M)"
git checkout -b "$branch"
git add envs/dev/sites
pr_commit_push_create "chore: devのWordPressプラグインを最新版へ更新" "$(cat <<EOF
## 内容
\`scripts/bump-plugins.sh\` で作成。devのサイトのプラグインを、WordPress.orgの最新版
(WordPress ${wp_version} で動くもの)へ更新する。

${summary}

マージ後、devのFleetが各サイトのプラグイン同期Jobで適用する。
メジャー更新を含む場合は各プラグインの変更履歴を確認し、必要なら本番データリハーサルを行う
(docs/operations-flow.md)。devで確認後、\`promote\` ワークフロー(name=all)でproductionへ昇格する。
EOF
)" || exit 1
pr_automerge_and_wait "$PR_URL"
echo "devへの反映が始まりました(各サイトのプラグイン同期Jobが数分で適用します)。"
