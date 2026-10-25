#!/usr/bin/env bash
# apps/配下の自作アプリ(brc-advanced-search, riken-diips等)のイメージ更新〜
# dev→staging→production昇格を補助するスクリプト(docs/manual-apps.md の手順をなぞる)。
#
# 自作アプリはstagingに常駐させる(2026-10-25〜。WordPressサイトと違い軽く、Secretの封印に人手が要るため)。
# 本番へは必ずstagingを通す(promoteワークフローの本番への昇格元はstaging)。
# 昇格はディレクトリの丸ごとコピー(envs/dev/apps/<app> → envs/staging/apps/<app> → envs/production/apps/<app>)。
# staging・productionで変える値(ホスト名、レプリカ数等)はdev側のディレクトリ内の
# overlays/<env>/ に置いてあるため、コピー後の書き換えは不要
# (docs/operations-flow.md「環境差分の書き方」)。
# 以下は意図的に自動化していない:
#   - SealedSecret(GHCR pull用等)の作成: kubeseal実行にPAT等の秘密情報と対象クラスタへの
#     kubectlアクセスが要るため、コマンド例を表示して人手に委ねる(各環境への初回昇格のときだけ)。
#   - productionに触れるPRのマージ: mainのブランチ保護は「承認数0 + Code Ownersレビュー必須」
#     (CODEOWNERSは/envs/production/のみ)。dev・staging・images/だけに触れるPR(set-image・deploy-dev・
#     deploy-staging)はvalidate通過後にauto-mergeされるが、production向け(deploy-production・
#     promote-production-finish)はPR作成・CI待ちまでで止め、マージはレビューの上で手動
#     (GitHub UIまたは`gh pr merge --squash --admin`)に委ねる。
#
# 通常のイメージ更新は set-image 1回で「イメージPR→マージ→ビルド完了待ち→devへ反映するPR→
# マージ→devの確認」まで進む。各ステージはサブコマンドとしても単独で実行できる
# (途中で止まった場合の再開用。例: ビルド成功後に deploy-dev から)。
#
# サブコマンド:
#   latest-src-ref <app>               取り込み元リポジトリ(upstream_repo_for/upstream_branch_for
#                                       で登録済みのブランチ)のHEADコミットSHAとメッセージを表示する。
#                                       set-imageのsrc_refに使う値を手打ちしないためのもの。
#   set-image <app> [tag] <src_ref>    images/<app>/{TAG,SRC_REF}を更新しPR作成 → auto-merge →
#                                       build-<app>-image.yamlの成功を待ち、続けてdeploy-devを行う。
#                                       tagを省略すると、現在のTAGが<version>-r<N>形式の場合に
#                                       限り自動採番する(N+1。例: 2.0.0-r7 → 2.0.0-r8)。
#                                       その形式でない場合はエラーになるので明示指定すること。
#   deploy-dev <app>                   build-<app>-image.yamlの最新実行が成功していることを確認した上で、
#                                       envs/dev/apps/<app>/deployment.yamlのイメージタグを
#                                       images/<app>/TAGに合わせて更新しPR作成 → auto-merge →
#                                       check-devまで行う(通常はset-imageから自動で呼ばれる)。
#   check-dev|check-staging|check-production <app>
#                                       その環境のrollout状況とWEBアクセス(readinessProbeのpathで200か)を確認。
#   sync-dev-data <app>                PVCで永続データを持つアプリ限定(persistent_data_dir_forに
#                                       登録済みのアプリのみ。現状は登録なし)。productionの
#                                       永続データ(例: repository/)をdevへコピーする。
#                                       **dev側の内容は上書きされる**。
#   deploy-staging <app>               既にstagingにある<app>を、envs/dev/apps/<app>と同じ内容に同期するPRを
#                                       promoteワークフロー(kind=apps、to=staging)で作り、auto-mergeを待って
#                                       check-stagingまで行う(stagingだけのPRなので承認不要)。
#   deploy-production <app>            既にproductionにある<app>を、envs/staging/apps/<app>と同じ内容に
#                                       同期するPRを、promoteワークフロー(kind=apps、to=production)で作成する
#                                       (stagingに入っている変更すべてが昇格対象。PRのdiffで内容を確認すること)。
#   promote-staging <app>              【stagingへの初回昇格専用】envs/dev/apps/<app> を envs/staging/apps/<app> へ
#   promote-production <app>           【productionへの初回昇格専用】envs/staging/apps/<app> を envs/production/apps/<app> へ
#                                       新規コピーする(ブランチ作成のみ、コミットはしない)。昇格元に
#                                       overlays/<昇格先>/ が無ければエラー。SealedSecret作成コマンドを
#                                       表示して停止する。既にある場合はエラーになる
#                                       (2回目以降はdeploy-staging/deploy-productionを使うこと)。
#   promote-staging-finish <app>       promote-staging/promote-productionでSealedSecretを手動作成した後に実行。
#   promote-production-finish <app>    コミット・PR作成まで行う(stagingはauto-merge、productionは人がマージ)。
#
# パイプライン用(Rundeckの apps/<app> ジョブから呼ぶ。docs/manual-rundeck.md):
#   dev-update <app> [src_ref] [tag]   src_refが空なら latest-src-ref の値を使い、現在の
#                                       images/<app>/SRC_REFと同じなら何もせずcheck-devだけ行う。
#                                       違えば set-image を行う(tagが空なら自動採番)。
#   staging-update <app>               deploy-staging(差分が無ければcheck-stagingだけ)。
#   release-production <app>           deploy-production → 人がPRをマージするのを待つ
#                                       (MERGE_WAIT_MINUTES、既定240分。マージはしない) →
#                                       mainをpull → check-production。差分が無ければ確認だけ行う。
#
# gitを操作するサブコマンドは、同じクローンを使う他のジョブと排他する(scripts/lib/pr.sh pr_lock_repo)。
#
# 使い方の例(brc-advanced-searchをイメージ更新する場合):
#   scripts/update-app-image.sh latest-src-ref brc-advanced-search
#   (表示された内容を確認し、それが新TAGとして取り込みたいコミットか判断する)
#   scripts/update-app-image.sh set-image brc-advanced-search <新SRC_REF(コミットSHA)>
#   (tagは省略。現在のTAGから自動採番される。明示指定したい場合は
#    scripts/update-app-image.sh set-image brc-advanced-search 2.0.0-r6 <新SRC_REF>)
#   (イメージPRのマージ・ビルド・devへの反映PRのマージ・check-devまで自動で進む)
#   (devで動作確認)
#   scripts/update-app-image.sh deploy-staging brc-advanced-search
#   (stagingで動作確認)
#   scripts/update-app-image.sh deploy-production brc-advanced-search
#   (レビューの上、手動でPRをマージ)
#   git pull
#   scripts/update-app-image.sh check-production brc-advanced-search
#
# 新規アプリの初回昇格は、deploy-staging/deploy-productionの代わりに次を使う:
#   (devのディレクトリに overlays/staging/・overlays/production/ を用意してdevへマージ済みであること)
#   scripts/update-app-image.sh promote-staging <app>
#   (表示されたkubesealコマンドを実行してenvs/staging/secrets/<app>.yamlを作る)
#   scripts/update-app-image.sh promote-staging-finish <app>
#   (stagingで動作確認したら、同じように promote-production / promote-production-finish)
#
# 前提: gh CLIが認証済み、kubectl/kubesealのコンテキスト(dev1/staging1/prod1)が
# ~/.kube/config にマージ済みであること(docs/manual-tooling-setup.md参照)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/pr.sh
source "$SCRIPT_DIR/lib/pr.sh"

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
    sparqlist) echo "dbcls/sparqlist" ;;
    metadatabase-v2) echo "silver198545/metadatabase-v2" ;;
    brc-cross-search-xsearch|brc-cross-search-resource) echo "d-usuda/brc-cross-search" ;;
    member-gateway) echo "silver198545/member-gateway" ;;
    *) echo "エラー: ${1} の取り込み元リポジトリが未登録です(このスクリプトの upstream_repo_for/upstream_branch_for に追記してください)。" >&2; exit 1 ;;
  esac
}

