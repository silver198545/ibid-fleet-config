#!/usr/bin/env bash
# アプリ・WordPressサイトのQA(docs/operations-flow.md「QAゲート」)。
# 反映の確認(Gitに書いた版が動いているか)と、qa/checks.yaml のチェック(L1: HTTPの応答、L2: 中身)を行う。
#
# 使い方: scripts/qa.sh <env> <apps|sites> <name...|all>
#   例: scripts/qa.sh staging apps brc-advanced-search
#       scripts/qa.sh staging sites abc abc-en
#
# env=staging のときは、結果をGitHubのcommit status(context: qa/<kind>/<name>)として、
# envs/staging/<kind>/<name> を最後に変更したmainのコミットに記録する。本番への昇格PRでは
# qa-gate ワークフロー(.github/workflows/qa-gate.yaml)が、昇格する内容と同じ内容のstagingが
# QAに通っているかをこの記録で確かめる。記録が通ったら、失敗していた本番PRのqa-gateをやり直させる。
# サイトは本番の同じサイトとも比べる(タイトル等。本番にまだ無いサイトは比べない)。
#
# 環境変数:
#   QA_NO_STATUS=1      stagingでも結果をGitHubに記録しない(試しに流すとき)
#   QA_APPLY_WAIT=<秒>  Gitの版がまだ動いていないとき、反映を待つ時間(既定300)
#
# 前提: gh CLIが認証済み(記録するとき)、kubectlのコンテキスト dev1/staging1/prod1、python3とPyYAML。
# mainを最新にしてから実行すること(記録先のコミットをorigin/mainから決めるため)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

QA_APPLY_WAIT="${QA_APPLY_WAIT:-300}"

die() { echo "エラー: $*" >&2; exit 1; }
usage() { die "使い方: $0 <dev|staging|production> <apps|sites> <name...|all>"; }

[[ $# -ge 3 ]] || usage
ENV="$1"
KIND="$2"
shift 2
case "$ENV" in
  dev) CTX=dev1 ;;
  staging) CTX=staging1 ;;
  production) CTX=prod1 ;;
  *) usage ;;
esac
[[ "$KIND" == apps || "$KIND" == sites ]] || usage

