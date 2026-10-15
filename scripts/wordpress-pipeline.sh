#!/usr/bin/env bash
# WordPressサイトの運用パイプライン。Rundeckの wordpress グループのジョブ
# (rundeck/jobs/wordpress.yaml、docs/manual-rundeck.md)から呼ぶ。手動でも実行できる。
# 手順書の手作業を順につないだもので、各段の内容は次の手順書と同じ:
#   docs/operations-flow.md「本番データリハーサル」「本番反映前のバックアップ」
#   docs/manual-wordpress-restore.md「日次バックアップ」「6b.」
#   docs/runbook/wordpress-update.md「C. 本番へ昇格する」
#
# サブコマンド:
#   dev-refresh <site>...            本番の最新コンテンツでdevの同名サイトを上書きする。
#                                    本番のバックアップを今すぐ取る → devの現状をバックアップ →
#                                    リストア → URL置換 → 確認。gitは触らない
#   rehearsal-start <site>           本番と同じ構成のリハーサルサイト <site>-rh をdev1に作り
#                                    (devだけのPRなのでauto-merge)、本番の最新コンテンツを入れて、
#                                    比較の基準(各ページのHTTPステータス・版)を記録する
#   rehearsal-upgrade <site>         <site>-rh をdevの構成(昇格予定の変更)へ切り替え、
#                                    プラグイン同期Job・DB更新・MariaDBアップグレード・表示を基準と比べる
#   rehearsal-cleanup <site>         <site>-rh をGitから消し(auto-merge)、namespaceを削除する
#   promote-production <site...|all> 本番への昇格PRを作り、対象サイトの本番バックアップを取ってから
#                                    人がPRをマージするのを待ち(このスクリプトはマージしない)、
#                                    反映後に本番を確認する
#   backup <env> <site...|all>       日次バックアップのCronJobから今すぐ1つ取る(完了まで待つ)
#   check <env> <site...|all>        各サイトのHTTPステータス(200か)とPodの状態を確認する
#
# 環境変数:
#   NFS_BACKUP_ROOT=<path>    バックアップNFSのマウント先(既定 /mnt/ibid-nfs/backup。
#                             192.168.1.1:/data/nfs を読み取り専用でマウントしておく)
#   FRESH_BACKUP=0            dev-refresh/rehearsal-start で本番のバックアップを新たに取らず、
#                             最新の日次バックアップ(JST 3:00)を使う
#   MERGE_WAIT_MINUTES=<分>   promote-production で人のマージを待つ時間(既定240)
#
# 前提: gh CLIが認証済み、kubectl/kubesealのコンテキスト dev1/prod1 が ~/.kube/config にあること
# (docs/manual-tooling-setup.md)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/pr.sh
source "$SCRIPT_DIR/lib/pr.sh"

NFS_BACKUP_ROOT="${NFS_BACKUP_ROOT:-/mnt/ibid-nfs/backup}"
FRESH_BACKUP="${FRESH_BACKUP:-1}"
MERGE_WAIT_MINUTES="${MERGE_WAIT_MINUTES:-240}"
WP_PATH="/opt/bitnami/wordpress"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/ibid-fleet-config/rehearsal"

usage() {
  echo "使い方: $0 <subcommand> [args...]" >&2
  echo "詳細はスクリプト冒頭のコメントを参照してください。" >&2
  exit 1
}

die() { echo "エラー: $*" >&2; exit 1; }

for cmd in git gh curl kubectl flock; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' が見つかりません。"
done

# ---------------------------------------------------------------------------
# 共通
# ---------------------------------------------------------------------------

context_for_env() {
  case "$1" in
    dev) echo "dev1" ;;
    production) echo "prod1" ;;
    *) die "envは dev / production のいずれかを指定してください: $1" ;;
  esac
}

kc() {
  local env="$1"
  shift
  kubectl --context "$(context_for_env "$env")" "$@"
}

# サイトのwordpressコンテナでwp-cliを実行する
wp_cli() {
  local env="$1" site="$2"
  shift 2
  kc "$env" -n "wordpress-$site" exec "deploy/wordpress-$site" -c wordpress -- wp --path="$WP_PATH" "$@"
}

check_site_name() {
  [[ "$1" =~ ^[a-z0-9-]+$ ]] || die "サイト名は英小文字・数字・ハイフンのみ使用できます: $1"
}

