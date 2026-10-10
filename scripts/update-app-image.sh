#!/usr/bin/env bash
# apps/配下の自作アプリ(brc-advanced-search, riken-diips等)のイメージ更新〜
# dev→production昇格を補助するスクリプト(docs/manual-apps.md の手順をなぞる)。
#
# 昇格は promote.yaml の対象外(sites/専用)のため、PR作成はこのスクリプトが行う。
# 昇格はディレクトリの丸ごとコピー(envs/dev/apps/<app> → envs/production/apps/<app>)。
# productionで変える値(ホスト名、レプリカ数等)はdev側のディレクトリ内の
# overlays/production/ に置いてあるため、コピー後の書き換えは不要
# (docs/operations-flow.md「環境差分の書き方」)。
# 以下は意図的に自動化していない:
#   - SealedSecret(GHCR pull用)の再作成: kubeseal実行にPAT等の秘密情報と対象クラスタへの
#     kubectlアクセスが要るため、コマンド例を表示して人手に委ねる。
#   - productionに触れるPRのマージ: mainのブランチ保護は「承認数0 + Code Ownersレビュー必須」
#     (CODEOWNERSは/envs/production/のみ)。dev・images/だけに触れるPR(set-image・deploy-dev)は
#     validate通過後にこのスクリプトがauto-mergeするが、production向け(deploy-production・
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
#   check-dev <app>                    devのrollout状況とWEBアクセス(readinessProbeのpathで200か)を確認。
#   sync-dev-data <app>                PVCで永続データを持つアプリ限定(persistent_data_dir_forに
#                                       登録済みのアプリのみ。現状sparqlistのみ)。productionの
#                                       永続データ(例: repository/)をdevへコピーし、本番相当
#                                       データでの確認を可能にする(WordPressの本番データリハーサル相当。
#                                       docs/manual-apps.md「devでの本番データ確認」参照)。
#                                       **dev側の内容は上書きされる**。
#   promote-production <app>           【初回昇格専用】envs/dev/apps/<app> を envs/production/apps/<app> へ
#                                       新規コピーする(ブランチ作成のみ、コミットはしない)。dev側に
#                                       overlays/production/ が無ければエラー。SealedSecret作成コマンドを
#                                       表示して停止する。既にある場合はエラーになる
#                                       (2回目以降はdeploy-productionを使うこと)。
#   promote-production-finish <app>    promote-productionでSealedSecretを手動作成した後に実行。
#                                       コミット・PR作成まで行う。
#   deploy-production <app>            【2回目以降】既にproductionにある<app>を、envs/dev/apps/<app>と
#                                       同じ内容に同期するPRを、promoteワークフロー(kind=apps)で作成する
#                                       (イメージタグを含むdevの変更すべてが昇格対象。PRのdiffで内容を
#                                       確認すること)。Actionsから直接 promote を起動しても同じ。
#   check-production <app>             productionのWEBアクセスを確認。
#
# 使い方の例(brc-advanced-searchをイメージ更新する場合):
#   scripts/update-app-image.sh latest-src-ref brc-advanced-search
#   (表示された内容を確認し、それが新TAGとして取り込みたいコミットか判断する)
#   scripts/update-app-image.sh set-image brc-advanced-search <新SRC_REF(コミットSHA)>
#   (tagは省略。現在のTAGから自動採番される。明示指定したい場合は
#    scripts/update-app-image.sh set-image brc-advanced-search 2.0.0-r6 <新SRC_REF>)
#   (イメージPRのマージ・ビルド・devへの反映PRのマージ・check-devまで自動で進む)
#   (devで動作確認)
#   scripts/update-app-image.sh deploy-production brc-advanced-search
#   (レビューの上、手動でPRをマージ)
#   git pull
#   scripts/update-app-image.sh check-production brc-advanced-search
#
# 新規アプリの初回昇格は、deploy-productionの代わりに次を使う:
#   (devのディレクトリに overlays/production/ を用意してdevへマージ済みであること)
#   scripts/update-app-image.sh promote-production <app>
#   (表示されたkubesealコマンドを実行してenvs/production/secrets/<app>.yamlを作る)
#   scripts/update-app-image.sh promote-production-finish <app>
#
# 前提: gh CLIが認証済み、kubectl/kubesealのコンテキスト(dev1/prod1)が
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
    *) echo "エラー: ${1} の取り込み元リポジトリが未登録です(このスクリプトの upstream_repo_for/upstream_branch_for に追記してください)。" >&2; exit 1 ;;
  esac
}