NAMES=()
if [[ "$*" == "all" ]]; then
  for d in "envs/$ENV/$KIND/"*/; do
    [[ -d "$d" ]] && NAMES+=("$(basename "$d")")
  done
  [[ ${#NAMES[@]} -gt 0 ]] || die "envs/$ENV/$KIND/ に対象がありません。"
else
  for n in "$@"; do
    [[ "$n" =~ ^[a-z0-9-]+$ ]] || die "名前は英小文字・数字・ハイフンのみ: $n"
    [[ -d "envs/$ENV/$KIND/$n" ]] || die "envs/$ENV/$KIND/$n がありません。"
    NAMES+=("$n")
  done
fi

kc() { kubectl --context "$CTX" "$@"; }

# サイトのURL(Ingressの内部名 + sitePath)。scripts/wordpress-pipeline.sh の site_url と同じ
site_url() {
  local env="$1" site="$2" f prefix path
  f="envs/$env/sites/$site/fleet.yaml"
  prefix="$(grep -oP '^\s*hostname: \K[a-z0-9-]+' "$f" | head -1)"
  path="$(grep -oP '^    sitePath: \K\S+' "$f" | head -1 || true)"
  echo "https://${prefix}.${env}.ibid.lan${path}/"
}

# Gitに書いた版(アプリはイメージ、サイトはチャートの版)と、動いている版。読めなければ空
expected_version() {
  local dir="envs/$ENV/$KIND/$1" f="envs/$ENV/$KIND/$1/deployment.yaml"
  if [[ "$KIND" == apps ]]; then
    # 環境でイメージを変えているアプリ(本番のmetadatabase-v2)はパッチ側を優先する
    if [[ -f "$dir/overlays/$ENV/deployment_patch.yaml" ]] && grep -q 'image:' "$dir/overlays/$ENV/deployment_patch.yaml"; then
      f="$dir/overlays/$ENV/deployment_patch.yaml"
    fi
    grep -oP '^\s*image: \K\S+' "$f" | head -1
  else
    grep -oP '^  version: "?\K[^"\s]+' "$dir/fleet.yaml" | head -1
  fi
}

deployed_version() {
  local n="$1" secret
  if [[ "$KIND" == apps ]]; then
    kc -n "$n" get deploy "$n" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
  else
    # Helmの履歴(Secret)からラッパーチャートの版を読む(本番がRead-onlyのオペレータは読めない)
    secret="$(kc -n "wordpress-$n" get secret -l "owner=helm,name=wordpress-$n,status=deployed" -o name 2>/dev/null | tail -1 || true)"
    [[ -n "$secret" ]] || return 0
    kc -n "wordpress-$n" get "$secret" -o jsonpath='{.data.release}' 2>/dev/null \
      | base64 -d | base64 -d | gzip -dc | python3 -c 'import json,sys; print(json.load(sys.stdin)["chart"]["metadata"]["version"])' 2>/dev/null || true
  fi
}

# Gitの版が動いているか(反映待ちなら QA_APPLY_WAIT まで待つ)と、rolloutが終わっているか
check_applied() {
  local n="$1" want got="" ns waited=0
  want="$(expected_version "$n")"
  [[ -n "$want" ]] || { echo "NG  Gitの版を読めません(envs/$ENV/$KIND/$n)"; return 1; }
  while :; do
    got="$(deployed_version "$n")"
    [[ "$got" == "$want" ]] && break
    if [[ -z "$got" && "$KIND" == sites ]] && ! kc auth can-i get secrets -n "wordpress-$n" >/dev/null 2>&1; then
      echo "--  動いているチャートの版は権限が無く読めないため、rolloutだけ確かめます(Git: ${want})"
      break
    fi
    if (( waited >= QA_APPLY_WAIT )); then
      echo "NG  Gitの版がまだ動いていません(Git: ${want} / 動いている: ${got:-不明})。Fleetの適用状況を確認してください"
      return 1
    fi
    (( waited == 0 )) && echo "    Gitの版(${want})の反映を待っています(最大${QA_APPLY_WAIT}秒。動いている: ${got:-不明})..."
    sleep 15
    waited=$((waited + 15))
  done
  if [[ "$KIND" == apps ]]; then
    ns="$n"
    kc -n "$ns" rollout status "deploy/$n" --timeout=10m >/dev/null || { echo "NG  rolloutが終わりません(deploy/$n)"; return 1; }
  else
    ns="wordpress-$n"
    kc -n "$ns" rollout status "statefulset/wordpress-$n-mariadb" --timeout=10m >/dev/null \
      && kc -n "$ns" rollout status "deploy/wordpress-$n" --timeout=10m >/dev/null \
      || { echo "NG  rolloutが終わりません(${ns})"; return 1; }
  fi
  [[ "$got" == "$want" ]] && echo "OK  反映済み: ${want}"
  return 0
}

# 記録先: envs/staging/<kind>/<name> を最後に変更したmainのコミット。QAしたのがmainのどの内容かを、
# 本番PRのqa-gateがこのコミットで突き合わせる。手元の内容(反映の確認に使ったもの)がorigin/mainと
# 違えば記録しない(空を返す)。他のディレクトリだけが進んでいるのは構わない
status_commit() {
  local n="$1" path="envs/staging/$KIND/$1"
  git fetch -q origin main || { echo "警告: git fetchに失敗したため、結果をGitHubに記録しません。" >&2; return 0; }
  if [[ -n "$(git status --porcelain -- "$path")" ]] \
    || [[ "$(git rev-parse "HEAD:$path" 2>/dev/null)" != "$(git rev-parse "origin/main:$path" 2>/dev/null)" ]]; then
    echo "警告: 手元の ${path} がorigin/mainと違うため、結果をGitHubに記録しません(git pull してやり直してください)。" >&2
    return 0
  fi
  git log -1 --format=%H origin/main -- "$path"
}

post_status() {
  local n="$1" state="$2" desc="$3" commit
  commit="$(status_commit "$n")"
  [[ -n "$commit" ]] || return 0
  local -a args=(-f state="$state" -f context="qa/$KIND/$n" -f description="${desc:0:140}")
  [[ -n "${RUNDECK_EXEC_URL:-}" && "${RUNDECK_EXEC_URL}" == http* ]] && args+=(-f target_url="$RUNDECK_EXEC_URL")
  if gh api -X POST "repos/{owner}/{repo}/statuses/$commit" "${args[@]}" >/dev/null; then
    echo "結果をGitHubに記録しました: qa/$KIND/$n = ${state}(コミット ${commit:0:7})"
    [[ "$state" == success ]] && rerun_gates "$n"
  else
    echo "警告: 結果をGitHubに記録できませんでした(qa/$KIND/$n)。" >&2
  fi
  return 0
}

# このアプリ・サイトを本番へ昇格する開いたPRのうち、qa-gateが失敗しているものをやり直させる
rerun_gates() {
  local n="$1" pr sha run
  while read -r pr sha; do
    [[ -n "$pr" ]] || continue
    run="$(gh run list --workflow=qa-gate.yaml --commit "$sha" --limit 1 --json databaseId,status,conclusion \
      -q '.[] | select(.status == "completed" and .conclusion != "success") | .databaseId' 2>/dev/null || true)"
    if [[ -n "$run" ]]; then
      gh run rerun "$run" >/dev/null 2>&1 && echo "PR #${pr} のqa-gateをやり直します(run ${run})。" \
        || echo "警告: PR #${pr} のqa-gateをやり直せませんでした。GitHubのPR画面から再実行してください。" >&2
    fi
  done < <(gh pr list --state open --base main --limit 50 --json number,headRefOid,files \
    -q ".[] | select(any(.files[]; .path | startswith(\"envs/production/$KIND/$n/\"))) | \"\(.number) \(.headRefOid)\"" 2>/dev/null || true)
}

failed=()
for n in "${NAMES[@]}"; do
  echo ""
  echo "=== QA: ${ENV} ${KIND}/${n} ==="
  ok=1
  check_applied "$n" || ok=0

  if [[ "$KIND" == apps ]]; then
    base="https://${n}.${ENV}.ibid.lan"
    prod=""
    [[ "$ENV" != production && -d "envs/production/apps/$n" ]] && prod="https://${n}.production.ibid.lan"
  else
    base="$(site_url "$ENV" "$n")"
    prod=""
    [[ "$ENV" != production && -d "envs/production/sites/$n" ]] && prod="$(site_url production "$n")"
  fi
  out="$(python3 -I "$SCRIPT_DIR/lib/qa_http.py" qa/checks.yaml "$KIND" "$n" "$base" ${prod:+--production "$prod"} 2>&1)" || ok=0
  grep -v '^QA_RESULT ' <<<"$out" || true
  read -r _ passed total < <(grep '^QA_RESULT ' <<<"$out" || echo "QA_RESULT 0 0")

  actor="${PIPELINE_ACTOR:-$(whoami)}"
  if [[ $ok -eq 1 ]]; then
    echo "結果: OK(チェック ${passed}/${total})"
    desc="OK: 反映確認とチェック${passed}/${total}件(${actor})"
  else
    echo "結果: NG(チェック ${passed}/${total})"
    desc="NG: チェック${passed}/${total}件、または未反映(${actor})"
    failed+=("$n")
  fi
  if [[ "$ENV" == staging && "${QA_NO_STATUS:-0}" != 1 ]]; then
    post_status "$n" "$([[ $ok -eq 1 ]] && echo success || echo failure)" "$desc"
  fi
done

echo ""
if [[ ${#failed[@]} -gt 0 ]]; then
  die "QAに通らなかったもの: ${failed[*]}(上の NG の行を確認してください)"
fi
echo "QAはすべて通りました(${ENV}: ${NAMES[*]})。"
