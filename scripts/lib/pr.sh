# scripts/ 配下のスクリプトが source して使う、PR作成〜マージ待ちの共通処理。
#
# マージの方針(docs/manual-multi-env.md「ブランチ保護」参照):
#   mainのブランチ保護は「承認数0 + Code Ownersレビュー必須」。CODEOWNERSは
#   /envs/production/ だけなので、production に触れないPR(dev・charts・images等)は
#   validate が通れば auto-merge でそのままマージされる。production に触れるPRは
#   承認待ちで止まるため、pr_automerge_and_wait は呼ばず人がレビュー・マージする。
#
# 前提: 呼び出し側で set -euo pipefail、カレントディレクトリがリポジトリルート。
#
# PIPELINE_ACTOR(Rundeckでジョブを実行した人。rundeck/generate-jobs.py が渡す)があれば、
# 作ったPRにそれを書き残す。GitHub上の作成者はパイプライン用のマシンユーザーになるため
# (docs/manual-rundeck.md「実行アカウント」)、誰が起動したかはここで追う。

# PR本文・コメントに付ける実行者の行(PIPELINE_ACTORが無ければ空)
pr_actor_line() {
  if [[ -n "${PIPELINE_ACTOR:-}" ]]; then
    echo "実行者: ${PIPELINE_ACTOR}(Rundeck、$(whoami)@$(hostname -s))"
  fi
}

# 他の仕組み(promoteワークフロー等)が作ったPRに、実行者をコメントで残す
# 引数: <pr_url>
pr_comment_actor() {
  if [[ -n "${PIPELINE_ACTOR:-}" ]]; then
    gh pr comment "$1" --body "$(pr_actor_line)" >/dev/null || echo "警告: PRへの実行者のコメントに失敗しました: $1" >&2
  fi
}

# 作業ツリー(このクローン)を排他ロックする。Rundeckの複数ジョブ(アプリの更新・
# WordPressのstagingでの確認等)が同じクローンでブランチを切り替え合わないようにするためのもの。
# 本番PRのマージ待ちのような長い待ちの間は pr_unlock_repo で手放すこと。
# 引数: [待つ秒数(既定3600)]
pr_lock_repo() {
  local wait="${1:-3600}" lockfile
  lockfile="$(git rev-parse --git-dir)/ibid-pipeline.lock"
  exec 9>"$lockfile"
  if ! flock -n 9; then
    echo "このクローンは他のジョブが使用中です。空くのを待っています(最大${wait}秒)..." >&2
    flock -w "$wait" 9 || { echo "エラー: ${wait}秒待ってもロックが空きませんでした: ${lockfile}" >&2; exit 1; }
  fi
}

pr_unlock_repo() {
  flock -u 9 2>/dev/null || true
}

# 人がPRをマージするのを待つ(このスクリプトはマージしない。productionに触れるPR用)。
# マージされたらマージコミットのSHAを MERGE_SHA に入れる。closeされた・時間切れはエラー終了。
# 引数: <pr_url> <待つ分数>
pr_wait_human_merge() {
  local pr_url="$1" minutes="$2" state i
  echo "PRのレビュー・マージを待っています(最大${minutes}分。マージは人が行う): ${pr_url}"
  for ((i = 0; i < minutes * 2; i++)); do
    state="$(gh pr view "$pr_url" --json state -q .state)"
    case "$state" in
      MERGED)
        MERGE_SHA="$(gh pr view "$pr_url" --json mergeCommit -q .mergeCommit.oid)"
        echo "マージされました: ${MERGE_SHA}"
        return 0
        ;;
      CLOSED) echo "エラー: PRがマージされずにcloseされました: ${pr_url}" >&2; exit 1 ;;
    esac
    (( i % 20 == 19 )) && echo "  まだマージされていません($(( (i + 1) / 2 ))分経過)"
    sleep 30
  done
  echo "エラー: ${minutes}分待ってもマージされませんでした。マージ後に確認だけ行う場合は check のジョブを使ってください: ${pr_url}" >&2
  exit 1
}

# 作業ツリーがクリーンかを確認する。
pr_ensure_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "エラー: 作業ツリーに未コミットの変更があります。先にcommit/stashしてください。" >&2
    git status --short >&2
    exit 1
  fi
}

# mainブランチ上で、origin/mainと同期していることを確認する。
pr_require_main_uptodate() {
  if [[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]]; then
    echo "エラー: mainブランチで実行してください(現在: $(git rev-parse --abbrev-ref HEAD))。" >&2
    exit 1
  fi
  git fetch origin main >/dev/null
  if [[ "$(git rev-parse main)" != "$(git rev-parse origin/main)" ]]; then
    echo "エラー: ローカルのmainがorigin/mainと同期していません。git pullしてください。" >&2
    exit 1
  fi
}