upstream_branch_for() {
  case "$1" in
    brc-advanced-search) echo "vue3-main-riken" ;;
    riken-diips) echo "main" ;;
    sparqlist) echo "main" ;;
    metadatabase-v2) echo "main" ;;
    *) echo "エラー: ${1} の取り込み元ブランチが未登録です。" >&2; exit 1 ;;
  esac
}

# GHCRイメージが公開設定のアプリはpull用SealedSecret(ghcr-<app>)が不要
# (ソースが公開リポジトリで、イメージも非公開にする理由がない場合。docs/manual-apps.md参照)。
# 新規アプリ追加時は必ずどちらかに登録すること。
ghcr_secret_needed_for() {
  case "$1" in
    brc-advanced-search|riken-diips|metadatabase-v2) echo yes ;;
    sparqlist) echo no ;;
    *) echo "エラー: ${1} のGHCR pull secret要否が未登録です(このスクリプトの ghcr_secret_needed_for に追記してください)。" >&2; exit 1 ;;
  esac
}

# PVCで永続データを持つアプリの、コンテナ内でのデータディレクトリ絶対パス。
# sync-dev-dataサブコマンドが production→dev のコピー元/先として使う
# (brc-advanced-search/riken-diipsのようにPVCを持たないアプリは対象外。
# docs/manual-apps.md「devでの本番データ確認」参照)。
persistent_data_dir_for() {
  case "$1" in
    sparqlist) echo "/app/repository" ;;
    *) echo "エラー: ${1} は永続データの同期に対応していません(このスクリプトの persistent_data_dir_for に追記してください。PVCを持たないアプリはそもそも対象外です)。" >&2; exit 1 ;;
  esac
}

context_for_env() {
  case "$1" in
    dev) echo "dev1" ;;
    production) echo "prod1" ;;
    *) echo "エラー: 不明な環境: $1" >&2; exit 1 ;;
  esac
}

hostname_for_env() {
  echo "${APP}.$1.ibid.lan"
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

  # productionで別イメージ名(例: metadatabase-v2-bioresource。BASE_PATH違い)を使うアプリは
  # overlays/production/deployment_patch.yaml にもimage行があるため、同じタグに揃える。
  local patch_file="envs/${env}/apps/${APP}/overlays/production/deployment_patch.yaml"
  local files=("$dep_file")
  if [[ -f "$patch_file" ]] && grep -q "ghcr\.io/${GH_OWNER}/${APP}" "$patch_file"; then
    files+=("$patch_file")
  fi

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
    echo "devで動作確認後、productionへ昇格する: scripts/update-app-image.sh deploy-production ${APP}"
  else
    echo "devの確認に失敗しました。あとで再確認: scripts/update-app-image.sh check-${env} ${APP}" >&2
    exit 1
  fi
}