# 引数(サイト名の並び、または all)を SITES 配列に展開する。all はその環境のリハーサルサイト以外の全サイト。
resolve_sites() {
  local env="$1" s d
  shift
  SITES=()
  [[ $# -gt 0 ]] || die "サイト名を指定してください(複数可。all で全サイト)。"
  if [[ "$*" == "all" ]]; then
    for d in "envs/$env/sites/"*/; do
      s="$(basename "$d")"
      [[ "$s" == *-rh ]] && continue
      SITES+=("$s")
    done
  else
    for s in "$@"; do
      [[ "$s" == "all" ]] && die "all は他のサイト名と一緒に指定できません。"
      check_site_name "$s"
      [[ -d "envs/$env/sites/$s" ]] || die "envs/$env/sites/$s がありません。"
      SITES+=("$s")
    done
  fi
}

require_nfs() {
  [[ -d "$NFS_BACKUP_ROOT/production" ]] || die "$NFS_BACKUP_ROOT/production が見えません。バックアップNFSを読み取り専用でマウントしてください:
  sudo mkdir -p /mnt/ibid-nfs && sudo mount -t nfs -o ro,nfsvers=4.1 192.168.1.1:/data/nfs /mnt/ibid-nfs
(docs/manual-wordpress-restore.md「日次バックアップ」)"
}

backup_dir() { echo "$NFS_BACKUP_ROOT/$1/wordpress-$2"; }

# NFS上の最新のバックアップ(dumpとtarが揃っているもの)の時刻 yyyymmdd_hhmm
latest_backup_ts() {
  local dir ts
  dir="$(backup_dir "$1" "$2")"
  for ts in $(find "$dir" -maxdepth 1 -name '[0-9]*_[0-9]*.dump.gz' -printf '%f\n' 2>/dev/null | sed 's/\.dump\.gz$//' | sort -r); do
    if [[ -f "$dir/$ts.tar.gz" ]]; then
      echo "$ts"
      return 0
    fi
  done
  return 1
}

# Jobの完了を待つ。失敗・時間切れならログを表示して1を返す。
# 引数: <env> <namespace> <job名> <待つ秒数>
wait_job() {
  local env="$1" ns="$2" job="$3" timeout="$4" i conds
  for ((i = 0; i < timeout / 10; i++)); do
    conds="$(kc "$env" -n "$ns" get job "$job" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)"
    case " $conds " in
      *" Complete "*) return 0 ;;
      *" Failed "*) break ;;
    esac
    sleep 10
  done
  echo "エラー: Job ${ns}/${job} が成功しませんでした(状態: ${conds:-実行中のまま時間切れ})。ログ:" >&2
  kc "$env" -n "$ns" logs "job/$job" --tail=50 >&2 || true
  return 1
}

# 日次バックアップのCronJobから今すぐ1つ取る(SITES全部を並行して)。
# 取れたバックアップの時刻を BACKUP_TS[<site>] に入れる。
declare -A BACKUP_TS=()
take_backups() {
  local env="$1" ts s job dir i failed=0
  shift
  ts="$(date +%Y%m%d%H%M%S)"
  for s in "$@"; do
    kc "$env" -n "wordpress-$s" create job --from="cronjob/wordpress-$s-backup" "wordpress-$s-backup-manual-$ts" >/dev/null
    echo "バックアップ開始: ${env}/${s}"
  done
  for s in "$@"; do
    job="wordpress-$s-backup-manual-$ts"
    if ! wait_job "$env" "wordpress-$s" "$job" 3600; then
      failed=1
      continue
    fi
    BACKUP_TS[$s]="$(kc "$env" -n "wordpress-$s" logs "job/$job" | grep -oE '[0-9]{8}_[0-9]{4}\.dump\.gz' | head -1 | sed 's/\.dump\.gz$//')"
    [[ -n "${BACKUP_TS[$s]}" ]] || { echo "エラー: ${s} のバックアップのファイル名をログから読めませんでした(job/${job})。" >&2; failed=1; continue; }
    echo "バックアップ完了: ${env}/${s} ${BACKUP_TS[$s]}(${NFS_BACKUP_ROOT}/${env}/wordpress-${s}/)"
  done
  [[ $failed -eq 0 ]] || die "失敗したバックアップがあります。"
  # 作業端末のNFSクライアントのキャッシュで新しいファイルが少し遅れて見えることがある
  if [[ -d "$NFS_BACKUP_ROOT/$env" ]]; then
    for s in "$@"; do
      dir="$(backup_dir "$env" "$s")"
      for ((i = 0; i < 24; i++)); do
        [[ -f "$dir/${BACKUP_TS[$s]}.dump.gz" && -f "$dir/${BACKUP_TS[$s]}.tar.gz" ]] && break
        sleep 5
      done
    done
  fi
}

# Helmリリースの現在のリビジョン(Fleetが適用するたびに増える)。まだ無い・読めないときは空
helm_revision() {
  { kc "$1" -n "wordpress-$2" get secret -l "owner=helm,name=wordpress-$2,status=deployed" \
    -o jsonpath='{.items[*].metadata.labels.version}' 2>/dev/null || true; } | tr ' ' '\n' | sort -n | tail -1
}