# git add済みの内容をコミットしてpushし、PRを作成してCIチェックを待つ。
# 作成したPRのURLを PR_URL に入れる。終了後はmainに戻る(ブランチは残る)。
# 引数: <title> <body>
pr_commit_push_create() {
  local title="$1" body="$2" actor
  actor="$(pr_actor_line)"
  [[ -n "$actor" ]] && body="${body}"$'\n\n'"${actor}"
  git commit -m "$title"
  git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
  PR_URL="$(gh pr create --title "$title" --body "$body")"
  git checkout main
  echo "PR作成: $PR_URL"
  echo "CIチェックを待っています(gh pr checks --watch)..."

  # gh pr checks --watchはPR作成直後、workflowがまだ1件も登録されていない
  # (GitHub Actions側の登録がPR作成に対してわずかに遅れる)場合、待たずに
  # 「no checks reported」で即座に失敗する。この場合だけ数秒待って再試行する
  # (実際にチェックが失敗した場合は再試行せずそのまま結果を表示する)。
  local checks_output attempt=0
  while true; do
    attempt=$((attempt + 1))
    if checks_output="$(gh pr checks "$PR_URL" --watch 2>&1)"; then
      echo "$checks_output"
      echo "チェック成功: $PR_URL"
      return 0
    fi
    echo "$checks_output"
    if [[ "$checks_output" == *"no checks reported"* && $attempt -lt 6 ]]; then
      echo "CIチェックがまだ登録されていないようです。10秒待って再試行します...(${attempt}/6)"
      sleep 10
      continue
    fi
    echo "警告: CIチェックが失敗、またはタイムアウトしました。内容を確認してください: $PR_URL" >&2
    return 1
  done
}

# PRをauto-merge(squash)し、マージされるまで待つ。マージ後はmainをpullし、
# 作業ブランチを(ローカル・リモートとも名前指定で)削除する。
# マージコミットのSHAを MERGE_SHA に入れる。
# production(CODEOWNERS対象)に触れるPRには使わないこと(承認待ちで止まるため)。
# 引数: <pr_url>
pr_automerge_and_wait() {
  local pr_url="$1" branch state i
  branch="$(gh pr view "$pr_url" --json headRefName -q .headRefName)"
  gh pr merge "$pr_url" --auto --squash
  echo "auto-mergeを設定しました。マージを待っています..."
  for ((i = 0; i < 90; i++)); do
    state="$(gh pr view "$pr_url" --json state -q .state)"
    case "$state" in
      MERGED) break ;;
      CLOSED) echo "エラー: PRがマージされずにcloseされました: $pr_url" >&2; exit 1 ;;
    esac
    sleep 10
  done
  if [[ "$state" != "MERGED" ]]; then
    echo "エラー: 15分待ってもマージされませんでした(承認待ち・チェック失敗等を確認してください): $pr_url" >&2
    exit 1
  fi
  MERGE_SHA="$(gh pr view "$pr_url" --json mergeCommit -q .mergeCommit.oid)"
  echo "マージされました: ${MERGE_SHA}"
  git checkout main
  git pull --ff-only origin main
  git branch -D "$branch" 2>/dev/null || true
  git push origin --delete "$branch" 2>/dev/null || true
}

# 指定コミットで起動したワークフロー実行の完了を待ち、失敗ならエラー終了する。
# 引数: <workflowファイル名> <commit sha>
pr_wait_workflow() {
  local workflow="$1" sha="$2" run_id="" i
  echo "${workflow} の実行(${sha:0:7})を待っています..."
  for ((i = 0; i < 30; i++)); do
    run_id="$(gh run list --workflow="$workflow" --commit "$sha" --limit 1 --json databaseId -q '.[0].databaseId // empty')"
    [[ -n "$run_id" ]] && break
    sleep 10
  done
  if [[ -z "$run_id" ]]; then
    echo "エラー: ${workflow} が ${sha:0:7} で起動していません(pathsフィルタ等を確認してください)。" >&2
    exit 1
  fi
  if ! gh run watch "$run_id" --exit-status >/dev/null; then
    echo "エラー: ${workflow} が失敗しました: gh run view ${run_id} --log-failed" >&2
    exit 1
  fi
  echo "${workflow} が成功しました(run ${run_id})。"
}
