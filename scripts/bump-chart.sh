#!/usr/bin/env bash
# ラッパーチャート(charts/ibid-wordpress)の変更を、devの全サイトへの反映まで1コマンドで行う。
#
# 以前の手順(チャート変更PR→マージ→公開待ち→devサイトのhelm.versionを上げるPR→マージ)を
# まとめたもの。中で行うこと:
#   1. Chart.yaml の version を上げ(デフォルトはパッチ+1)、作業ツリーのチャート変更と
#      一緒にPR作成 → validate通過後に auto-merge → release-chart.yaml の公開完了を待つ
#   2. envs/dev/sites/*/fleet.yaml の helm.version を新バージョンにするPR作成 → auto-merge
#      (チャートの公開を待ってから参照を切り替えるので、Fleetが未公開のバージョンを
#      取りに行って失敗することはない)
# productionへは触らない。devで確認後、通常どおり promote ワークフロー(site=all)で昇格する
# (docs/operations-flow.md「基本サイクル」)。
#
# 使い方(mainブランチ・origin/mainと同期した状態で実行):
#   # WordPressコア/MariaDBを最新のBitnamiイメージへ(values.yamlのdigestを自動更新)
#   scripts/bump-chart.sh --update-images "feat: WordPress/MariaDBイメージを最新のdigestへ更新"
#
#   # values.yaml やテンプレートを手で編集した後(未コミットのまま実行する)
#   scripts/bump-chart.sh "fix: ○○を修正"
#
#   オプション:
#     --update-images   docker.io/bitnami/{wordpress,mariadb}:latest の現在のdigestを取得し
#                       values.yaml に書き込む(既に最新なら何もしない)
#     --minor           バージョンをマイナー+1(x.Y.0)にする。デフォルトはパッチ+1
#     --version <ver>   バージョンを明示指定する
#   タイトルは「種類: 日本語の説明」形式(CLAUDE.mdのコミット規約)。末尾に(チャート<ver>)が付く。
#
# 途中で止まった場合(公開失敗など)は、原因を直してから dev サイトの helm.version 更新だけを
# 手で行うか、新しいバージョンでやり直すこと(公開済みのバージョン番号は再利用しない)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/pr.sh
source "$SCRIPT_DIR/lib/pr.sh"

CHART_DIR="charts/ibid-wordpress"
CHART_YAML="${CHART_DIR}/Chart.yaml"
VALUES_YAML="${CHART_DIR}/values.yaml"

usage() {
  echo "使い方: $0 [--update-images] [--minor | --version <ver>] \"<種類>: <説明>\"" >&2
  echo "詳細はスクリプト冒頭のコメントを参照してください。" >&2
  exit 1
}

update_images=false bump=patch new_version="" title=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update-images) update_images=true ;;
    --minor) bump=minor ;;
    --version) shift; new_version="${1:-}"; [[ -n "$new_version" ]] || usage ;;
    -h|--help) usage ;;
    -*) echo "エラー: 不明なオプション: $1" >&2; usage ;;
    *) [[ -z "$title" ]] || usage; title="$1" ;;
  esac
  shift
done
[[ -n "$title" ]] || usage
if [[ ! "$title" =~ ^(feat|fix|perf|refactor|docs|style|test|chore):\ .+ ]]; then
  echo "エラー: タイトルは「種類: 説明」形式にしてください(種類: feat/fix/perf/refactor/docs/style/test/chore)。" >&2
  exit 1
fi

for cmd in git gh curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "エラー: '$cmd' が見つかりません。" >&2; exit 1; }
done

# 作業ツリーの変更はチャート配下だけであること(他の変更を巻き込まない)。
if [[ -n "$(git status --porcelain -- . ":(exclude)${CHART_DIR}")" ]]; then
  echo "エラー: ${CHART_DIR}/ 以外に未コミットの変更があります。先にcommit/stashしてください。" >&2
  git status --short -- . ":(exclude)${CHART_DIR}" >&2
  exit 1
fi
pr_require_main_uptodate

# Docker Hub の <repo>:latest の現在のdigest(マルチアーキのindex)を返す。
# HEADリクエストはDocker Hubのpull回数制限にカウントされない。
latest_digest() {
  local repo="$1" token
  token="$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | jq -r .token)"
  curl -fsSI \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://registry-1.docker.io/v2/${repo}/manifests/latest" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}'
}