# Fleetがサイトを適用し終えるのを待つ。<before_rev>を渡すと、それより新しいリビジョンになるまで待つ。
# 引数: <env> <site> [before_rev]
wait_site_applied() {
  local env="$1" site="$2" before="${3:-}" ns="wordpress-$2" i rev=""
  echo "Fleetによる ${env}/${site} の適用を待っています..."
  for ((i = 0; i < 120; i++)); do
    rev="$(helm_revision "$env" "$site")"
    if [[ -n "$rev" ]] && { [[ -z "$before" ]] || (( rev > before )); }; then
      break
    fi
    sleep 15
  done
  [[ -n "$rev" ]] && { [[ -z "$before" ]] || (( rev > before )); } \
    || die "30分待っても ${env}/${site} が適用されません(Rancher UIのContinuous Deliveryでバンドルの状態を確認してください)。"
  echo "Helmリリース: リビジョン ${rev}"
  kc "$env" -n "$ns" rollout status "statefulset/wordpress-$site-mariadb" --timeout=20m
  kc "$env" -n "$ns" rollout status "deploy/wordpress-$site" --timeout=20m
}

# サイトの確認用URL(Ingressの内部名 + sitePath)。fleet.yamlから組み立てる
site_url() {
  local env="$1" site="$2" f prefix path
  f="envs/$env/sites/$site/fleet.yaml"
  prefix="$(grep -oP '^\s*hostname: \K[a-z0-9-]+' "$f" | head -1)"
  path="$(grep -oP '^    sitePath: \K\S+' "$f" | head -1 || true)"
  echo "https://${prefix}.${env}.ibid.lan${path}/"
}

cmd_check() {
  local env="$1" s code url bad failed=0
  shift
  resolve_sites "$env" "$@"
  for s in "${SITES[@]}"; do
    url="$(site_url "$env" "$s")"
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "$url" || echo 000)"
    bad="$(kc "$env" -n "wordpress-$s" get pods --no-headers 2>/dev/null | grep -v -E 'Running|Completed' || true)"
    printf '%-14s %s  %s\n' "$s" "$code" "$url"
    if [[ "$code" != "200" ]]; then
      failed=1
    fi
    if [[ -n "$bad" ]]; then
      echo "  正常でないPod:"
      sed 's/^/    /' <<<"$bad"
      failed=1
    fi
  done
  [[ $failed -eq 0 ]] || { echo "200以外、または正常でないPodがあります(docs/runbook/troubleshooting.md)。" >&2; return 1; }
  echo "全サイト正常です。"
}

# リストアしたDBに残る本番のURL(DBのhome)を、このサイトのURL(wp-config.phpのWP_HOME)へ置換する。
# docs/manual-wordpress-restore.md 6b. の置換を、ホスト名単位で行う(/ja・/enなどのパスはそのまま)。
replace_urls() {
  local env="$1" site="$2" src dst src_host dst_host dst_scheme old new
  src="$(wp_cli "$env" "$site" eval 'global $wpdb; echo $wpdb->get_var("SELECT option_value FROM $wpdb->options WHERE option_name = \"home\"");')"
  dst="$(wp_cli "$env" "$site" eval 'echo defined("WP_HOME") ? WP_HOME : home_url();')"
  src_host="$(sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$src")"
  dst_host="$(sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$dst")"
  dst_scheme="$(sed -E 's#^([a-z]+)://.*#\1#' <<<"$dst")"
  echo "URL置換: ${src}(リストアしたDB) → ${dst}(このサイトのWP_HOME)"
  if [[ -z "$src_host" || -z "$dst_host" ]]; then
    die "URLを読み取れませんでした(DBのhome='${src}' / WP_HOME='${dst}')。"
  fi
  if [[ "$src_host" == "$dst_host" ]]; then
    echo "ホスト名が同じなので置換しません。"
    return 0
  fi
  # 順に: スキームあり(http/https)、スキーム無し参照、JSON内でエスケープされたURL。
  # スキーム無しは "//<host>/" とパス区切りまで含めて一致させ、Freemius等が持つ
  # ホスト名だけの値(fs_accountsのhost)は書き換えない(6b.参照)。
  local -a pairs=(
    "http://${src_host}"     "${dst_scheme}://${dst_host}"
    "https://${src_host}"    "${dst_scheme}://${dst_host}"
    "//${src_host}/"         "//${dst_host}/"
    "http:\\/\\/${src_host}"  "${dst_scheme}:\\/\\/${dst_host}"
    "https:\\/\\/${src_host}" "${dst_scheme}:\\/\\/${dst_host}"
  )
  local i
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    old="${pairs[i]}"
    new="${pairs[i + 1]}"
    printf '  %s → %s: ' "$old" "$new"
    wp_cli "$env" "$site" search-replace "$old" "$new" --all-tables-with-prefix --skip-columns=guid --precise 2>&1 | tail -1
  done
  wp_cli "$env" "$site" cache flush >/dev/null || true
  wp_cli "$env" "$site" rewrite flush >/dev/null || echo "警告: wp rewrite flush に失敗しました(パーマリンクが404なら手動で実行してください)。" >&2
}

