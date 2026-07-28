#!/usr/bin/env bash
# apps/配下の自作アプリ(brc-advanced-search, riken-diips等)のイメージ更新〜
# dev→staging→production昇格を補助するスクリプト(docs/manual-apps.md の手順をなぞる)。
#
# 昇格は promote.yaml の対象外(sites/専用)のため、PR作成はこのスクリプトが行う。
# 以下の2点は意図的に自動化していない:
#   - SealedSecret(GHCR pull用)の再作成: kubeseal実行にPAT等の秘密情報と対象クラスタへの
#     kubectlアクセスが要るため、コマンド例を表示して人手に委ねる。
#   - productionのPRマージ: `envs/production/**` はCODEOWNERS承認が必須のブランチ保護が
#     かかっているため、PR作成までで止め、承認後は手動マージとする。
# dev/stagingのPRは低リスクなため自動マージ(gh pr merge --auto)まで行う。
#
# 各ステージは独立したサブコマンドで、前段の結果(pod Ready・WEBアクセス200等)を
# 確認してから次を手動で実行する運用を想定している。
#
# サブコマンド:
#   set-image <app> <tag> <src_ref>    images/<app>/{TAG,SRC_REF}を更新しPR+自動マージ。
#                                       マージ後 build-<app>-image.yaml が自動発火する。
#   deploy-dev <app>                   envs/dev/apps/<app>/deployment.yamlのイメージタグを
#                                       images/<app>/TAGに合わせて更新しPR+自動マージ。
#   check-dev <app>                    devのrollout状況とWEBアクセス(200か)を確認。
#   promote-staging <app>              envs/dev/apps/<app> を envs/staging/apps/<app> へコピーし
#                                       ホスト名を書き換える(ブランチ作成のみ、コミットはしない)。
#                                       SealedSecret作成コマンドを表示して停止する。
#   promote-staging-finish <app>       promote-stagingでSealedSecretを手動作成した後に実行。
#                                       コミット・PR作成・自動マージまで行う。
#   check-staging <app>                stagingのWEBアクセスを確認。
#   promote-production <app>           envs/staging/apps/<app> を envs/production/apps/<app> へ
#                                       コピー。SealedSecret作成コマンドを表示して停止する。
#   promote-production-finish <app>    コミット・PR作成のみ(自動マージしない)。
#   check-production <app>             productionのWEBアクセスを確認。
#   cleanup-staging <app>              本番反映確認後、staging側のGit定義を削除するPR+自動マージ。
#                                       マージ後に実行するkubectl delete namespaceコマンドを表示する。
#
# 使い方の例(brc-advanced-searchをイメージ更新する場合):
#   scripts/update-app-image.sh set-image brc-advanced-search 2.0.0-r6 <新SRC_REF>
#   (PRマージとイメージビルド完了を待つ)
#   scripts/update-app-image.sh deploy-dev brc-advanced-search
#   (PRマージを待つ)
#   scripts/update-app-image.sh check-dev brc-advanced-search
#   scripts/update-app-image.sh promote-staging brc-advanced-search
#   (表示されたkubesealコマンドを実行してenvs/staging/secrets/brc-advanced-search.yamlを作る)
#   scripts/update-app-image.sh promote-staging-finish brc-advanced-search
#   (PRマージを待つ)
#   scripts/update-app-image.sh check-staging brc-advanced-search
#   scripts/update-app-image.sh promote-production brc-advanced-search
#   (kubesealコマンドを実行してenvs/production/secrets/brc-advanced-search.yamlを作る)
#   scripts/update-app-image.sh promote-production-finish brc-advanced-search
#   (CODEOWNERS承認後、手動でPRをマージ)
#   scripts/update-app-image.sh check-production brc-advanced-search
#   scripts/update-app-image.sh cleanup-staging brc-advanced-search
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
commit_push_pr() {
  local title="$1" body="$2" automerge="$3"
  git commit -m "$title"
  git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
  local pr_url
  pr_url="$(gh pr create --title "$title" --body "$body")"
  echo "PR作成: $pr_url"
  if [[ "$automerge" == "true" ]]; then
    if gh pr merge --squash --auto "$pr_url"; then
      echo "自動マージを有効化しました(CIが通り次第マージされます)。"
    else
      echo "警告: 自動マージの設定に失敗しました。手動でマージしてください: $pr_url" >&2
    fi
  else
    echo "productionはCODEOWNERS承認が必須のため自動マージしていません。"
    echo "承認後、手動でマージしてください: $pr_url"
  fi
  git checkout main
}