if $update_images; then
  for repo in bitnami/wordpress bitnami/mariadb; do
    digest="$(latest_digest "$repo")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "エラー: ${repo} のdigest取得に失敗しました: ${digest}" >&2; exit 1; }
    current="$(sed -n "\#repository: ${repo}\$#,/digest:/ s/.*digest: //p" "$VALUES_YAML")"
    if [[ "$current" == "$digest" ]]; then
      echo "${repo}: 既に最新です(${digest})"
    else
      sed -i "\#repository: ${repo}\$#,/digest:/ s/digest: sha256:[0-9a-f]*/digest: ${digest}/" "$VALUES_YAML"
      echo "${repo}: ${current} → ${digest}"
    fi
  done
fi

if [[ -z "$(git status --porcelain -- "$CHART_DIR")" ]]; then
  echo "${CHART_DIR}/ に変更がありません。何もせず終了します。"
  exit 0
fi

old_version="$(awk '/^version:/ {print $2; exit}' "$CHART_YAML")"
if [[ -z "$new_version" ]]; then
  IFS=. read -r major minor patch <<< "$old_version"
  case "$bump" in
    patch) new_version="${major}.${minor}.$((patch + 1))" ;;
    minor) new_version="${major}.$((minor + 1)).0" ;;
  esac
fi
if [[ ! "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "エラー: バージョンは x.y.z 形式にしてください: ${new_version}" >&2
  exit 1
fi
echo "チャートバージョン: ${old_version} → ${new_version}"

# --- 1. チャート変更のPR → auto-merge → GHCRへの公開を待つ ---
chart_branch="chart/ibid-wordpress-${new_version}"
git checkout -b "$chart_branch"
sed -i "s/^version: .*/version: ${new_version}/" "$CHART_YAML"
git add "$CHART_DIR"
echo "チャートの変更:"
git diff --cached --stat

pr_commit_push_create "${title}(チャート${new_version})" "$(cat <<EOF
## 内容
\`scripts/bump-chart.sh\` で作成。チャート \`ibid-wordpress\` を ${old_version} → ${new_version} に更新。

マージ後 \`release-chart.yaml\` がGHCRへ公開し、続けて同スクリプトがdevの全サイトの
\`helm.version\` を ${new_version} に上げるPRを作成します。
EOF
)" || exit 1
pr_automerge_and_wait "$PR_URL"
pr_wait_workflow release-chart.yaml "$MERGE_SHA"

# --- 2. devの全サイトの helm.version を上げるPR → auto-merge ---
sites_branch="chart/dev-sites-${new_version}"
git checkout -b "$sites_branch"
# サイトのfleet.yamlでインデント2の version: は helm.version だけ(プラグインの version はより深い)。
sed -i -E "s/^  version: \"[^\"]*\"$/  version: \"${new_version}\"/" envs/dev/sites/*/fleet.yaml
git add envs/dev/sites
if git diff --cached --quiet; then
  echo "devのサイトは既に ${new_version} です。"
  git checkout main
  git branch -D "$sites_branch"
  exit 0
fi
echo "更新したサイト:"
git diff --cached --stat

pr_commit_push_create "chore: devの全サイトをibid-wordpress ${new_version}へ更新" "$(cat <<EOF
## 内容
\`scripts/bump-chart.sh\` で作成。devの全サイトの \`helm.version\` を ${new_version} に更新
(チャートは公開済み)。

devで確認後、\`promote\` ワークフロー(site=all)でproductionへ昇格する。
EOF
)" || exit 1
pr_automerge_and_wait "$PR_URL"

cat <<EOF

devへの反映が始まりました(Fleetが数分で適用します)。確認:
  kubectl --context dev1 get pods -A -l app.kubernetes.io/instance --field-selector=status.phase!=Running,status.phase!=Succeeded
  各サイトの表示・管理画面(https://<site>.dev.ibid.lan/)
DBを書き換え得る変更(コア・プラグインのメジャー更新、MariaDB更新)なら本番データリハーサルを行う
(docs/operations-flow.md「本番データリハーサル」)。問題なければ本番バックアップを取り、
  gh workflow run promote.yaml -f site=all
で昇格PRを作成してレビュー・マージする。
EOF