upstream_branch_for() {
  case "$1" in
    brc-advanced-search) echo "vue3-main-riken" ;;
    riken-diips) echo "main" ;;
    sparqlist) echo "main" ;;
    metadatabase-v2) echo "main" ;;
    # Docker対応(APP_MODE)の作業ブランチ feature/docker-app-mode を追っていたが、
    # 2026-10-15にmainへマージされ(取り込み元PR #3)ブランチが削除されたためmainに切り替えた。
    brc-cross-search-xsearch|brc-cross-search-resource) echo "main" ;;
    member-gateway) echo "main" ;;
    *) echo "エラー: ${1} の取り込み元ブランチが未登録です。" >&2; exit 1 ;;
  esac
}

# GHCRイメージが公開設定のアプリはpull用SealedSecret(ghcr-<app>)が不要
# (ソースが公開リポジトリで、イメージも非公開にする理由がない場合。docs/manual-apps.md参照)。
# 新規アプリ追加時は必ずどちらかに登録すること。
ghcr_secret_needed_for() {
  case "$1" in
    brc-advanced-search|riken-diips|metadatabase-v2|brc-cross-search-xsearch|brc-cross-search-resource|member-gateway) echo yes ;;
    sparqlist) echo no ;;
    *) echo "エラー: ${1} のGHCR pull secret要否が未登録です(このスクリプトの ghcr_secret_needed_for に追記してください)。" >&2; exit 1 ;;
  esac
}