cmd_set_image() {
  local tag="${1:-}" src_ref="${2:-}"
  [[ -n "$tag" && -n "$src_ref" ]] || { echo "使い方: $0 set-image <app> <tag> <src_ref>" >&2; exit 1; }
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
)" \
    "true"

  echo ""
  echo "マージとイメージビルドの完了を確認してから、次を実行してください:"
  echo "  gh run list --workflow=build-${APP}-image.yaml --branch main --limit 1"
  echo "  git pull"
  echo "  scripts/update-app-image.sh deploy-dev ${APP}"
}

cmd_deploy_dev() {
  local dep_file="envs/dev/apps/${APP}/deployment.yaml"
  [[ -f "$dep_file" ]] || { echo "エラー: ${dep_file} が見つかりません。" >&2; exit 1; }
  local tag
  tag="$(tr -d '[:space:]' < "images/${APP}/TAG")"

  ensure_clean_worktree
  require_main_uptodate

  open_branch "deploy-dev/${APP}-${tag}"
  sed -i -E "s#(ghcr\.io/${GH_OWNER}/${APP}):[^\"[:space:]]+#\1:${tag}#" "$dep_file"
  echo "更新後のimage行: $(grep 'image:' "$dep_file")"
  git add "$dep_file"

  commit_push_pr \
    "feat: dev環境の${APP}を${tag}に更新" \
    "envs/dev/apps/${APP}/deployment.yamlのイメージタグを${tag}に更新。マージ後devクラスタのFleetが自動適用します。" \
    "true"

  echo ""
  echo "マージ後、次で確認してください:"
  echo "  git pull && scripts/update-app-image.sh check-dev ${APP}"
}

cmd_check() {
  local env="$1"
  local ctx host code
  ctx="$(context_for_env "$env")"
  host="$(hostname_for_env "$env")"

  echo "== kubectl rollout status (${env}: ${ctx}) =="
  kubectl --context "$ctx" -n "$APP" rollout status "deployment/${APP}" --timeout=120s

  echo ""
  echo "== pods =="
  kubectl --context "$ctx" -n "$APP" get pods -o wide

  echo ""
  echo "== WEBアクセス確認: https://${host}/ =="
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${host}/" || echo "000")"
  echo "HTTPステータス: ${code}"
  if [[ "$code" == "200" ]]; then
    echo "OK: ${host} は200を返しました。"
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
  [[ -d "$to_dir" ]] && { echo "エラー: ${to_dir} は既に存在します。既存の昇格が進行中でないか確認してください。" >&2; exit 1; }

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
  local to_env="$1" automerge="$2"
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
)" \
    "$automerge"
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
    "production昇格を確認済みのため、待機コストを残さないようstagingの${APP}を削除する。" \
    "true"

  echo ""
  echo "マージ後、必ず以下を実行してください(keepResources: trueのためGit削除だけではnamespaceは消えません):"
  echo "  kubectl --context staging1 delete namespace ${APP}"
  echo "注意: 順序を守ること。マージ前にnamespaceを消すと、まだfleet.yamlを検知しているstagingのGitRepoがFleetに再作成させてしまいます。"
}

case "$SUBCOMMAND" in
  set-image)                 cmd_set_image "$@" ;;
  deploy-dev)                cmd_deploy_dev ;;
  check-dev)                 cmd_check dev ;;
  promote-staging)           cmd_promote_prepare dev staging ;;
  promote-staging-finish)    cmd_promote_finish staging true ;;
  check-staging)             cmd_check staging ;;
  promote-production)        cmd_promote_prepare staging production ;;
  promote-production-finish) cmd_promote_finish production false ;;
  check-production)          cmd_check production ;;
  cleanup-staging)           cmd_cleanup_staging ;;
  *) usage ;;
esac