# 本番<src_site>のバックアップ(時刻<ts>)を dev の<dst_site>へリストアし、URLを置換する
restore_from_production() {
  local src_site="$1" dst_site="$2" ts="$3"
  echo ""
  echo "=== リストア: production/${src_site}(${ts}) → dev/${dst_site} ==="
  # (dev-refreshではサブシェル内のif条件として呼ばれ set -e が効かないため、各段で明示的に止める)
  KUBE_CONTEXT=dev1 IBID_ASSUME_YES=1 "$SCRIPT_DIR/restore-wordpress.sh" \
    "$dst_site" "$(backup_dir production "$src_site")" "$ts" || return 1
  # Podの入れ替え中に置換すると途中で切れるため、落ち着いてから行う(6b.参照)
  kc dev -n "wordpress-$dst_site" rollout status "deploy/wordpress-$dst_site" --timeout=10m || return 1
  replace_urls dev "$dst_site" || return 1
}

# 本番データのバックアップの時刻をサイトごとに決める(FRESH_BACKUP=1なら今すぐ取る)
prepare_production_backups() {
  local s
  if [[ "$FRESH_BACKUP" == "1" ]]; then
    take_backups production "$@"
  else
    for s in "$@"; do
      BACKUP_TS[$s]="$(latest_backup_ts production "$s")" || die "production/${s} の日次バックアップが見つかりません: $(backup_dir production "$s")"
      echo "最新の日次バックアップを使います: production/${s} ${BACKUP_TS[$s]}"
    done
  fi
}

# ---------------------------------------------------------------------------
# dev-refresh: 本番コンテンツ → devの同名サイト
# ---------------------------------------------------------------------------