# WEBアクセス確認(check-dev/check-production)に使うパスを、readinessProbeのpathの代わりに指定するアプリ。
# probeはHTTP 200〜399を成功とみなすが、確認は200だけを正常とするため、probeのpathがリダイレクトを
# 返すアプリはここで200を返すパスを指定する(例: riken-diipsの / は /en// への307)。
check_path_override_for() {
  case "$1" in
    riken-diips) echo "/ja" ;;
    *) echo "" ;;
  esac
}

# PVCで永続データを持つアプリの、コンテナ内でのデータディレクトリ絶対パス。
# sync-dev-dataサブコマンドが production→dev のコピー元/先として使う
# (brc-advanced-search/riken-diipsのようにPVCを持たないアプリは対象外。
# docs/manual-apps.md「本番反映のサイクル」参照)。sparqlistは2026-10-21から
# repository/をdevとproductionで同じNFSディレクトリを共有するようにしたため外した(コピー不要)。
persistent_data_dir_for() {
  case "$1" in
    *) echo "エラー: ${1} は永続データの同期に対応していません(このスクリプトの persistent_data_dir_for に追記してください。PVCを持たないアプリはそもそも対象外です)。" >&2; exit 1 ;;
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

# 昇格先の環境から昇格元を決める(本番へは必ずstagingを通す)
from_env_for() {
  case "$1" in
    staging) echo "dev" ;;
    production) echo "staging" ;;
    *) echo "エラー: 昇格先は staging / production のいずれか: $1" >&2; exit 1 ;;
  esac
}

ensure_clean_worktree() { pr_ensure_clean_worktree; }
require_main_uptodate() { pr_require_main_uptodate; }

open_branch() {
  git checkout -b "$1"
}

# 呼び出し前にgit add/git rm済みであることを前提とする。PR作成・CI待ちまで(マージはしない)。
# devだけに触れるPRは呼び出し側で続けて pr_automerge_and_wait する(scripts/lib/pr.sh参照)。
commit_push_pr() {
  pr_commit_push_create "$1" "$2"
}

cmd_latest_src_ref() {
  local repo branch result sha
  repo="$(upstream_repo_for "$APP")"
  branch="$(upstream_branch_for "$APP")"

  if ! result="$(gh api "repos/${repo}/commits/${branch}" --jq '[.sha, .commit.author.date, (.commit.message | split("\n")[0])] | @tsv' 2>&1)"; then
    echo "エラー: ${repo}(${branch})の最新コミット取得に失敗しました。" >&2
    echo "$result" >&2
    echo "ghが${repo}への読み取り権限を持つアカウントで認証されているか確認してください(gh auth status)。" >&2
    echo "Rundeckのパイプライン用マシンユーザーで実行している場合は、そのアカウントが${repo}の" >&2
    echo "collaborator(Read)になっているか確認する(docs/manual-rundeck.md「実行アカウント」)。" >&2
    echo "すぐ進めたいときは、取り込むコミットのSHAをジョブのsrc_refに指定すれば、この取得は行わない。" >&2
    exit 1
  fi

  IFS=$'\t' read -r sha date message <<< "$result"
  echo "リポジトリ: ${repo} (${branch}ブランチ)" >&2
  echo "コミット日時: ${date}" >&2
  echo "コミットメッセージ: ${message}" >&2
  echo "SRC_REF: ${sha}" >&2
  echo "" >&2
  echo "内容を確認した上で、以下のように使ってください:" >&2
  echo "  scripts/update-app-image.sh set-image ${APP} ${sha}   # tagは現在のTAGから自動採番される" >&2
  echo "  (tagを明示指定したい場合: scripts/update-app-image.sh set-image ${APP} <新TAG> ${sha})" >&2
  echo "" >&2
  # 標準出力にはSHAのみを出す(他コマンドへの $(...) 渡しを想定)
  echo "$sha"
}

