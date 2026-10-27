# stagingのQA結果をGitHubのcommit statusに記録する(scripts/qa.sh・scripts/vuln-scan.sh から source する)。
# 本番への昇格PRの qa-gate(.github/workflows/qa-gate.yaml)がこの記録を見る。
# 説明: docs/operations-flow.md「QAゲート」

# 記録先: envs/staging/<kind>/<name> を最後に変更したmainのコミット。QAしたのがmainのどの内容かを、
# 本番PRのqa-gateがこのコミットで突き合わせる。手元の内容(反映の確認に使ったもの)がorigin/mainと
# 違えば記録しない(空を返す)。他のディレクトリだけが進んでいるのは構わない
status_commit() {
  local kind="$1" n="$2" path="envs/staging/$1/$2"
  git fetch -q origin main || { echo "警告: git fetchに失敗したため、結果をGitHubに記録しません。" >&2; return 0; }
  if [[ -n "$(git status --porcelain -- "$path")" ]] \
    || [[ "$(git rev-parse "HEAD:$path" 2>/dev/null)" != "$(git rev-parse "origin/main:$path" 2>/dev/null)" ]]; then
    echo "警告: 手元の ${path} がorigin/mainと違うため、結果をGitHubに記録しません(git pull してやり直してください)。" >&2
    return 0
  fi
  git log -1 --format=%H origin/main -- "$path"
}

# post_status <context(qa・vuln)> <kind> <name> <state> <説明>
post_status() {
  local ctx="$1/$2/$3" kind="$2" n="$3" state="$4" desc="$5" commit
  commit="$(status_commit "$kind" "$n")"
  [[ -n "$commit" ]] || return 0
  local -a args=(-f state="$state" -f context="$ctx" -f description="${desc:0:140}")
  [[ -n "${RUNDECK_EXEC_URL:-}" && "${RUNDECK_EXEC_URL}" == http* ]] && args+=(-f target_url="$RUNDECK_EXEC_URL")
  if gh api -X POST "repos/{owner}/{repo}/statuses/$commit" "${args[@]}" >/dev/null; then
    echo "結果をGitHubに記録しました: $ctx = ${state}(コミット ${commit:0:7})"
    [[ "$state" == success ]] && rerun_gates "$kind" "$n"
  else
    echo "警告: 結果をGitHubに記録できませんでした($ctx)。" >&2
  fi
  return 0
}

# このアプリ・サイトを本番へ昇格する開いたPRのうち、qa-gateが失敗しているものをやり直させる
rerun_gates() {
  local kind="$1" n="$2" pr sha run
  while read -r pr sha; do
    [[ -n "$pr" ]] || continue
    run="$(gh run list --workflow=qa-gate.yaml --commit "$sha" --limit 1 --json databaseId,status,conclusion \
      -q '.[] | select(.status == "completed" and .conclusion != "success") | .databaseId' 2>/dev/null || true)"
    if [[ -n "$run" ]]; then
      gh run rerun "$run" >/dev/null 2>&1 && echo "PR #${pr} のqa-gateをやり直します(run ${run})。" \
        || echo "警告: PR #${pr} のqa-gateをやり直せませんでした。GitHubのPR画面から再実行してください。" >&2
    fi
  done < <(gh pr list --state open --base main --limit 50 --json number,headRefOid,files \
    -q ".[] | select(any(.files[]; .path | startswith(\"envs/production/$kind/$n/\"))) | \"\(.number) \(.headRefOid)\"" 2>/dev/null || true)
}