# productionの<app>をdevと同じ内容に同期する(昇格=丸ごとコピー)。productionで変える値は
# dev側の overlays/production/ に入っているため、コピーだけで完結する。
# コピーとPR作成は promote ワークフロー(kind=apps)が行う(サイトと同じ仕組みに一本化)。
# ここでは起動してPRができるのを待ち、CIの結果を表示する。マージは人が行う。
cmd_deploy_production() {
  local from_dir="envs/dev/apps/${APP}"
  local to_dir="envs/production/apps/${APP}"
  [[ -d "$from_dir" ]] || { echo "エラー: ${from_dir} がありません。" >&2; exit 1; }
  [[ -d "$to_dir" ]] || {
    echo "エラー: ${to_dir} がありません。初回昇格は promote-production / promote-production-finish を使ってください。" >&2
    exit 1
  }
  require_main_uptodate
  if diff -rq "$from_dir" "$to_dir" >/dev/null; then
    echo "devとproductionの${APP}に差分がありません。PRは作成しません。"
    exit 0
  fi

  local started run_id="" pr_url="" i
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh workflow run promote.yaml -f kind=apps -f name="$APP"
  echo "promoteワークフローを起動しました。実行を待っています..."
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
  pr_url="$(gh pr list --state open --search "head:promote/dev-to-production-apps-${APP}-${run_id}" --json url -q '.[0].url // empty')"
  [[ -n "$pr_url" ]] || { echo "エラー: 昇格PRが見つかりません(run ${run_id})。" >&2; exit 1; }
  echo "PR作成: ${pr_url}"
  echo "CIチェックを待っています..."
  gh pr checks "$pr_url" --watch || echo "警告: CIチェックが失敗、またはタイムアウトしました: ${pr_url}" >&2

  echo ""
  echo "PRのdiffを確認してマージしてください。マージ後、次で確認してください:"
  echo "  git pull && scripts/update-app-image.sh check-production ${APP}"
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
  # productionでパスを変えているアプリ(例: metadatabase-v2の/bioresource)はパッチ側を優先する。
  local patch_file="envs/${env}/apps/${APP}/overlays/production/deployment_patch.yaml"
  if [[ "$env" == "production" && -f "$patch_file" ]]; then
    local patch_path
    patch_path="$(awk '/readinessProbe:/{f=1} f && /path:/{print $2; exit}' "$patch_file")"
    path="${patch_path:-$path}"
  fi
  path="${path:-/}"

  echo ""
  echo "== WEBアクセス確認: https://${host}${path} =="
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${host}${path}" || echo "000")"
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

cmd_promote_prepare() {
  local from_env="dev" to_env="production"
  local from_dir="envs/${from_env}/apps/${APP}"
  local to_dir="envs/${to_env}/apps/${APP}"
  [[ -d "$from_dir" ]] || { echo "エラー: ${from_dir} がありません。" >&2; exit 1; }
  [[ -d "${from_dir}/overlays/production" ]] || {
    echo "エラー: ${from_dir}/overlays/production がありません。" >&2
    echo "productionで変える値(ホスト名等)のパッチと、fleet.yamlのtargetCustomizationsを" >&2
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
      echo "ADMIN_SECRET_KEY/ADMIN_INITIAL_PASSWORDは${to_env}用に新規生成、VIRTUOSO_ISQL_PASSWORDは${to_env}のVirtuosoのもの:"
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

cmd_promote_finish() {
  local from_env="dev" to_env="production"
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
\`envs/${from_env}/apps/${APP}\` → \`envs/${to_env}/apps/${APP}\`(初回昇格。丸ごとコピー。promote.yamlはsites/のみ対象)

- productionで変える値(ホスト名 \`$(hostname_for_env "$to_env")\` 等)は \`overlays/production/\` で適用される
${secret_line}

## マージ後の確認
- [ ] scripts/update-app-image.sh check-${to_env} ${APP}
EOF
)"
}

case "$SUBCOMMAND" in
  latest-src-ref)            cmd_latest_src_ref ;;
  set-image)                 cmd_set_image "$@" ;;
  deploy-dev)                cmd_deploy_dev ;;
  check-dev)                 cmd_check dev ;;
  sync-dev-data)             cmd_sync_dev_data ;;
  promote-production)        cmd_promote_prepare ;;
  promote-production-finish) cmd_promote_finish ;;
  deploy-production)         cmd_deploy_production ;;
  check-production)          cmd_check production ;;
  *) usage ;;
esac