cmd_set_image() {
  local tag="" src_ref=""
  case $# in
    1) src_ref="$1" ;;                 # tag省略。自動採番する
    2) tag="$1"; src_ref="$2" ;;
    *) echo "使い方: $0 set-image <app> [tag] <src_ref>" >&2; exit 1 ;;
  esac
  [[ -n "$src_ref" ]] || { echo "使い方: $0 set-image <app> [tag] <src_ref>" >&2; exit 1; }
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

  if [[ -z "$tag" ]]; then
    local current_tag
    current_tag="$(tr -d '[:space:]' < "$img_dir/TAG")"
    if [[ "$current_tag" =~ ^(.+)-r([0-9]+)$ ]]; then
      # 10#で強制的に10進数として解釈する(先頭が0の場合、bashの算術展開は
      # デフォルトで8進数扱いするため、08/09のような値でエラーになるのを防ぐ)。
      tag="${BASH_REMATCH[1]}-r$((10#${BASH_REMATCH[2]} + 1))"
      echo "tag省略のため自動採番しました: ${current_tag} → ${tag}" >&2
    else
      echo "エラー: 現在の${img_dir}/TAG(${current_tag})が<version>-r<N>形式ではないため自動採番できません。tagを明示指定してください。" >&2
      exit 1
    fi
  fi

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

