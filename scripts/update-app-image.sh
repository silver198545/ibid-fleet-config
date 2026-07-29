#!/usr/bin/env bash
# apps/配下の自作アプリ(brc-advanced-search, riken-diips等)のイメージ更新〜
# dev→staging→production昇格を補助するスクリプト(docs/manual-apps.md の手順をなぞる)。
#
# 昇格は promote.yaml の対象外(sites/専用)のため、PR作成はこのスクリプトが行う。
# 以下は意図的に自動化していない:
#   - SealedSecret(GHCR pull用)の再作成: kubeseal実行にPAT等の秘密情報と対象クラスタへの
#     kubectlアクセスが要るため、コマンド例を表示して人手に委ねる。
#   - 全PRのマージ: mainのブランチ保護は`allow_auto_merge: false`かつ
#     required_approving_review_count: 1(CODEOWNERSレビュー必須)で、dev/staging/production
#     問わず全PRに適用される(ソロ運用のため自己承認者がいない)。このスクリプトは
#     `gh pr merge --auto`もブランチ保護をバイパスする`--admin`も使わない
#     (前者はリポジトリ側の設定が無効、後者は意図的な安全ゲートのバイパスになるため)。
#     PR作成・CIチェック待ちまでを行い、マージは常に手動(GitHub UIまたは
#     `gh pr merge --squash --admin`)に委ねる。
#
# 各ステージは独立したサブコマンドで、前段の結果(マージ完了・pod Ready・
# WEBアクセス200等)を確認してから次を手動で実行する運用を想定している。
#
# サブコマンド:
#   latest-src-ref <app>               取り込み元リポジトリ(upstream_repo_for/upstream_branch_for
#                                       で登録済みのブランチ)のHEADコミットSHAとメッセージを表示する。
#                                       set-imageのsrc_refに使う値を手打ちしないためのもの。
#   set-image <app> <tag> <src_ref>    images/<app>/{TAG,SRC_REF}を更新しPR作成、CI完了を待つ。
#                                       マージ後 build-<app>-image.yaml が自動発火する。
#   deploy-dev <app>                   build-<app>-image.yamlの最新実行が成功していることを確認した上で、
#                                       envs/dev/apps/<app>/deployment.yamlのイメージタグを
#                                       images/<app>/TAGに合わせて更新しPR作成。
#   check-dev <app>                    devのrollout状況とWEBアクセス(readinessProbeのpathで200か)を確認。
#   promote-staging <app>              【初回昇格専用】envs/dev/apps/<app> を envs/staging/apps/<app> へ
#                                       新規コピーしホスト名を書き換える(ブランチ作成のみ、コミットはしない)。
#                                       SealedSecret作成コマンドを表示して停止する。envs/staging/apps/<app>が
#                                       既にある場合はエラーになる(2回目以降のイメージ更新はdeploy-stagingを使うこと)。
#   promote-staging-finish <app>       promote-stagingでSealedSecretを手動作成した後に実行。
#                                       コミット・PR作成まで行う。
#   deploy-staging <app>               【2回目以降】既にstagingにある<app>のイメージタグだけを
#                                       images/<app>/TAGに合わせて更新しPR作成(deploy-devのstaging版)。
#   check-staging <app>                stagingのWEBアクセスを確認。
#   promote-production <app>           【初回昇格専用】envs/staging/apps/<app> を envs/production/apps/<app> へ
#                                       新規コピー。SealedSecret作成コマンドを表示して停止する。既にある場合は
#                                       エラーになる(2回目以降のイメージ更新はdeploy-productionを使うこと)。
#   promote-production-finish <app>    コミット・PR作成のみ。
#   deploy-production <app>            【2回目以降】既にproductionにある<app>のイメージタグだけを
#                                       images/<app>/TAGに合わせて更新しPR作成(deploy-devのproduction版)。
#   check-production <app>             productionのWEBアクセスを確認。
#   cleanup-staging <app>              本番反映確認後、staging側のGit定義を削除するPRを作成。
#                                       マージ後に実行するkubectl delete namespaceコマンドを表示する。
#
# 使い方の例(brc-advanced-searchをイメージ更新する場合):
#   scripts/update-app-image.sh latest-src-ref brc-advanced-search
#   (表示された内容を確認し、それが新TAGとして取り込みたいコミットか判断する)
#   scripts/update-app-image.sh set-image brc-advanced-search 2.0.0-r6 <新SRC_REF(コミットSHA)>
#   (PRをマージし、build-brc-advanced-search-imageの成功を確認)
#   git pull
#   scripts/update-app-image.sh deploy-dev brc-advanced-search
#   (PRをマージ)
#   git pull
#   scripts/update-app-image.sh check-dev brc-advanced-search
#   scripts/update-app-image.sh promote-staging brc-advanced-search
#   (表示されたkubesealコマンドを実行してenvs/staging/secrets/brc-advanced-search.yamlを作る)
#   scripts/update-app-image.sh promote-staging-finish brc-advanced-search
#   (PRをマージ)
#   git pull
#   scripts/update-app-image.sh check-staging brc-advanced-search
#   scripts/update-app-image.sh promote-production brc-advanced-search
#   (kubesealコマンドを実行してenvs/production/secrets/brc-advanced-search.yamlを作る)
#   scripts/update-app-image.sh promote-production-finish brc-advanced-search
#   (レビューの上、手動でPRをマージ)
#   git pull
#   scripts/update-app-image.sh check-production brc-advanced-search
#   scripts/update-app-image.sh cleanup-staging brc-advanced-search
#
# 2回目以降のイメージ更新(productionは初回昇格後も envs/production/apps/<app> が残り続けるため、
# promote-productionは使えず必ずエラーになる。stagingはcleanup-stagingで毎回消す運用のため、
# 通常はpromote-stagingで問題ないが、cleanup-staging未実施のまま次サイクルに入った場合は
# 同様にdeploy-stagingを使う):
#   scripts/update-app-image.sh set-image brc-advanced-search 2.0.0-r7 <新SRC_REF>
#   (PRをマージし、build-brc-advanced-search-imageの成功を確認)
#   git pull && scripts/update-app-image.sh deploy-dev brc-advanced-search
#   (PRをマージ) git pull && scripts/update-app-image.sh check-dev brc-advanced-search
#   scripts/update-app-image.sh promote-staging brc-advanced-search   # 既にあればdeploy-stagingを使う
#   ...(以下は初回と同様)...
#   scripts/update-app-image.sh deploy-production brc-advanced-search  # promote-productionではなくこちら
#   (PRをマージ) git pull && scripts/update-app-image.sh check-production brc-advanced-search
#
# 前提: gh CLIが認証済み、kubectl/kubesealのコンテキスト(dev1/staging1/prod1)が
# ~/.kube/config にマージ済みであること(docs/manual-tooling-setup.md参照)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

