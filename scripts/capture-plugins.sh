#!/usr/bin/env bash
# devのサイトに今入っているプラグイン(版・有効/無効)を、Gitの envs/dev/sites/<site>/fleet.yaml に取り込むPRを
# 作ってマージする。
#
# 運用(2026-11-09〜): サイトの管理者(wpadmins)がdevの管理画面でプラグインを更新・追加して動作を確かめ、
# このスクリプト(Rundeckの 0-dev-plugin-capture)でその版をGitに取り込む。取り込んだ構成は従来どおり
# staging → 本番へ昇格する(チャートのプラグイン同期Jobが各環境に同じ版を入れる)。
# 取り込むまでの間に同期Jobが動いても、入っている版の方が新しければ戻さない(チャート0.7.7〜)。
#
# - devの管理画面で追加したプラグインは追加、更新したものは版を変え、削除したものは一覧から消す
#   (一覧から消しても、他の環境のプラグインは同期Jobでは消えない。本番では手で削除する。
#   docs/runbook/wordpress-update.md「プラグインを追加・削除する」)
# - 無効のプラグインは activate: false で取り込む(同期Jobが勝手に有効化しないように)
# - WordPress.orgに無いプラグイン・版は取り込まない(同期Jobが入れられないため。警告を出す)
# PRはdevだけに触れるので、validate通過後にauto-mergeする。
#
# 使い方(mainブランチ・origin/mainと同期した状態で実行。kubectlのコンテキスト dev1 が要る):
#   scripts/capture-plugins.sh web web-en       # サイトを指定
#   scripts/capture-plugins.sh all              # devの全サイト
#   scripts/capture-plugins.sh --dry-run web    # 書き換えだけ行い、PRは作らない(差分は git diff で見る)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/pr.sh
source "$SCRIPT_DIR/lib/pr.sh"

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
    [[ " ${sites[*]:-} " == *" $s "* ]] || sites+=("$s")
  done
fi

for cmd in git gh python3 kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "エラー: '$cmd' が見つかりません。" >&2; exit 1; }
done

# Rundeckの他のジョブと同じクローンでブランチを切り替え合わないよう、PRを作り終えるまでロックする
$dry_run || pr_lock_repo
pr_ensure_clean_worktree
$dry_run || pr_require_main_uptodate

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

files=()
for s in "${sites[@]}"; do
  echo "devの ${s} のプラグイン一覧を取得します..."
  if ! kubectl --context dev1 -n "wordpress-$s" exec "deploy/wordpress-$s" -c wordpress -- \
      wp --path=/opt/bitnami/wordpress --skip-plugins --skip-themes plugin list --format=json --fields=name,version,status \
      >"$WORK/$s.json" 2>"$WORK/$s.err"; then
    echo "エラー: devの ${s} のプラグイン一覧を取得できません(Podの状態・execの権限を確認): $(head -c 300 "$WORK/$s.err")" >&2
    exit 1
  fi
  files+=("envs/dev/sites/$s/fleet.yaml")
done

summary="$(python3 "$SCRIPT_DIR/lib/plugin_pins.py" capture --inventory-dir "$WORK" "${files[@]}")"
if [[ -z "$summary" ]]; then
  echo "Gitとdevのプラグインは一致しています(取り込むものはありません)。"
  exit 0
fi
echo "取り込む内容:"
echo "$summary"
if $dry_run; then
  echo "(--dry-run のためPRは作りません。元に戻す: git checkout -- ${files[*]})"
  exit 0
fi

# PRのタイトル・ブランチ名に入れる対象(全サイトや多数なら件数で書く)
changed=()
for f in "${files[@]}"; do
  git diff --quiet -- "$f" || changed+=("$(basename "$(dirname "$f")")")
done
if [[ ${#changed[@]} -le 3 ]]; then
  target="$(printf '%s・' "${changed[@]}")" label="$(IFS=-; echo "${changed[*]}")"
  target="devの${target%・}"
else
  target="devの${#changed[@]}サイト" label="${#changed[@]}sites"
fi
branch="plugins/capture-${label}-$(date +%Y%m%d%H%M%S)"
git checkout -b "$branch"
git add "${files[@]}"
pr_commit_push_create "chore: ${target}のプラグインの版をdevの状態に合わせて固定" "$(cat <<EOF
## 内容
\`scripts/capture-plugins.sh\` で作成。devの管理画面で更新・追加・削除したプラグインを、Gitの
\`envs/dev/sites/<site>/fleet.yaml\` の \`plugins:\` に取り込む(devのPodの \`wp plugin list\` の版・有効/無効)。

${summary}

devには既にこの版が入っているので、マージしてもdevは変わらない(プラグイン同期Jobは同じ版なら何もしない)。
devで確認済みのものを、サイトごとにstagingを通してproductionへ昇格する(docs/runbook/wordpress-update.md)。
「削除」があるときは、一覧から消しても他の環境のプラグインは消えないので、本番では手で削除する。
EOF
)" || exit 1
pr_unlock_repo
pr_automerge_and_wait "$PR_URL"
echo "Gitに取り込みました。staging → 本番への昇格は 2-staging → 3-production-promote で行います。"