cmd_dev_refresh() {
  local s ts
  resolve_sites dev "$@"
  local -a targets=("${SITES[@]}")
  for s in "${targets[@]}"; do
    [[ "$s" == *-rh ]] && die "リハーサルサイトは対象外です: $s(rehearsal-start を使ってください)"
    [[ -d "envs/production/sites/$s" ]] || die "本番に ${s} がありません(envs/production/sites/${s})。"
    if kc dev -n "wordpress-$s" exec "deploy/wordpress-$s" -c wordpress -- test -e /bitnami/wordpress/wp-content.orig 2>/dev/null; then
      die "dev/${s} に前回のリストアの退避分 wp-content.orig が残っています。内容を確認して削除してから再実行してください:
  kubectl --context dev1 -n wordpress-$s exec deploy/wordpress-$s -c wordpress -- rm -rf /bitnami/wordpress/wp-content.orig"
    fi
  done
  require_nfs

  echo "=== 本番のバックアップ ==="
  prepare_production_backups "${targets[@]}"
  local -A prod_ts=()
  for s in "${targets[@]}"; do prod_ts[$s]="${BACKUP_TS[$s]}"; done

  echo ""
  echo "=== devの現状のバックアップ(上書き前。戻すときは restore-wordpress.sh で) ==="
  take_backups dev "${targets[@]}"

  local failed=()
  for s in "${targets[@]}"; do
    ts="${prod_ts[$s]}"
    if ! (restore_from_production "$s" "$s" "$ts"); then
      echo "エラー: dev/${s} のリストアに失敗しました。上書き前のバックアップ: $(backup_dir dev "$s")/${BACKUP_TS[$s]}" >&2
      failed+=("$s")
      continue
    fi
    if cmd_check dev "$s"; then
      kc dev -n "wordpress-$s" exec "deploy/wordpress-$s" -c wordpress -- rm -rf /bitnami/wordpress/wp-content.orig
    else
      echo "警告: dev/${s} の確認に失敗しました。wp-content.orig(上書き前のwp-content)は残してあります。" >&2
      failed+=("$s")
    fi
  done

  echo ""
  if [[ ${#failed[@]} -gt 0 ]]; then
    die "失敗したサイト: ${failed[*]}"
  fi
  echo "devの ${targets[*]} を本番のコンテンツで更新しました。表示・管理画面をブラウザで確認してください。"
}

# ---------------------------------------------------------------------------
# 本番データリハーサル(docs/operations-flow.md「本番データリハーサル」)
# ---------------------------------------------------------------------------

rh_state_dir() { echo "$STATE_ROOT/$1-rh"; }

# リハーサルサイトの状態を記録する(<dir>/<name>-info.txt と <name>-pages.txt)。
# ページの一覧は基準の記録時(before)に作り、以降は同じページを見る。
rh_snapshot() {
  local site="$1" name="$2" rh="$1-rh" dir host url path code
  dir="$(rh_state_dir "$site")"
  mkdir -p "$dir"
  {
    echo "WordPress: $(wp_cli dev "$rh" core version 2>/dev/null || echo 不明)"
    echo "MariaDB(mariadb_upgrade_info): $(kc dev -n "wordpress-$rh" exec "wordpress-$rh-mariadb-0" -c mariadb -- cat /bitnami/mariadb/data/mariadb_upgrade_info 2>/dev/null || echo なし)"
    echo "テーマ: $(wp_cli dev "$rh" theme list --status=active --field=name 2>/dev/null | tr '\n' ' ')"
    echo "プラグイン(name,status,version):"
    { wp_cli dev "$rh" plugin list --fields=name,status,version --format=csv 2>/dev/null || printf 'header\n(取得失敗)\n'; } | tail -n +2 | sed 's/^/  /'
  } >"$dir/$name-info.txt"

  if [[ ! -f "$dir/paths.txt" ]]; then
    {
      echo "/"
      { wp_cli dev "$rh" post list --post_type=post,page --post_status=publish --posts_per_page=10 \
        --orderby=modified --field=url 2>/dev/null || true; } | sed -E 's#^[a-z]+://[^/]+##'
    } | sort -u >"$dir/paths.txt"
  fi
  host="$(grep -oP '^\s*hostname: \K[a-z0-9-]+' "envs/dev/sites/$rh/fleet.yaml" | head -1).dev.ibid.lan"
  : >"$dir/$name-pages.txt"
  while read -r path; do
    [[ "$path" == "/" ]] && path="$(grep -oP '^    sitePath: \K\S+' "envs/dev/sites/$rh/fleet.yaml" | head -1 || true)/"
    url="https://${host}${path}"
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "$url" || echo 000)"
    echo "$code $path" >>"$dir/$name-pages.txt"
  done <"$dir/paths.txt"
  echo "--- ${name}: $(cat "$dir/$name-info.txt" | head -2 | tr '\n' ' ')"
  sed 's/^/  /' "$dir/$name-pages.txt"
}

rh_require_single() {
  local rh="$1" d other=()
  for d in envs/dev/sites/*-rh; do
    [[ -d "$d" && "$(basename "$d")" != "$rh" ]] && other+=("$(basename "$d")")
  done
  [[ ${#other[@]} -eq 0 ]] || die "他のリハーサルサイトがあります: ${other[*]}。dev1のメモリの都合で同時に置けるのは1つまでです。先に rehearsal-cleanup してください。"
}

cmd_rehearsal_start() {
  [[ $# -eq 1 ]] || usage
  local site="$1" rh="$1-rh" ts
  check_site_name "$site"
  [[ "$site" != *-rh ]] || die "リハーサル元のサイト名を指定してください: $site"
  [[ -d "envs/production/sites/$site" ]] || die "本番に ${site} がありません。"
  rh_require_single "$rh"
  require_nfs

  pr_lock_repo
  pr_ensure_clean_worktree
  pr_require_main_uptodate
  if [[ -d "envs/dev/sites/$rh" ]]; then
    die "envs/dev/sites/${rh} は既にあります。続きは rehearsal-upgrade、作り直すなら rehearsal-cleanup してから実行してください。"
  fi

  git checkout -b "rehearsal/${rh}-start-$(date +%Y%m%d%H%M%S)"
  "$SCRIPT_DIR/rehearsal-site.sh" "$site" production
  SEAL_HIDE_PASSWORDS=1 "$SCRIPT_DIR/seal-site-secrets.sh" dev "$rh"
  git add "envs/dev/sites/$rh" "envs/dev/secrets/$rh.yaml"
  pr_commit_push_create \
    "chore: 本番データリハーサル用に${rh}をdevへ追加" \
    "$(cat <<EOF
## 内容
\`scripts/wordpress-pipeline.sh rehearsal-start ${site}\` で作成。本番(\`envs/production/sites/${site}\`)と同じ構成の
一時サイト \`${rh}\` をdev1に作り、本番の最新コンテンツをリストアします(docs/operations-flow.md「本番データリハーサル」)。

リハーサルが終わったら \`rehearsal-cleanup ${site}\` で削除します。
EOF
)"
  pr_automerge_and_wait "$PR_URL"
  pr_unlock_repo

  wait_site_applied dev "$rh"

  echo ""
  echo "=== 本番のバックアップ ==="
  prepare_production_backups "$site"
  ts="${BACKUP_TS[$site]}"
  restore_from_production "$site" "$rh" "$ts"
  kc dev -n "wordpress-$rh" exec "deploy/wordpress-$rh" -c wordpress -- rm -rf /bitnami/wordpress/wp-content.orig

  rm -f "$(rh_state_dir "$site")"/*
  echo ""
  echo "=== 比較の基準(本番と同じ構成・本番データ)を記録します ==="
  rh_snapshot "$site" before
  echo "production/${site} ${ts}" >"$(rh_state_dir "$site")/source.txt"
  echo ""
  echo "リハーサルサイトを本番と同じ構成で用意しました: $(site_url dev "$rh")"
  echo "(リンク先はdevの公開ドメインになる。docs/manual-wordpress-restore.md 6b.)"
}

cmd_rehearsal_upgrade() {
  [[ $# -eq 1 ]] || usage
  local site="$1" rh="$1-rh" dir before_rev merged_at job_line job_created job failed=0 secs
  check_site_name "$site"
  dir="$(rh_state_dir "$site")"
  [[ -d "envs/dev/sites/$rh" ]] || die "envs/dev/sites/${rh} がありません。先に rehearsal-start ${site} を実行してください。"
  [[ -f "$dir/before-pages.txt" ]] || echo "警告: 比較の基準(${dir}/before-pages.txt)がありません。比較はせず現状だけ表示します。" >&2

  pr_lock_repo
  pr_ensure_clean_worktree
  pr_require_main_uptodate
  before_rev="$(helm_revision dev "$rh")"
  git checkout -b "rehearsal/${rh}-upgrade-$(date +%Y%m%d%H%M%S)"
  "$SCRIPT_DIR/rehearsal-site.sh" "$site" dev
  if git diff --quiet; then
    git checkout main
    git branch -D "$(git rev-parse --abbrev-ref '@{-1}')" >/dev/null
    pr_unlock_repo
    echo "devと本番の ${site} の構成に差分がありません(昇格予定の変更が無い)。リハーサルで確かめることはありません。"
    return 0
  fi
  echo "適用する変更(本番の構成 → devの構成):"
  git --no-pager diff
  git add "envs/dev/sites/$rh"
  pr_commit_push_create \
    "chore: ${rh}をdevの構成へ切り替えて本番データリハーサル" \
    "\`scripts/wordpress-pipeline.sh rehearsal-upgrade ${site}\` で作成。\`${rh}\`(本番データ)に、昇格予定の構成(\`envs/dev/sites/${site}\`)を適用します。"
  merged_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  pr_automerge_and_wait "$PR_URL"
  pr_unlock_repo

  SECONDS=0
  wait_site_applied dev "$rh" "$before_rev"
  echo "適用にかかった時間: ${SECONDS}秒"

  echo ""
  echo "=== プラグイン同期Job ==="
  job=""
  for ((secs = 0; secs < 300; secs += 15)); do
    job_line="$(kc dev -n "wordpress-$rh" get jobs -l app.kubernetes.io/component=plugin-sync \
      -o jsonpath='{range .items[*]}{.metadata.creationTimestamp} {.metadata.name}{"\n"}{end}' 2>/dev/null | sort | tail -1)"
    job_created="${job_line%% *}"
    if [[ -n "$job_line" && "$job_created" > "$merged_at" ]]; then
      job="${job_line#* }"
      break
    fi
    sleep 15
  done
  if [[ -z "$job" ]]; then
    echo "新しいプラグイン同期Jobは作られませんでした(プラグイン一覧・イメージに変更が無い)。"
  elif wait_job dev "wordpress-$rh" "$job" 1200; then
    echo "成功: job/${job}(所要時間: $(kc dev -n "wordpress-$rh" get job "$job" -o go-template='{{.status.startTime}} → {{.status.completionTime}}'))"
    kc dev -n "wordpress-$rh" logs "job/$job" --tail=20 | sed 's/^/  /'
  else
    failed=1
  fi

  echo ""
  echo "=== WordPressのDB更新(管理画面の「データベースの更新が必要です」に相当) ==="
  SECONDS=0
  wp_cli dev "$rh" core update-db 2>&1 | tail -3 | sed 's/^/  /' || failed=1
  echo "所要時間: ${SECONDS}秒"

  echo ""
  echo "=== 切り替え後の状態 ==="
  rh_snapshot "$site" after

  echo ""
  echo "=== 基準(本番と同じ構成)との比較 ==="
  if [[ -f "$dir/before-pages.txt" ]]; then
    diff "$dir/before-info.txt" "$dir/after-info.txt" | sed 's/^/  /' || true
    local regressed
    regressed="$(join -1 2 -2 2 <(sort -k2 "$dir/before-pages.txt") <(sort -k2 "$dir/after-pages.txt") \
      | awk '$2 != $3 { print "  " $1 ": " $2 " → " $3 }')"
    if [[ -n "$regressed" ]]; then
      echo "HTTPステータスが変わったページ:"
      echo "$regressed"
      failed=1
    else
      echo "HTTPステータスが変わったページはありません($(wc -l <"$dir/after-pages.txt")ページ)。"
    fi
  fi

  echo ""
  echo "=== 切り替え後のPHPエラー(wordpressコンテナのログ) ==="
  kc dev -n "wordpress-$rh" logs "deploy/wordpress-$rh" -c wordpress --since=1h 2>/dev/null \
    | grep -iE 'PHP (Fatal|Parse|Warning)|Uncaught' | tail -30 | sed 's/^/  /' || echo "  なし"

  echo ""
  echo "リハーサルサイト: $(site_url dev "$rh")"
  echo "表示・管理画面・プラグイン固有の画面をブラウザでも確認し、結果(所要時間・気づいた点)を昇格PRに書いてください。"
  echo "終わったら rehearsal-cleanup ${site} でリハーサルサイトを削除します。"
  [[ $failed -eq 0 ]] || die "リハーサルで問題が見つかりました(上の出力を確認してください)。devで修正して rehearsal-upgrade をやり直せます。"
}

cmd_rehearsal_cleanup() {
  [[ $# -eq 1 ]] || usage
  local site="$1" rh="$1-rh" paths=()
  check_site_name "$site"
  [[ "$site" != *-rh ]] || die "リハーサル元のサイト名を指定してください: $site"

  pr_lock_repo
  pr_ensure_clean_worktree
  pr_require_main_uptodate
  [[ -d "envs/dev/sites/$rh" ]] && paths+=("envs/dev/sites/$rh")
  [[ -f "envs/dev/secrets/$rh.yaml" ]] && paths+=("envs/dev/secrets/$rh.yaml")
  if [[ ${#paths[@]} -gt 0 ]]; then
    git checkout -b "rehearsal/${rh}-cleanup-$(date +%Y%m%d%H%M%S)"
    git rm -r -q "${paths[@]}"
    pr_commit_push_create \
      "chore: 本番データリハーサル用の${rh}をdevから削除" \
      "\`scripts/wordpress-pipeline.sh rehearsal-cleanup ${site}\` で作成。マージ後、同スクリプトがdev1の \`wordpress-${rh}\` namespaceを削除します(\`keepResources: true\` のためGitの削除だけでは消えない)。"
    pr_automerge_and_wait "$PR_URL"
  else
    echo "Git側には ${rh} がありません(削除済み)。"
  fi
  pr_unlock_repo

  # マージ後に消す(先に消すとFleetが作り直す)。本番のコピーが入っているので必ず消す
  if kc dev get namespace "wordpress-$rh" >/dev/null 2>&1; then
    echo "namespace wordpress-${rh} を削除します(PVCも削除されます)..."
    kc dev delete namespace "wordpress-$rh" --wait=true --timeout=15m
  fi
  local released
  released="$(kc dev get pv --no-headers 2>/dev/null | grep "wordpress-$rh/" || true)"
  if [[ -n "$released" ]]; then
    echo "警告: 次のPVが残っています。harvester StorageClassのPVは既知の問題でReleasedのまま残ることがあります(docs/roadmap.md 項目8の手順で片付ける):" >&2
    echo "$released" >&2
  fi
  rm -rf "$(rh_state_dir "$site")"
  echo "リハーサルサイト ${rh} を削除しました。"
}

# ---------------------------------------------------------------------------
# 本番昇格(docs/runbook/wordpress-update.md「C. 本番へ昇格する」)
# ---------------------------------------------------------------------------

cmd_promote_production() {
  local s started run_id="" pr_url="" i names
  pr_lock_repo
  pr_ensure_clean_worktree
  pr_require_main_uptodate

  # all は本番に既にあるサイトだけ(promote.yamlと同じ)。名前指定ならdevにしか無いサイトの新規追加もできる
  if [[ "$*" == "all" ]]; then
    resolve_sites production all
  else
    resolve_sites dev "$@"
  fi
  local -a changed=() existing=() added=()
  for s in "${SITES[@]}"; do
    if [[ ! -d "envs/dev/sites/$s" ]]; then
      echo "警告: envs/dev/sites/${s} が無いため ${s} はスキップします(promote.yamlも同じ扱い)。" >&2
    elif [[ ! -d "envs/production/sites/$s" ]]; then
      [[ -f "envs/production/secrets/$s.yaml" ]] || die "本番に ${s} を新規追加するには、先に scripts/seal-site-secrets.sh production ${s} でSecretを作り、mainへマージしてください。"
      changed+=("$s")
      added+=("$s")
    elif ! diff -rq "envs/dev/sites/$s" "envs/production/sites/$s" >/dev/null; then
      changed+=("$s")
      existing+=("$s")
    fi
  done
  if [[ ${#changed[@]} -eq 0 ]]; then
    pr_unlock_repo
    echo "devと本番に差分のあるサイトがありません。PRは作成せず、本番の確認だけ行います。"
    cmd_check production "${SITES[@]}"
    return
  fi
  echo "昇格するサイト: ${changed[*]}"
  for s in "${existing[@]}"; do
    diff -u "envs/production/sites/$s/fleet.yaml" "envs/dev/sites/$s/fleet.yaml" | sed 's/^/  /' || true
  done

  if [[ "$*" == "all" ]]; then names="all"; else names="${changed[*]}"; fi
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh workflow run promote.yaml -f kind=sites -f name="$names"
  echo "promoteワークフローを起動しました。実行を待っています..."
  for ((i = 0; i < 30; i++)); do
    run_id="$(gh run list --workflow=promote.yaml --event workflow_dispatch --limit 5 \
      --json databaseId,createdAt -q "[.[] | select(.createdAt >= \"${started}\")] | last | .databaseId // empty")"
    [[ -n "$run_id" ]] && break
    sleep 5
  done
  [[ -n "$run_id" ]] || die "promoteワークフローの実行が見つかりません(gh run list --workflow=promote.yaml)。"
  gh run watch "$run_id" --exit-status >/dev/null || die "promoteワークフローが失敗しました: gh run view ${run_id} --log-failed"
  pr_url="$(gh pr list --state open --search "head:promote/dev-to-production-sites-" --json url,headRefName \
    -q "[.[] | select(.headRefName | endswith(\"-${run_id}\"))][0].url // empty")"
  [[ -n "$pr_url" ]] || die "昇格PRが見つかりません(run ${run_id})。"
  echo "PR作成: ${pr_url}"
  echo "CIチェックを待っています..."
  gh pr checks "$pr_url" --watch || echo "警告: CIチェックが失敗、またはタイムアウトしました: ${pr_url}" >&2
  pr_unlock_repo

  # 本番反映前のバックアップ(必須。docs/operations-flow.md「本番反映前のバックアップ」)。
  # マージ直前に近づけるため、PRができてから取る
  local -A before_rev=()
  local summary=""
  if [[ ${#existing[@]} -gt 0 ]]; then
    echo ""
    echo "=== 本番のバックアップ(マージ前) ==="
    take_backups production "${existing[@]}"
    for s in "${existing[@]}"; do
      before_rev[$s]="$(helm_revision production "$s")"
      summary+="- ${s}: \`backup/production/wordpress-${s}/${BACKUP_TS[$s]}\`"$'\n'
    done
    gh pr comment "$pr_url" --body "$(cat <<EOF
本番バックアップを取得しました(\`scripts/wordpress-pipeline.sh promote-production\`、$(date '+%Y-%m-%d %H:%M'))。

${summary}
このあと長く時間が空いてからマージする場合は、Rundeckの \`wordpress/tools/backup\` で取り直してください。
マージ後の反映確認はパイプラインが続けて行います。
EOF
)" >/dev/null
  fi

  echo ""
  echo "=== PRのdiffが、devで確認した変更(helm.version・pluginsのversion等)だけであることを見てマージしてください ==="
  pr_wait_human_merge "$pr_url" "$MERGE_WAIT_MINUTES"
  pr_lock_repo
  git pull --ff-only origin main
  pr_unlock_repo

  for s in "${existing[@]}"; do wait_site_applied production "$s" "${before_rev[$s]}"; done
  for s in "${added[@]}"; do wait_site_applied production "$s"; done

  echo ""
  echo "=== 本番の確認 ==="
  local failed=0
  cmd_check production "${changed[@]}" || failed=1
  echo ""
  echo "MariaDBのアップグレード状況(イメージを更新したときは、全サイトがイメージの版と同じになっていればよい):"
  for s in "${changed[@]}"; do
    echo "  ${s}: $(kc production -n "wordpress-$s" exec "wordpress-$s-mariadb-0" -c mariadb -- cat /bitnami/mariadb/data/mariadb_upgrade_info 2>/dev/null || echo 不明)"
  done
  [[ $failed -eq 0 ]] || die "本番の確認で問題があります(docs/runbook/troubleshooting.md)。戻すときはマージ前のバックアップから restore-wordpress.sh で。"
  echo "本番への昇格が完了しました: ${changed[*]}"
}

# ---------------------------------------------------------------------------

[[ $# -ge 1 ]] || usage
SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  dev-refresh)        cmd_dev_refresh "$@" ;;
  rehearsal-start)    cmd_rehearsal_start "$@" ;;
  rehearsal-upgrade)  cmd_rehearsal_upgrade "$@" ;;
  rehearsal-cleanup)  cmd_rehearsal_cleanup "$@" ;;
  promote-production) cmd_promote_production "$@" ;;
  backup)
    [[ $# -ge 2 ]] || usage
    env_name="$1"
    shift
    resolve_sites "$env_name" "$@"
    take_backups "$env_name" "${SITES[@]}"
    ;;
  check)
    [[ $# -ge 2 ]] || usage
    env_name="$1"
    shift
    cmd_check "$env_name" "$@"
    ;;
  *) usage ;;
esac