GH_OWNER="silver198545"

usage() {
  echo "使い方: $0 <subcommand> <app> [args...]" >&2
  echo "詳細はスクリプト冒頭のコメントを参照してください。" >&2
  exit 1
}

[[ $# -ge 2 ]] || usage
SUBCOMMAND="$1"
APP="$2"
shift 2

if [[ ! "$APP" =~ ^[a-z0-9-]+$ ]]; then
  echo "エラー: アプリ名は英小文字・数字・ハイフンのみ使用できます: $APP" >&2
  exit 1
fi

for cmd in git gh curl kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: '$cmd' が見つかりません。" >&2
    exit 1
  fi
done

upstream_repo_for() {
  case "$1" in
    brc-advanced-search) echo "PENQEinc/riken_brc_advanced_search" ;;
    riken-diips) echo "PENQEinc/riken-diips" ;;
    *) echo "エラー: ${1} の取り込み元リポジトリが未登録です(このスクリプトの upstream_repo_for/upstream_branch_for に追記してください)。" >&2; exit 1 ;;
  esac
}

upstream_branch_for() {
  case "$1" in
    brc-advanced-search) echo "vue3-main-riken" ;;
    riken-diips) echo "main" ;;
    *) echo "エラー: ${1} の取り込み元ブランチが未登録です。" >&2; exit 1 ;;
  esac
}

context_for_env() {
  case "$1" in
    dev) echo "dev1" ;;
    staging) echo "staging1" ;;
    production) echo "prod1" ;;
    *) echo "エラー: 不明な環境: $1" >&2; exit 1 ;;
  esac
}

hostname_for_env() {
  echo "${APP}.$1.ibid.lan"
}

ensure_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "エラー: 作業ツリーに未コミットの変更があります。先にcommit/stashしてください。" >&2
    git status --short >&2
    exit 1
  fi
}

require_main_uptodate() {
  if [[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]]; then
    echo "エラー: mainブランチで実行してください(現在: $(git rev-parse --abbrev-ref HEAD))。" >&2
    exit 1
  fi
  git fetch origin main >/dev/null
  local local_head remote_head
  local_head="$(git rev-parse main)"
  remote_head="$(git rev-parse origin/main)"
  if [[ "$local_head" != "$remote_head" ]]; then
    echo "エラー: ローカルのmainがorigin/mainと同期していません。git pullしてください。" >&2
    exit 1
  fi
}