\`scripts/update-app-image.sh set-image\` で作成。マージ後、\`.github/workflows/build-${APP}-image.yaml\`
が \`ghcr.io/${GH_OWNER}/${APP}:${tag}\` を公開し、続けて同スクリプトがdevへ反映するPRを作成します。
EOF
)"
  pr_automerge_and_wait "$PR_URL"
  pr_wait_workflow "build-${APP}-image.yaml" "$MERGE_SHA"

  echo ""
  echo "イメージが公開されました。続けてdevへ反映します(deploy-dev)。"
  cmd_deploy_dev
}

cmd_deploy_dev() {
  local env="dev"
  local dep_file="envs/${env}/apps/${APP}/deployment.yaml"
  [[ -f "$dep_file" ]] || { echo "エラー: ${dep_file} が見つかりません。" >&2; exit 1; }
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

  # 環境によって別イメージ名(例: productionのmetadatabase-v2-bioresource。BASE_PATH違い)を使うアプリは
  # overlays/<env>/deployment_patch.yaml にもimage行があるため、同じタグに揃える。
  local patch_file
  local files=("$dep_file")
  for patch_file in "envs/${env}/apps/${APP}/overlays/"*/deployment_patch.yaml; do
    if [[ -f "$patch_file" ]] && grep -q "ghcr\.io/${GH_OWNER}/${APP}" "$patch_file"; then
      files+=("$patch_file")
    fi
  done

  open_branch "deploy-${env}/${APP}-${tag}"
  sed -i -E "s#(ghcr\.io/${GH_OWNER}/${APP}(-[a-z0-9]+)?):[^\"[:space:]]+#\1:${tag}#" "${files[@]}"
  echo "更新後のimage行:"
  grep -H 'image:' "${files[@]}"
  git add "${files[@]}"

  commit_push_pr \
    "feat: ${env}環境の${APP}を${tag}に更新" \
    "envs/${env}/apps/${APP}/deployment.yamlのイメージタグを${tag}に更新。マージ後${env}クラスタのFleetが自動適用します。"
  pr_automerge_and_wait "$PR_URL"

  # Fleetがマージを検知して適用するまで少し待ってから確認する(GitRepoのポーリング間隔は既定15秒)。
  echo "Fleetの適用を待っています(60秒)..."
  sleep 60
  if cmd_check "$env"; then
    echo ""
    echo "devで動作確認後、stagingへ昇格する: scripts/update-app-image.sh deploy-staging ${APP}"
  else
    echo "devの確認に失敗しました。あとで再確認: scripts/update-app-image.sh check-${env} ${APP}" >&2
    exit 1
  fi
}

# 昇格先(staging/production)の<app>を昇格元(dev/staging)と同じ内容に同期する(昇格=丸ごとコピー)。
# 環境で変える値は dev側の overlays/<env>/ に入っているため、コピーだけで完結する。
# コピーとPR作成は promote ワークフロー(kind=apps)が行う(サイトと同じ仕組みに一本化)。
# ここでは起動してPRができるのを待ち、CIの結果を表示する。stagingはauto-merge、productionは人がマージする。
# 引数: <staging|production>
cmd_deploy() {
  local to_env="$1" from_env
  from_env="$(from_env_for "$to_env")"
  local from_dir="envs/${from_env}/apps/${APP}"
  local to_dir="envs/${to_env}/apps/${APP}"
  [[ -d "$from_dir" ]] || {
    echo "エラー: ${from_dir} がありません。" >&2
    [[ "$from_env" == staging ]] && echo "本番へはstagingを通して昇格します(先に deploy-staging、stagingが初めてなら promote-staging)。" >&2
    exit 1
  }
  [[ -d "$to_dir" ]] || {
    echo "エラー: ${to_dir} がありません。初回昇格は promote-${to_env} / promote-${to_env}-finish を使ってください。" >&2
    exit 1
  }
  require_main_uptodate
  PR_URL=""
  if [[ "$to_env" == production ]] && ! diff -rq "envs/dev/apps/${APP}" "$from_dir" >/dev/null; then
    echo "注意: devの${APP}にはstagingで未確認の変更があります(昇格するのはstagingの内容。devの変更も入れるなら先に deploy-staging)。" >&2
  fi
  if diff -rq "$from_dir" "$to_dir" >/dev/null; then
    echo "${from_env}と${to_env}の${APP}に差分がありません。PRは作成しません。"
    return 0
  fi

  local started run_id="" pr_url="" i
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh workflow run promote.yaml -f kind=apps -f to="$to_env" -f name="$APP"
  echo "promoteワークフロー(${from_env}→${to_env})を起動しました。実行を待っています..."
  for ((i = 0; i < 30; i++)); do
    run_id="$(gh run list --workflow=promote.yaml --event workflow_dispatch --limit 5 \
      --json databaseId,createdAt -q "[.[] | select(.createdAt >= \"${started}\")] | last | .databaseId // empty")"
    [[ -n "$run_id" ]] && break
    sleep 5
  done
  [[ -n "$run_id" ]] || { echo "エラー: promoteワークフローの実行が見つかりません(gh run list --workflow=promote.yaml)。" >&2; exit 1; }
  if ! gh run watch "$run_id" --exit-status >/dev/null; then
    echo "エラー: promoteワークフローが失敗しました: gh run view ${run_id} --log-failed" >&2
    exit 1
  fi
  pr_url="$(gh pr list --state all --search "head:promote/${from_env}-to-${to_env}-apps-${APP}-${run_id}" --json url -q '.[0].url // empty')"
  [[ -n "$pr_url" ]] || { echo "エラー: 昇格PRが見つかりません(run ${run_id})。" >&2; exit 1; }
  echo "PR作成: ${pr_url}"
  pr_comment_actor "$pr_url"
  PR_URL="$pr_url"
  echo "CIチェックを待っています..."
  gh pr checks "$pr_url" --watch || echo "警告: CIチェックが失敗、またはタイムアウトしました: ${pr_url}" >&2

  if [[ "$to_env" == staging ]]; then
    return 0
  fi
  echo ""
  echo "PRのdiffを確認してマージしてください。マージ後、次で確認してください:"
  echo "  git pull && scripts/update-app-image.sh check-production ${APP}"
}

# stagingへの反映(auto-mergeを待つ)→ stagingの確認。パイプラインの staging-update もこれ。
cmd_deploy_staging() {
  local i state
  cmd_deploy staging
  if [[ -n "$PR_URL" ]]; then
    echo "auto-mergeを待っています..."
    for ((i = 0; i < 90; i++)); do
      state="$(gh pr view "$PR_URL" --json state -q .state)"
      case "$state" in
        MERGED) break ;;
        CLOSED) echo "エラー: PRがマージされずにcloseされました: ${PR_URL}" >&2; exit 1 ;;
      esac
      sleep 10
    done
    [[ "$state" == MERGED ]] || { echo "エラー: 15分待ってもマージされませんでした: ${PR_URL}" >&2; exit 1; }
    git pull --ff-only origin main
    pr_unlock_repo
    echo "Fleetの適用を待っています(60秒)..."
    sleep 60
  fi
  pr_unlock_repo
  if cmd_check staging; then
    echo ""
    echo "stagingで動作確認後、productionへ昇格する: scripts/update-app-image.sh deploy-production ${APP}"
  else
    echo "stagingの確認に失敗しました。あとで再確認: scripts/update-app-image.sh check-staging ${APP}" >&2
    exit 1
  fi
}

# パイプライン用: 取り込み元の最新(またはsrc_ref指定)を、変更があるときだけdevへ入れる。
cmd_dev_update() {
  local src_ref="${1:-}" tag="${2:-}" current
  if [[ -z "$src_ref" ]]; then
    src_ref="$(cmd_latest_src_ref)"
    echo "取り込み元の最新コミットを使います: ${src_ref}"
  fi
  current="$(tr -d '[:space:]' < "images/${APP}/SRC_REF")"
  if [[ "$current" == "$src_ref"* || "$src_ref" == "$current"* ]]; then
    echo "images/${APP}/SRC_REF は既に ${current} です。イメージ更新は不要なので、devの確認だけ行います。"
    pr_unlock_repo
    cmd_check dev
    return
  fi
  if [[ -n "$tag" ]]; then
    cmd_set_image "$tag" "$src_ref"
  else
    cmd_set_image "$src_ref"
  fi
}

# パイプライン用: 本番への昇格PR作成 → 人のマージ待ち → 本番の確認。
cmd_release_production() {
  cmd_deploy production
  if [[ -n "$PR_URL" ]]; then
    pr_unlock_repo   # マージ待ちの間は他のジョブにクローンを譲る
    pr_wait_human_merge "$PR_URL" "${MERGE_WAIT_MINUTES:-240}"
    pr_lock_repo
    git pull --ff-only origin main
    pr_unlock_repo
    echo "Fleetの適用を待っています(60秒)..."
    sleep 60
  fi
  cmd_check production
}

cmd_check() {
  local env="$1"
  local ctx host code path probe_path dep_file
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
  probe_path="$(awk '/readinessProbe:/{f=1} f && /path:/{print $2; exit}' "$dep_file")"
  # 環境によってパスを変えているアプリ(例: productionのmetadatabase-v2の/bioresource)はパッチ側を優先する。
  local patch_file="envs/${env}/apps/${APP}/overlays/${env}/deployment_patch.yaml"
  if [[ "$env" != "dev" && -f "$patch_file" ]]; then
    local patch_path
    patch_path="$(awk '/readinessProbe:/{f=1} f && /path:/{print $2; exit}' "$patch_file")"
    probe_path="${patch_path:-$probe_path}"
  fi
  path="$(check_path_override_for "$APP")"
  [[ -n "$path" ]] || path="${probe_path:-/}"

  echo ""
  echo "== WEBアクセス確認: https://${host}${path} =="
  # 接続できないときもcurlは -w で 000 を出力して失敗する(|| echo 000 だと 000000 になる)
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${host}${path}" || true)"
  code="${code:-000}"
  echo "HTTPステータス: ${code}"
  if [[ "$code" == "200" ]]; then
    echo "OK: ${host}${path} は200を返しました。"
  else
    echo "警告: 200以外です。DNS未登録・cert-manager未発行・SealedSecret未投入等を確認してください(docs/manual-apps.md参照)。" >&2
    return 1
  fi
}

cmd_sync_dev_data() {
  local data_dir parent_dir dir_name prod_pod dev_pod archive_name tmp_file
  data_dir="$(persistent_data_dir_for "$APP")"
  parent_dir="$(dirname "$data_dir")"
  dir_name="$(basename "$data_dir")"
  archive_name="${APP}-data-sync.tar.gz"

  # jsonpathはPodが0件だと非0で終了する(set -eで即死しないよう || true で受ける)。
  prod_pod="$(kubectl --context prod1 -n "$APP" get pods -l app="$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$prod_pod" ]] || { echo "エラー: production(prod1)に${APP}のPodが見つかりません。" >&2; exit 1; }
  dev_pod="$(kubectl --context dev1 -n "$APP" get pods -l app="$APP" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$dev_pod" ]] || { echo "エラー: dev(dev1)に${APP}のPodが見つかりません。" >&2; exit 1; }

  echo "production Pod: ${prod_pod}" >&2
  echo "dev Pod:        ${dev_pod}" >&2
  echo "同期対象: ${data_dir} (production → dev。dev側の内容は上書きされます)" >&2

  tmp_file="$(mktemp "/tmp/${archive_name}.XXXXXX")"
  trap 'rm -f "$tmp_file"' EXIT

  kubectl --context prod1 -n "$APP" exec "$prod_pod" -- \
    tar czf "/tmp/${archive_name}" -C "$parent_dir" "$dir_name"
  kubectl --context prod1 -n "$APP" cp "${prod_pod}:/tmp/${archive_name}" "$tmp_file"
  kubectl --context prod1 -n "$APP" exec "$prod_pod" -- rm "/tmp/${archive_name}"

  kubectl --context dev1 -n "$APP" cp "$tmp_file" "${dev_pod}:/tmp/${archive_name}"
  # -m(mtime復元しない)/--no-same-permissions を付けないと、既存の(マウントポイントである)
  # ディレクトリ自体の属性復元でtarが失敗する(docs/manual-apps.md「実際に踏んだ問題」参照。
  # ファイル本体の展開自体はこのオプション無しでも成功するが、終了コードで失敗を検知できなくなるため付ける)。
  kubectl --context dev1 -n "$APP" exec "$dev_pod" -- \
    tar xzf "/tmp/${archive_name}" -C "$parent_dir" -m --no-same-permissions
  kubectl --context dev1 -n "$APP" exec "$dev_pod" -- rm "/tmp/${archive_name}"

  rm -f "$tmp_file"
  trap - EXIT

  echo ""
  echo "同期しました。devで本番相当データでの動作を確認してください: https://$(hostname_for_env dev)/"
}

# 引数: <staging|production>
cmd_promote_prepare() {
  local to_env="$1" from_env
  from_env="$(from_env_for "$to_env")"
  local from_dir="envs/${from_env}/apps/${APP}"
  local to_dir="envs/${to_env}/apps/${APP}"
  [[ -d "$from_dir" ]] || {
    echo "エラー: ${from_dir} がありません。" >&2
    [[ "$from_env" == staging ]] && echo "本番へはstagingを通して昇格します。先に promote-staging ${APP} でstagingへ初回昇格してください。" >&2
    exit 1
  }
  [[ -d "${from_dir}/overlays/${to_env}" ]] || {
    echo "エラー: ${from_dir}/overlays/${to_env} がありません。" >&2
    echo "${to_env}で変える値(ホスト名等)のパッチと、fleet.yamlのtargetCustomizationsを" >&2
    echo "devのディレクトリに用意してdevへマージしてから実行してください" >&2
    echo "(docs/operations-flow.md「環境差分の書き方」、既存のbrc-advanced-search等が参考になる)。" >&2
    exit 1
  }
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

  echo "コピーが完了しました(まだコミットしていません):"
  git status --short

  local to_ctx secret_file
  to_ctx="$(context_for_env "$to_env")"
  secret_file="envs/${to_env}/secrets/${APP}.yaml"

  echo ""
  if [[ "$(ghcr_secret_needed_for "$APP")" == "yes" ]]; then
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
    if [[ "$APP" == "metadatabase-v2" ]]; then
      echo ""
      echo "=== 管理画面用SealedSecret(metadatabase-v2-admin)も${to_env}向けに作成してください ==="
      echo "ADMIN_SECRET_KEY/ADMIN_INITIAL_PASSWORDは${to_env}用に新規生成、VIRTUOSO_ISQL_PASSWORDは${to_env}が使うVirtuosoのもの"
      echo "(stagingはdevと同じVirtuosoを使う。overlays/stagingはVirtuosoの接続先を変えない):"
      cat <<EOF
kubectl create secret generic metadatabase-v2-admin \\
  -n ${APP} \\
  --from-literal=ADMIN_SECRET_KEY="\$(openssl rand -base64 32)" \\
  --from-literal=ADMIN_INITIAL_PASSWORD="\$(openssl rand -base64 18)" \\
  --from-literal=VIRTUOSO_ISQL_PASSWORD='<Virtuosoのdbaパスワード>' \\
  --dry-run=client -o json \\
| kubeseal --context ${to_ctx} --format yaml > envs/${to_env}/secrets/${APP}-admin.yaml
EOF
    fi
    if [[ "$APP" == "member-gateway" ]]; then
      echo ""
      echo "=== kintone用SealedSecret(member-gateway-kintone)も${to_env}向けに作成してください ==="
      echo "APIトークンはアプリ360の「レコード閲覧」権限だけを付けたもの(devとは別に発行することを推奨):"
      cat <<EOF
kubectl create secret generic member-gateway-kintone \\
  -n ${APP} \\
  --from-literal=base-url='https://<サブドメイン>.cybozu.com' \\
  --from-literal=api-token='<APIトークン>' \\
  --dry-run=client -o json \\
| kubeseal --context ${to_ctx} --format yaml > envs/${to_env}/secrets/${APP}-kintone.yaml
EOF
    fi
  else
    echo "${APP}のGHCRイメージは公開設定のため、pull用SealedSecretは不要です。"
    if [[ "$APP" == "sparqlist" ]]; then
      echo ""
      echo "=== 次に、ADMIN_PASSWORD用SealedSecretを作成してください(${to_env}向けに新規生成) ==="
      echo "  scripts/seal-sparqlist-secret.sh ${to_env}"
    fi
  fi
  echo ""
  echo "DNSは環境ごとのワイルドカード(*.${to_env}.ibid.lan)なので、$(hostname_for_env "$to_env") の登録は不要です"
  echo "(docs/manual-cert-manager-freeipa-acme.md「サイトホスト名のDNS」)。"
  echo ""
  echo "SealedSecret作成後、次を実行してください:"
  echo "  scripts/update-app-image.sh promote-${to_env}-finish ${APP}"
}

# 引数: <staging|production>
cmd_promote_finish() {
  local to_env="$1" from_env
  from_env="$(from_env_for "$to_env")"
  local to_dir="envs/${to_env}/apps/${APP}"
  local secret_file="envs/${to_env}/secrets/${APP}.yaml"

  case "$(git rev-parse --abbrev-ref HEAD)" in
    promote/"${APP}"-"${from_env}"-to-"${to_env}") ;;
    *)
      echo "エラー: promote/${APP}-${from_env}-to-${to_env} ブランチではありません。先に promote-${to_env} を実行してください。" >&2
      exit 1
      ;;
  esac
  [[ -d "$to_dir" ]] || { echo "エラー: ${to_dir} がありません。先に promote-${to_env} を実行してください。" >&2; exit 1; }
  [[ -f "$secret_file" ]] || { echo "エラー: ${secret_file} がありません。SealedSecretを先に作成してください。" >&2; exit 1; }

  if [[ "$APP" == "metadatabase-v2" && ! -f "envs/${to_env}/secrets/${APP}-admin.yaml" ]]; then
    echo "エラー: envs/${to_env}/secrets/${APP}-admin.yaml がありません。promote-${to_env}の表示どおり作成してください。" >&2
    exit 1
  fi
  if [[ "$APP" == "member-gateway" && ! -f "envs/${to_env}/secrets/${APP}-kintone.yaml" ]]; then
    echo "エラー: envs/${to_env}/secrets/${APP}-kintone.yaml がありません。promote-${to_env}の表示どおり作成してください。" >&2
    exit 1
  fi

  git add "$to_dir" "$secret_file"
  # アプリ用の追加Secret(例: metadatabase-v2-admin.yaml)があれば一緒に含める。
  local extra
  for extra in "envs/${to_env}/secrets/${APP}"-*.yaml; do
    if [[ -f "$extra" ]]; then
      git add "$extra"
    fi
  done

  local secret_line
  if [[ "$(ghcr_secret_needed_for "$APP")" == "yes" ]]; then
    secret_line="- GHCR pull用SealedSecretを \`$(context_for_env "$to_env")\` 向けに作り直し"
  else
    secret_line="- ADMIN_PASSWORD等のアプリ用SealedSecretを \`$(context_for_env "$to_env")\` 向けに新規生成(GHCRイメージは公開設定のためpull用Secretは無し)"
  fi

  commit_push_pr \
    "feat: ${APP}を${to_env}環境へ昇格" \
    "$(cat <<EOF
## 昇格内容
\`envs/${from_env}/apps/${APP}\` → \`envs/${to_env}/apps/${APP}\`(初回昇格。丸ごとコピー。2回目以降はpromoteワークフロー)

- ${to_env}で変える値(ホスト名 \`$(hostname_for_env "$to_env")\` 等)は \`overlays/${to_env}/\` で適用される
${secret_line}

## マージ後の確認
- [ ] scripts/update-app-image.sh check-${to_env} ${APP}
EOF
)"
  if [[ "$to_env" == staging ]]; then
    # stagingだけに触れるPRはCODEOWNERSの対象外。validateが通ればマージする
    pr_automerge_and_wait "$PR_URL"
    echo "Fleetの適用を待っています(60秒)..."
    sleep 60
    cmd_check staging || echo "stagingの確認に失敗しました。あとで再確認: scripts/update-app-image.sh check-staging ${APP}" >&2
  fi
}

case "$SUBCOMMAND" in
  set-image|deploy-dev|promote-staging|promote-staging-finish|promote-production|promote-production-finish|deploy-staging|deploy-production|dev-update|staging-update|release-production)
    pr_lock_repo ;;
esac

case "$SUBCOMMAND" in
  latest-src-ref)            cmd_latest_src_ref ;;
  set-image)                 cmd_set_image "$@" ;;
  deploy-dev)                cmd_deploy_dev ;;
  check-dev)                 cmd_check dev ;;
  check-staging)             cmd_check staging ;;
  check-production)          cmd_check production ;;
  sync-dev-data)             cmd_sync_dev_data ;;
  promote-staging)           cmd_promote_prepare staging ;;
  promote-staging-finish)    cmd_promote_finish staging ;;
  promote-production)        cmd_promote_prepare production ;;
  promote-production-finish) cmd_promote_finish production ;;
  deploy-staging|staging-update) cmd_deploy_staging ;;
  deploy-production)         cmd_deploy production ;;
  dev-update)                cmd_dev_update "$@" ;;
  release-production)        cmd_release_production ;;
  *) usage ;;
esac