open_branch() {
  git checkout -b "$1"
}

# 呼び出し前にgit add/git rm済みであることを前提とする。
# マージは行わない(mainのブランチ保護が全PRに承認必須のため。スクリプト冒頭コメント参照)。
commit_push_pr() {
  local title="$1" body="$2"
  git commit -m "$title"
  git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
  local pr_url
  pr_url="$(gh pr create --title "$title" --body "$body")"
  git checkout main
  echo "PR作成: $pr_url"
  echo "CIチェックを待っています(gh pr checks --watch)..."
  if gh pr checks "$pr_url" --watch; then
    echo "チェック成功。レビュー・マージしてください: $pr_url"
  else
    echo "警告: CIチェックが失敗、またはタイムアウトしました。内容を確認してください: $pr_url" >&2
  fi
}

cmd_latest_src_ref() {
  local repo branch result sha
  repo="$(upstream_repo_for "$APP")"
  branch="$(upstream_branch_for "$APP")"

  if ! result="$(gh api "repos/${repo}/commits/${branch}" --jq '[.sha, .commit.author.date, (.commit.message | split("\n")[0])] | @tsv' 2>&1)"; then
    echo "エラー: ${repo}(${branch})の最新コミット取得に失敗しました。" >&2
    echo "$result" >&2
    echo "ghが${repo}への読み取り権限を持つアカウントで認証されているか確認してください(gh auth status)。" >&2
    exit 1
  fi

  IFS=$'\t' read -r sha date message <<< "$result"
  echo "リポジトリ: ${repo} (${branch}ブランチ)" >&2
  echo "コミット日時: ${date}" >&2
  echo "コミットメッセージ: ${message}" >&2
  echo "SRC_REF: ${sha}" >&2
  echo "" >&2
  echo "内容を確認した上で、以下のように使ってください:" >&2
  echo "  scripts/update-app-image.sh set-image ${APP} <新TAG> ${sha}" >&2
  echo "" >&2
  # 標準出力にはSHAのみを出す(他コマンドへの $(...) 渡しを想定)
  echo "$sha"
}

cmd_set_image() {
  local tag="${1:-}" src_ref="${2:-}"
  [[ -n "$tag" && -n "$src_ref" ]] || { echo "使い方: $0 set-image <app> <tag> <src_ref>" >&2; exit 1; }
  if [[ ! "$src_ref" =~ ^[0-9a-f]{7,40}$ ]]; then
    echo "エラー: src_refはコミットSHA(16進数7〜40文字)を指定してください: ${src_ref}" >&2
    echo "(バージョン文字列やブランチ名ではなく、取り込み元リポジトリの実際のコミットSHAを指定すること)" >&2
    exit 1
  fi
  local img_dir="images/${APP}"
  [[ -f "$img_dir/TAG" && -f "$img_dir/SRC_REF" ]] || {
    echo "エラー: ${img_dir} にTAG/SRC_REFがありません(対応アプリか確認してください)。" >&2
    exit 1
  }

  ensure_clean_worktree
  require_main_uptodate

  open_branch "update-image/${APP}-${tag}"
  printf '%s' "$tag" > "$img_dir/TAG"
  printf '%s' "$src_ref" > "$img_dir/SRC_REF"
  git add "$img_dir/TAG" "$img_dir/SRC_REF"

  commit_push_pr \
    "feat: ${APP}のイメージを${tag}に更新" \
    "$(cat <<EOF
## 内容
- \`${img_dir}/TAG\`: ${tag}
- \`${img_dir}/SRC_REF\`: ${src_ref}

マージ後、\`.github/workflows/build-${APP}-image.yaml\` が自動発火し、
\`ghcr.io/${GH_OWNER}/${APP}:${tag}\` を公開します。
EOF
)"

  echo ""
  echo "マージ後、イメージビルドの成功を確認してから、次を実行してください:"
  echo "  gh run list --workflow=build-${APP}-image.yaml --branch main --limit 1"
  echo "  git pull"
  echo "  scripts/update-app-image.sh deploy-dev ${APP}"
}

cmd_deploy() {
  local env="$1"
  local dep_file="envs/${env}/apps/${APP}/deployment.yaml"
  [[ -f "$dep_file" ]] || {
    echo "エラー: ${dep_file} が見つかりません。" >&2
    if [[ "$env" != "dev" ]]; then
      echo "${env}にまだ${APP}が昇格されていない可能性があります。先に promote-${env} / promote-${env}-finish を実行してください。" >&2
    fi
    exit 1
  }
  local tag
  tag="$(tr -d '[:space:]' < "images/${APP}/TAG")"

  local build_conclusion
  build_conclusion="$(gh run list --workflow="build-${APP}-image.yaml" --branch main --limit 1 --json conclusion -q '.[0].conclusion' 2>/dev/null || echo "")"
  if [[ "$build_conclusion" != "success" ]]; then
    echo "エラー: build-${APP}-image.yaml の最新実行が成功していません(conclusion=${build_conclusion:-不明})。" >&2
    echo "ghcr.io/${GH_OWNER}/${APP}:${tag} が公開されていない可能性が高く、続行するとImagePullBackOffになります。" >&2
    echo "確認: gh run list --workflow=build-${APP}-image.yaml --branch main --limit 3" >&2
    exit 1
  fi

  ensure_clean_worktree
  require_main_uptodate

  open_branch "deploy-${env}/${APP}-${tag}"
  sed -i -E "s#(ghcr\.io/${GH_OWNER}/${APP}):[^\"[:space:]]+#\1:${tag}#" "$dep_file"
  echo "更新後のimage行: $(grep 'image:' "$dep_file")"
  git add "$dep_file"

  commit_push_pr \
    "feat: ${env}環境の${APP}を${tag}に更新" \
    "envs/${env}/apps/${APP}/deployment.yamlのイメージタグを${tag}に更新。マージ後${env}クラスタのFleetが自動適用します。"

  echo ""
  echo "マージ後、次で確認してください:"
  echo "  git pull && scripts/update-app-image.sh check-${env} ${APP}"
}

cmd_check() {
  local env="$1"
  local ctx host code path dep_file
  ctx="$(context_for_env "$env")"
  host="$(hostname_for_env "$env")"

  echo "== kubectl rollout status (${env}: ${ctx}) =="
  kubectl --context "$ctx" -n "$APP" rollout status "deployment/${APP}" --timeout=120s

  echo ""
  echo "== pods =="
  kubectl --context "$ctx" -n "$APP" get pods -o wide

  # ヘルスチェックパスはアプリごとに異なる(例: brc-advanced-searchはbaseURLが
  # /advanced固定でベアの/は404)。Deploymentのreadiness/livenessProbeが見ているpathを
  # そのまま使う(なければ/にフォールバック)。
  dep_file="envs/${env}/apps/${APP}/deployment.yaml"
  [[ -f "$dep_file" ]] || { echo "エラー: ${dep_file} が見つかりません。git pullでmainを最新化してから再実行してください。" >&2; exit 1; }
  path="$(awk '/readinessProbe:/{f=1} f && /path:/{print $2; exit}' "$dep_file")"
  path="${path:-/}"

  echo ""
  echo "== WEBアクセス確認: https://${host}${path} =="
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${host}${path}" || echo "000")"
  echo "HTTPステータス: ${code}"
  if [[ "$code" == "200" ]]; then
    echo "OK: ${host}${path} は200を返しました。"
  else
    echo "警告: 200以外です。DNS未登録・cert-manager未発行・SealedSecret未投入等を確認してください(docs/manual-apps.md参照)。" >&2
    exit 1
  fi
}

cmd_promote_prepare() {
  local from_env="$1" to_env="$2"
  local from_dir="envs/${from_env}/apps/${APP}"
  local to_dir="envs/${to_env}/apps/${APP}"
  [[ -d "$from_dir" ]] || { echo "エラー: ${from_dir} がありません。" >&2; exit 1; }
  [[ -d "$to_dir" ]] && {
    echo "エラー: ${to_dir} は既に存在します。既存の昇格が進行中でないか確認してください。" >&2
    echo "既に${to_env}へ初回昇格済みで、イメージバージョンを更新したいだけの場合は" >&2
    echo "promote-${to_env}ではなく deploy-${to_env} ${APP} を使ってください。" >&2
    exit 1
  }

  ensure_clean_worktree
  require_main_uptodate

  open_branch "promote/${APP}-${from_env}-to-${to_env}"
  mkdir -p "envs/${to_env}/apps"
  cp -r "$from_dir" "$to_dir"
  sed -i "s#${APP}\\.${from_env}\\.ibid\\.lan#${APP}.${to_env}.ibid.lan#g" "${to_dir}/ingress.yaml"

  echo "コピーとホスト名の書き換えが完了しました(まだコミットしていません):"
  git status --short

  local to_ctx secret_file
  to_ctx="$(context_for_env "$to_env")"
  secret_file="envs/${to_env}/secrets/${APP}.yaml"

  echo ""
  echo "=== 次に、GHCR pull用SealedSecretを手動で作成してください ==="
  cat <<EOF
kubectl create secret docker-registry ghcr-${APP} \\
  -n ${APP} \\
  --docker-server=ghcr.io \\
  --docker-username=<GitHubユーザー名> \\
  --docker-password=<PAT> \\
  --docker-email=unused@example.com \\
  --dry-run=client -o json \\
| kubeseal --context ${to_ctx} --format yaml > ${secret_file}
EOF
  echo ""
  echo "${to_env}向けのDNS Aレコード($(hostname_for_env "$to_env"))が未登録なら"
  echo "docs/manual-apps.md / docs/manual-cert-manager-freeipa-acme.md の手順で登録してください。"
  echo ""
  echo "SealedSecret作成後、次を実行してください:"
  echo "  scripts/update-app-image.sh promote-${to_env}-finish ${APP}"
}

cmd_promote_finish() {
  local to_env="$1"
  local to_dir="envs/${to_env}/apps/${APP}"
  local secret_file="envs/${to_env}/secrets/${APP}.yaml"
  local from_env

  case "$to_env" in
    staging) from_env="dev" ;;
    production) from_env="staging" ;;
  esac

  case "$(git rev-parse --abbrev-ref HEAD)" in
    promote/"${APP}"-"${from_env}"-to-"${to_env}") ;;
    *)
      echo "エラー: promote/${APP}-${from_env}-to-${to_env} ブランチではありません。先に promote-${to_env} を実行してください。" >&2
      exit 1
      ;;
  esac
  [[ -d "$to_dir" ]] || { echo "エラー: ${to_dir} がありません。先に promote-${to_env} を実行してください。" >&2; exit 1; }
  [[ -f "$secret_file" ]] || { echo "エラー: ${secret_file} がありません。SealedSecretを先に作成してください。" >&2; exit 1; }

  git add "$to_dir" "$secret_file"

  commit_push_pr \
    "feat: ${APP}を${to_env}環境へ昇格" \
    "$(cat <<EOF
## 昇格内容
\`envs/${from_env}/apps/${APP}\` → \`envs/${to_env}/apps/${APP}\`(手動昇格。promote.yamlはsites/のみ対象)

- ホスト名を \`${APP}.${from_env}.ibid.lan\` → \`$(hostname_for_env "$to_env")\` に変更
- GHCR pull用SealedSecretを \`$(context_for_env "$to_env")\` 向けに作り直し

## マージ後の確認
- [ ] scripts/update-app-image.sh check-${to_env} ${APP}
EOF
)"
}

cmd_cleanup_staging() {
  local dir="envs/staging/apps/${APP}"
  local secret_file="envs/staging/secrets/${APP}.yaml"
  if [[ ! -d "$dir" ]]; then
    echo "envs/staging/apps/${APP} は既にありません。何もしません。"
    exit 0
  fi

  ensure_clean_worktree
  require_main_uptodate

  open_branch "cleanup-staging/${APP}"
  git rm -r "$dir" >/dev/null
  [[ -f "$secret_file" ]] && git rm "$secret_file" >/dev/null

  commit_push_pr \
    "chore: ${APP}をstaging環境から削除" \
    "production昇格を確認済みのため、待機コストを残さないようstagingの${APP}を削除する。"

  echo ""
  echo "マージ後、必ず以下を実行してください(keepResources: trueのためGit削除だけではnamespaceは消えません):"
  echo "  kubectl --context staging1 delete namespace ${APP}"
  echo "注意: 順序を守ること。マージ前にnamespaceを消すと、まだfleet.yamlを検知しているstagingのGitRepoがFleetに再作成させてしまいます。"
}

case "$SUBCOMMAND" in
  latest-src-ref)            cmd_latest_src_ref ;;
  set-image)                 cmd_set_image "$@" ;;
  deploy-dev)                cmd_deploy dev ;;
  check-dev)                 cmd_check dev ;;
  promote-staging)           cmd_promote_prepare dev staging ;;
  promote-staging-finish)    cmd_promote_finish staging ;;
  deploy-staging)            cmd_deploy staging ;;
  check-staging)             cmd_check staging ;;
  promote-production)        cmd_promote_prepare staging production ;;
  promote-production-finish) cmd_promote_finish production ;;
  deploy-production)         cmd_deploy production ;;
  check-production)          cmd_check production ;;
  cleanup-staging)           cmd_cleanup_staging ;;
  *) usage ;;
esac
