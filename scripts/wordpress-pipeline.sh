#!/usr/bin/env bash
# WordPressサイトの運用パイプライン。Rundeckの wordpress グループのジョブ
# (rundeck/jobs/wordpress.yaml、docs/manual-rundeck.md)から呼ぶ。手動でも実行できる。
# 手順書の手作業を順につないだもので、各段の内容は次の手順書と同じ:
#   docs/operations-flow.md「stagingでの確認」「本番反映前のバックアップ」
#   docs/manual-wordpress-restore.md「日次バックアップ」「6b.」
#   docs/runbook/wordpress-update.md「C. 本番へ昇格する」
#
# 昇格の流れ: dev → staging(本番データで確認) → production。stagingには確認中のサイトだけを一時的に置き、
# 終わったら消す(staging1のメモリの都合で同時に STAGING_MAX_SITES サイトまで)。
#
# サブコマンド:
#   dev-refresh <site>...            本番の最新コンテンツでdevの同名サイトを上書きする。
#                                    本番のバックアップを今すぐ取る → devの現状をバックアップ →
#                                    リストア → URL置換 → 確認。gitは触らない
#   staging-start <site>             <site>を本番と同じ構成でstagingに置き(stagingだけのPRなのでauto-merge)、
#                                    本番の最新コンテンツを入れて、比較の基準(各ページのHTTPステータス・版)を記録する。
#                                    本番にまだ無い新規サイトはdevの構成で置く(本番データは入れない)
#   staging-upgrade <site>           stagingの<site>をdevの構成(昇格予定の変更)へ切り替え(promoteワークフロー、
#                                    auto-merge)、プラグイン同期Job・DB更新・MariaDBアップグレード・表示を基準と比べる
#   staging-cleanup <site>           stagingの<site>をGitから消し(auto-merge)、namespaceを削除する
#   promote-production <site...|all> stagingから本番への昇格PRを作り、対象サイトの本番バックアップを取ってから
#                                    人がPRをマージするのを待ち(このスクリプトはマージしない)、
#                                    反映後に本番を確認する。all はstagingに載っている、本番にある全サイト
#   backup <env> <site...|all>       日次バックアップのCronJobから今すぐ1つ取る(完了まで待つ)
#   check <env> <site...|all>        各サイトのHTTPステータス(200か)とPodの状態を確認する
#
# 環境変数:
#   NFS_BACKUP_ROOT=<path>    バックアップNFSのマウント先(既定 /mnt/ibid-nfs/backup。
#                             192.168.1.1:/data/nfs を読み取り専用でマウントしておく)
#   FRESH_BACKUP=0            dev-refresh/staging-start で本番のバックアップを新たに取らず、
#                             最新の日次バックアップ(JST 3:00)を使う
#   MERGE_WAIT_MINUTES=<分>   promote-production で人のマージを待つ時間(既定240)
#   STAGING_MAX_SITES=<数>    stagingに同時に置けるサイト数(既定4。staging1のメモリの都合)
#   STAGING_PROJECT_ID=<クラスタID>:<プロジェクトID> staging-start で作るnamespaceを置く、staging1のRancherの
#                             プロジェクト(オペレータが触れるようにする。空ならプロジェクトの外)
#   SEALED_SECRETS_CERT_STAGING=<pem> staging-start で、staging1のSealed Secretsの証明書を取りに行けないとき
#                             に使う公開証明書(既定 /var/lib/ibid-fleet-config/sealed-secrets-staging1.pem)
#
# 実行する人の権限が足りないときの動き(Rundeckのオペレータ。docs/manual-rundeck.md「WordPressのオペレータ」):
#   - 本番でJobを作れない(prod1がRead-only): 今すぐのバックアップは取らず、dev-refresh・staging-start は
#     最新の日次バックアップを使う。promote-production は「マージ前に管理者がバックアップを取る」とPRに書いて待つ
#   - 本番のSecret(Helmの履歴)を読めない: 反映はHelmのリビジョンでなく、一定時間待ってからrolloutで確かめる
#   - kube-systemのSealed Secretsに届かない: SEALED_SECRETS_CERT_STAGING の証明書で封印する
#
# 前提: gh CLIが認証済み、kubectl/kubesealのコンテキスト dev1/staging1/prod1 が ~/.kube/config にあること
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
STAGING_MAX_SITES="${STAGING_MAX_SITES:-4}"
# stagingでの比較の基準。始めた人と続きを実行する人が違ってもよいよう、ユーザー間で共有する
# (FreeIPAのグループ wpadmins で書けるsetgidディレクトリ。docs/manual-rundeck.md「実行アカウント」)。
# パスはdev1のリハーサルサイト時代(〜2026-10-25)のものをそのまま使う
STATE_ROOT="${STAGING_STATE_ROOT:-/var/lib/ibid-fleet-config/rehearsal}"
SEALED_SECRETS_CERT_STAGING="${SEALED_SECRETS_CERT_STAGING:-/var/lib/ibid-fleet-config/sealed-secrets-staging1.pem}"

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
    staging) echo "staging1" ;;
    production) echo "prod1" ;;
    *) die "envは dev / staging / production のいずれかを指定してください: $1" ;;
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

# 引数(サイト名の並び、または all)を SITES 配列に展開する。all はその環境の全サイト。
resolve_sites() {
  local env="$1" s d
  shift
  SITES=()
  [[ $# -gt 0 ]] || die "サイト名を指定してください(複数可。all で全サイト)。"
  if [[ "$*" == "all" ]]; then
    for d in "envs/$env/sites/"*/; do
      SITES+=("$(basename "$d")")
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

# 実行している人がその操作をできるか(kubectl auth can-i)。引数: <env> <kubectl auth can-i の引数...>
can_i() {
  local env="$1"
  shift
  kc "$env" auth can-i "$@" >/dev/null 2>&1
}

# 本番で今すぐのバックアップ(CronJobからJobを作る)ができるか。対象サイトのnamespaceで確かめる
can_take_backups() {
  local env="$1" s
  shift
  for s in "$@"; do
    can_i "$env" create jobs.batch -n "wordpress-$s" || return 1
  done
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
  if ! can_i "$env" get secrets -n "$ns"; then
    # Helmの履歴(Secret)を読めない(本番がRead-onlyのオペレータ)。Fleetが拾って適用し始めるまでの
    # 時間を待ってから、rolloutの完了で確かめる(リビジョンの比較より粗い)
    echo "(Helmの履歴を読む権限が無いため、${FLEET_APPLY_WAIT:-180}秒待ってからrolloutで確かめます)"
    sleep "${FLEET_APPLY_WAIT:-180}"
    kc "$env" -n "$ns" rollout status "statefulset/wordpress-$site-mariadb" --timeout=20m
    kc "$env" -n "$ns" rollout status "deploy/wordpress-$site" --timeout=20m
    return
  fi
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
    # 接続できないときもcurlは -w で 000 を出力して失敗する(|| echo 000 だと 000000 になる)
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "$url" || true)"
    code="${code:-000}"
    # Terminating は入れ替え直後の古いPodの終了処理中で、異常ではない
    bad="$(kc "$env" -n "wordpress-$s" get pods --no-headers 2>/dev/null | grep -v -E 'Running|Completed|Terminating' || true)"
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

# cmd_check を、通るまで何回か間を空けてやり直す。Podの入れ替え直後は、古いPodの終了処理中に
# Ingress(Traefik)が一時的に502を返すことがあるため(2026-10-20、jmcの本番昇格で発生)。
# 引数: <env> <site...>
check_with_retry() {
  local env="$1" i tries="${CHECK_RETRIES:-6}"
  shift
  for ((i = 1; i <= tries; i++)); do
    if cmd_check "$env" "$@"; then
      return 0
    fi
    if (( i < tries )); then
      echo "(入れ替え直後の一時的な応答の可能性があるため、30秒後にもう一度確認します: ${i}/${tries})"
      sleep 30
    fi
  done
  return 1
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

# 本番<src_site>のバックアップ(時刻<ts>)を <dst_env> の<dst_site>へリストアし、URLを置換する
restore_from_production() {
  local src_site="$1" dst_env="$2" dst_site="$3" ts="$4"
  echo ""
  echo "=== リストア: production/${src_site}(${ts}) → ${dst_env}/${dst_site} ==="
  # (dev-refreshではサブシェル内のif条件として呼ばれ set -e が効かないため、各段で明示的に止める)
  KUBE_CONTEXT="$(context_for_env "$dst_env")" IBID_ASSUME_YES=1 "$SCRIPT_DIR/restore-wordpress.sh" \
    "$dst_site" "$(backup_dir production "$src_site")" "$ts" || return 1
  # Podの入れ替え中に置換すると途中で切れるため、落ち着いてから行う(6b.参照)
  kc "$dst_env" -n "wordpress-$dst_site" rollout status "deploy/wordpress-$dst_site" --timeout=10m || return 1
  replace_urls "$dst_env" "$dst_site" || return 1
}

# 本番データのバックアップの時刻をサイトごとに決める(FRESH_BACKUP=1なら今すぐ取る)
prepare_production_backups() {
  local s
  if [[ "$FRESH_BACKUP" == "1" ]] && ! can_take_backups production "$@"; then
    echo "注意: 本番でバックアップのJobを作る権限が無いため、今すぐのバックアップは取らず、最新の日次バックアップを使います。"
    FRESH_BACKUP=0
  fi
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
    if ! (restore_from_production "$s" dev "$s" "$ts"); then
      echo "エラー: dev/${s} のリストアに失敗しました。上書き前のバックアップ: $(backup_dir dev "$s")/${BACKUP_TS[$s]}" >&2
      failed+=("$s")
      continue
    fi
    if check_with_retry dev "$s"; then
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
# staging(検証中のサイトを一時的に置く。docs/operations-flow.md「stagingでの確認」)
# ---------------------------------------------------------------------------

stg_state_dir() { echo "$STATE_ROOT/staging-$1"; }

# 基準のディレクトリへ書けることを確かめる(他のオペレータも上書きできるよう、グループ書き込み可で作る)
stg_require_state_root() {
  [[ -d "$STATE_ROOT" && -w "$STATE_ROOT" ]] || die "stagingの比較の基準の置き場所 ${STATE_ROOT} がない、または書き込めません。
  sudo install -d -m 2775 -g wpadmins ${STATE_ROOT}   # 実行するユーザーをグループ wpadmins に入れておく
(docs/manual-rundeck.md「実行アカウント」)"
  umask 002
}

# stagingのサイトがHTTPで応答する(000以外を返す)まで待つ。置いた直後は証明書の発行中で、DNS-01の
# _acme-challengeのTXTがある間は <site>.staging.ibid.lan にワイルドカードが効かず名前が引けない
# (この端末のDNSが否定応答をキャッシュすることもある)。待たずに基準を記録すると 000 になり、
# 比較で「変わったページ」と誤判定される(2026-10-26、pmsで発生)。
stg_wait_reachable() {
  local site="$1" url code i
  url="$(site_url staging "$site")"
  for ((i = 0; i < 40; i++)); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$url" || true)"
    [[ -n "$code" && "$code" != "000" ]] && return 0
    sleep 15
  done
  echo "警告: 10分待っても ${url} に接続できません(証明書・DNSを確認してください)。基準はこのまま記録します。" >&2
}

# stagingのサイトの状態を記録する(<dir>/<name>-info.txt と <name>-pages.txt)。
# ページの一覧は基準の記録時(before)に作り、以降は同じページを見る。
stg_snapshot() {
  local site="$1" name="$2" dir url path code base
  dir="$(stg_state_dir "$site")"
  mkdir -p "$dir"
  {
    echo "WordPress: $(wp_cli staging "$site" core version 2>/dev/null || echo 不明)"
    echo "MariaDB(mariadb_upgrade_info): $(kc staging -n "wordpress-$site" exec "wordpress-$site-mariadb-0" -c mariadb -- cat /bitnami/mariadb/data/mariadb_upgrade_info 2>/dev/null || echo なし)"
    echo "テーマ: $(wp_cli staging "$site" theme list --status=active --field=name 2>/dev/null | tr '\n' ' ')"
    echo "プラグイン(name,status,version):"
    { wp_cli staging "$site" plugin list --fields=name,status,version --format=csv 2>/dev/null || printf 'header\n(取得失敗)\n'; } | tail -n +2 | sed 's/^/  /'
  } >"$dir/$name-info.txt"

  if [[ ! -f "$dir/paths.txt" ]]; then
    {
      echo "/"
      { wp_cli staging "$site" post list --post_type=post,page --post_status=publish --posts_per_page=10 \
        --orderby=modified --field=url 2>/dev/null || true; } | sed -E 's#^[a-z]+://[^/]+##'
    } | sort -u >"$dir/paths.txt"
  fi
  # site_url は https://<host><sitePath>/ 。記事のURLはsitePathを含むので、ホストまでを使う
  base="$(site_url staging "$site" | sed -E 's#^(https://[^/]+).*#\1#')"
  : >"$dir/$name-pages.txt"
  while read -r path; do
    if [[ "$path" == "/" ]]; then url="$(site_url staging "$site")"; else url="${base}${path}"; fi
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 "$url" || true)"
    code="${code:-000}"
    echo "$code $path" >>"$dir/$name-pages.txt"
  done <"$dir/paths.txt"
  echo "--- ${name}: $(head -2 "$dir/$name-info.txt" | tr '\n' ' ')"
  sed 's/^/  /' "$dir/$name-pages.txt"
}

# stagingに今載っているサイト(envs/staging/sites/ のディレクトリ)
staging_sites() {
  local d
  for d in envs/staging/sites/*/; do
    [[ -d "$d" ]] && basename "$d"
  done
}

# staging1のメモリの都合で、同時に載せるサイト数に上限を設ける(既定4。STAGING_MAX_SITES)
stg_require_capacity() {
  local -a current
  mapfile -t current < <(staging_sites)
  if (( ${#current[@]} >= STAGING_MAX_SITES )); then
    die "stagingには既に ${#current[@]} サイトあります(${current[*]})。staging1のメモリの都合で同時に置けるのは${STAGING_MAX_SITES}サイトまでです。
確認の終わったサイトを staging-cleanup してください。"
  fi
}

# promoteワークフローを起動し、作られたPRのURLを PROMOTE_PR_URL に入れる。差分が無くPRが作られなかったときは空。
# 引数: <kind> <to> <name...|all>
run_promote() {
  local kind="$1" to="$2" names="$3" started run_id="" i from
  case "$to" in staging) from=dev ;; production) from=staging ;; esac
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh workflow run promote.yaml -f kind="$kind" -f to="$to" -f name="$names"
  echo "promoteワークフロー(${from}→${to})を起動しました。実行を待っています..."
  for ((i = 0; i < 30; i++)); do
    run_id="$(gh run list --workflow=promote.yaml --event workflow_dispatch --limit 5 \
      --json databaseId,createdAt -q "[.[] | select(.createdAt >= \"${started}\")] | last | .databaseId // empty")"
    [[ -n "$run_id" ]] && break
    sleep 5
  done
  [[ -n "$run_id" ]] || die "promoteワークフローの実行が見つかりません(gh run list --workflow=promote.yaml)。"
  gh run watch "$run_id" --exit-status >/dev/null || die "promoteワークフローが失敗しました: gh run view ${run_id} --log-failed"
  PROMOTE_PR_URL="$(gh pr list --state all --search "head:promote/${from}-to-${to}-${kind}-" --json url,headRefName \
    -q "[.[] | select(.headRefName | endswith(\"-${run_id}\"))][0].url // empty")"
  if [[ -n "$PROMOTE_PR_URL" ]]; then
    echo "PR作成: ${PROMOTE_PR_URL}"
    pr_comment_actor "$PROMOTE_PR_URL"
  fi
}

# auto-mergeを設定したPR(stagingだけに触れるもの)のマージを待つ。引数: <pr_url>
wait_automerged() {
  local pr_url="$1" i state
  echo "auto-mergeを待っています: ${pr_url}"
  for ((i = 0; i < 90; i++)); do
    state="$(gh pr view "$pr_url" --json state -q .state)"
    case "$state" in
      MERGED) echo "マージされました。"; return 0 ;;
      CLOSED) die "PRがマージされずにcloseされました: ${pr_url}" ;;
    esac
    sleep 10
  done
  die "15分待ってもマージされませんでした(validateの失敗等を確認してください): ${pr_url}"
}

cmd_staging_start() {
  [[ $# -eq 1 ]] || usage
  local site="$1" ts from
  check_site_name "$site"
  [[ -d "envs/dev/sites/$site" ]] || die "envs/dev/sites/${site} がありません(変更は必ずdevから入れる)。"
  if [[ -d "envs/production/sites/$site" ]]; then
    from=production
    require_nfs
  else
    from=dev
  fi
  stg_require_state_root

  pr_lock_repo
  pr_ensure_clean_worktree
  pr_require_main_uptodate
  [[ -d "envs/staging/sites/$site" ]] && die "envs/staging/sites/${site} は既にあります。続きは staging-upgrade、作り直すなら staging-cleanup してから実行してください。"
  stg_require_capacity

  git checkout -b "staging/${site}-start-$(date +%Y%m%d%H%M%S)"
  # 本番にあるサイトは本番と同じ構成で置き(このあと本番データを入れて基準を記録する)、
  # 本番にまだ無い新規サイトはdevの構成で置く
  cp -r "envs/$from/sites/$site" "envs/staging/sites/$site"
  # stagingのSecretは毎回新しいパスワードで作る(片付けで消す)。オペレータがstaging1で触れるよう、
  # STAGING_PROJECT_ID があればRancherのプロジェクトに置く
  local -a seal_env=(SEAL_HIDE_PASSWORDS=1 NAMESPACE_PROJECT_ID="${STAGING_PROJECT_ID:-}")
  if ! can_i staging get services/proxy -n kube-system; then
    [[ -r "$SEALED_SECRETS_CERT_STAGING" ]] || die "staging1のSealed Secretsの証明書を取りに行く権限が無く、証明書ファイル ${SEALED_SECRETS_CERT_STAGING} もありません。
管理者に置いてもらってください: kubeseal --context staging1 --fetch-cert | sudo tee ${SEALED_SECRETS_CERT_STAGING}"
    seal_env+=(SEALED_SECRETS_CERT="$SEALED_SECRETS_CERT_STAGING")
  fi
  env "${seal_env[@]}" "$SCRIPT_DIR/seal-site-secrets.sh" staging "$site"
  git add "envs/staging/sites/$site" "envs/staging/secrets/$site.yaml"
  pr_commit_push_create \
    "chore: 確認のため${site}をstagingへ追加" \
    "$(cat <<EOF
## 内容
\`scripts/wordpress-pipeline.sh staging-start ${site}\` で作成。\`envs/${from}/sites/${site}\` と同じ構成で
\`${site}\` をstaging1に置きます(docs/operations-flow.md「stagingでの確認」)。
$([[ "$from" == production ]] && echo "このあと本番の最新コンテンツをリストアし、比較の基準を記録します。")

確認が終わったら \`staging-cleanup ${site}\` で削除します。
EOF
)"
  pr_automerge_and_wait "$PR_URL"
  pr_unlock_repo

  wait_site_applied staging "$site"
  rm -f "$(stg_state_dir "$site")"/*

  if [[ "$from" == production ]]; then
    echo ""
    echo "=== 本番のバックアップ ==="
    prepare_production_backups "$site"
    ts="${BACKUP_TS[$site]}"
    restore_from_production "$site" staging "$site" "$ts"
    kc staging -n "wordpress-$site" exec "deploy/wordpress-$site" -c wordpress -- rm -rf /bitnami/wordpress/wp-content.orig
    echo ""
    echo "=== 比較の基準(本番と同じ構成・本番データ)を記録します ==="
    stg_wait_reachable "$site"
    stg_snapshot "$site" before
    echo "production/${site} ${ts}" >"$(stg_state_dir "$site")/source.txt"
    echo ""
    echo "stagingに本番と同じ構成・本番データで用意しました: $(site_url staging "$site")"
    echo "続けて staging-upgrade ${site} でdevの構成(昇格予定の変更)へ切り替えます。"
  else
    echo ""
    echo "=== 状態を記録します(本番にまだ無い新規サイトのため、本番データは入れない) ==="
    stg_wait_reachable "$site"
    stg_snapshot "$site" before
    echo ""
    echo "新規サイトをdevの構成でstagingに置きました: $(site_url staging "$site")"
    echo "確認できたら promote-production ${site} で本番へ追加します(先に scripts/seal-site-secrets.sh production ${site})。"
  fi
}

cmd_staging_upgrade() {
  [[ $# -eq 1 ]] || usage
  local site="$1" dir before_rev merged_at job_line job_created job failed=0 secs
  check_site_name "$site"
  stg_require_state_root
  dir="$(stg_state_dir "$site")"
  [[ -d "envs/staging/sites/$site" ]] || die "envs/staging/sites/${site} がありません。先に staging-start ${site} を実行してください。"
  [[ -f "$dir/before-pages.txt" ]] || echo "警告: 比較の基準(${dir}/before-pages.txt)がありません。比較はせず現状だけ表示します。" >&2

  pr_lock_repo
  pr_ensure_clean_worktree
  pr_require_main_uptodate
  if diff -rq "envs/dev/sites/$site" "envs/staging/sites/$site" >/dev/null; then
    pr_unlock_repo
    echo "devとstagingの ${site} の構成に差分がありません(昇格予定の変更が無い、または切り替え済み)。"
    return 0
  fi
  echo "適用する変更(stagingの構成 → devの構成):"
  diff -ru "envs/staging/sites/$site" "envs/dev/sites/$site" | sed 's/^/  /' || true
  before_rev="$(helm_revision staging "$site")"
  merged_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  pr_unlock_repo

  # dev→stagingの昇格はpromoteワークフローで行う(stagingだけのPRなのでauto-merge)
  run_promote sites staging "$site"
  [[ -n "$PROMOTE_PR_URL" ]] || die "昇格PRが見つかりません。"
  wait_automerged "$PROMOTE_PR_URL"
  pr_lock_repo
  git pull --ff-only origin main
  pr_unlock_repo

  SECONDS=0
  wait_site_applied staging "$site" "$before_rev"
  echo "適用にかかった時間: ${SECONDS}秒"

  echo ""
  echo "=== プラグイン同期Job ==="
  job=""
  for ((secs = 0; secs < 300; secs += 15)); do
    job_line="$(kc staging -n "wordpress-$site" get jobs -l app.kubernetes.io/component=plugin-sync \
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
  elif wait_job staging "wordpress-$site" "$job" 1200; then
    echo "成功: job/${job}(所要時間: $(kc staging -n "wordpress-$site" get job "$job" -o go-template='{{.status.startTime}} → {{.status.completionTime}}'))"
    kc staging -n "wordpress-$site" logs "job/$job" --tail=20 | sed 's/^/  /'
  else
    failed=1
  fi

  echo ""
  echo "=== WordPressのDB更新(管理画面の「データベースの更新が必要です」に相当) ==="
  SECONDS=0
  wp_cli staging "$site" core update-db 2>&1 | tail -3 | sed 's/^/  /' || failed=1
  echo "所要時間: ${SECONDS}秒"

  echo ""
  echo "=== 切り替え後の状態 ==="
  stg_snapshot "$site" after

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
  kc staging -n "wordpress-$site" logs "deploy/wordpress-$site" -c wordpress --since=1h 2>/dev/null \
    | grep -iE 'PHP (Fatal|Parse|Warning)|Uncaught' | tail -30 | sed 's/^/  /' || echo "  なし"

  echo ""
  echo "stagingのサイト: $(site_url staging "$site")"
  echo "表示・管理画面・プラグイン固有の画面をブラウザでも確認し、結果(所要時間・気づいた点)を昇格PRに書いてください。"
  echo "問題なければ promote-production ${site} で本番へ昇格し、終わったら staging-cleanup ${site} で削除します。"
  [[ $failed -eq 0 ]] || die "stagingで問題が見つかりました(上の出力を確認してください)。devで修正して staging-upgrade をやり直せます。"
}

cmd_staging_cleanup() {
  [[ $# -eq 1 ]] || usage
  local site="$1" paths=()
  check_site_name "$site"

  pr_lock_repo
  pr_ensure_clean_worktree
  pr_require_main_uptodate
  if [[ -d "envs/staging/sites/$site" && -d "envs/production/sites/$site" ]] \
      && ! diff -rq "envs/staging/sites/$site" "envs/production/sites/$site" >/dev/null; then
    echo "注意: stagingの ${site} の構成は本番へまだ昇格していません(昇格するなら、削除の前に promote-production ${site})。" >&2
  fi
  [[ -d "envs/staging/sites/$site" ]] && paths+=("envs/staging/sites/$site")
  [[ -f "envs/staging/secrets/$site.yaml" ]] && paths+=("envs/staging/secrets/$site.yaml")
  if [[ ${#paths[@]} -gt 0 ]]; then
    git checkout -b "staging/${site}-cleanup-$(date +%Y%m%d%H%M%S)"
    git rm -r -q "${paths[@]}"
    pr_commit_push_create \
      "chore: 確認の終わった${site}をstagingから削除" \
      "\`scripts/wordpress-pipeline.sh staging-cleanup ${site}\` で作成。マージ後、同スクリプトがstaging1の \`wordpress-${site}\` namespaceを削除します(\`keepResources: true\` のためGitの削除だけでは消えない)。"
    pr_automerge_and_wait "$PR_URL"
  else
    echo "Git側には ${site} がありません(削除済み)。"
  fi
  pr_unlock_repo

  # マージ後に消す(先に消すとFleetが作り直す)。本番データのコピーが入っているので必ず消す。
  # stagingのStorageClassはDeleteなので、NFS上のwp-content・バックアップも一緒に消える
  if kc staging get namespace "wordpress-$site" >/dev/null 2>&1; then
    echo "namespace wordpress-${site} を削除します(PVCも削除されます)..."
    kc staging delete namespace "wordpress-$site" --wait=true --timeout=15m
  fi
  # PV(NFSのディレクトリ・Harvesterのボリューム)の削除はPVCの削除より少し遅れるので、消えるまで待つ
  local released i
  for ((i = 0; i < 36; i++)); do
    released="$(kc staging get pv --no-headers 2>/dev/null | grep "wordpress-$site/" || true)"
    [[ -z "$released" ]] && break
    sleep 5
  done
  if [[ -n "$released" ]]; then
    echo "警告: 3分待っても次のPVが残っています(docs/runbook/troubleshooting.md「PV が Released のまま残る」):" >&2
    echo "$released" >&2
  fi
  rm -rf "$(stg_state_dir "$site")"
  echo "stagingから ${site} を削除しました。"
}

# ---------------------------------------------------------------------------
# 本番昇格(docs/runbook/wordpress-update.md「C. 本番へ昇格する」)
# ---------------------------------------------------------------------------

cmd_promote_production() {
  local s names pr_url
  pr_lock_repo
  pr_ensure_clean_worktree
  pr_require_main_uptodate

  # 本番へはstagingを通す。all は本番に既にあり、かつstagingに載っているサイト(promote.yamlと同じ)。
  # 名前指定ならstagingにしか無いサイト(新規)の本番への追加もできる
  local -a targets=()
  if [[ "$*" == "all" ]]; then
    resolve_sites production all
    for s in "${SITES[@]}"; do
      [[ -d "envs/staging/sites/$s" ]] && targets+=("$s")
    done
    [[ ${#targets[@]} -gt 0 ]] || { pr_unlock_repo; die "本番にあるサイトのうち、stagingに載っているものがありません(先に staging-start)。"; }
    echo "stagingに載っていないサイトは対象外です(stagingに載っているもの: ${targets[*]})。"
  else
    for s in "$@"; do
      check_site_name "$s"
      [[ -d "envs/staging/sites/$s" ]] || { pr_unlock_repo; die "stagingに ${s} がありません。本番へはstagingで確認してから昇格します(staging-start ${s})。"; }
      targets+=("$s")
    done
  fi
  local -a changed=() existing=() added=()
  for s in "${targets[@]}"; do
    if [[ ! -d "envs/production/sites/$s" ]]; then
      [[ -f "envs/production/secrets/$s.yaml" ]] || { pr_unlock_repo; die "本番に ${s} を新規追加するには、先に scripts/seal-site-secrets.sh production ${s} でSecretを作り、mainへマージしてください。"; }
      changed+=("$s")
      added+=("$s")
    elif ! diff -rq "envs/staging/sites/$s" "envs/production/sites/$s" >/dev/null; then
      changed+=("$s")
      existing+=("$s")
    fi
    if [[ -d "envs/dev/sites/$s" ]] && ! diff -rq "envs/dev/sites/$s" "envs/staging/sites/$s" >/dev/null; then
      echo "注意: devの ${s} にはstagingで未確認の変更があります(昇格するのはstagingの内容。devの変更も入れるなら先に staging-upgrade ${s})。" >&2
    fi
  done
  pr_unlock_repo
  if [[ ${#changed[@]} -eq 0 ]]; then
    echo "stagingと本番に差分のあるサイトがありません。PRは作成せず、本番の確認だけ行います。"
    cmd_check production "${targets[@]}"
    return
  fi
  echo "昇格するサイト: ${changed[*]}"
  for s in "${existing[@]}"; do
    diff -u "envs/production/sites/$s/fleet.yaml" "envs/staging/sites/$s/fleet.yaml" | sed 's/^/  /' || true
  done

  if [[ "$*" == "all" ]]; then names="all"; else names="${changed[*]}"; fi
  run_promote sites production "$names"
  pr_url="$PROMOTE_PR_URL"
  [[ -n "$pr_url" ]] || die "昇格PRが見つかりません。"
  echo "CIチェックを待っています..."
  gh pr checks "$pr_url" --watch || echo "警告: CIチェックが失敗、またはタイムアウトしました: ${pr_url}" >&2

  # 本番反映前のバックアップ(必須。docs/operations-flow.md「本番反映前のバックアップ」)。
  # マージ直前に近づけるため、PRができてから取る
  local -A before_rev=()
  local summary=""
  if [[ ${#existing[@]} -gt 0 ]]; then
    echo ""
    echo "=== 本番のバックアップ(マージ前) ==="
    for s in "${existing[@]}"; do before_rev[$s]="$(helm_revision production "$s")"; done
    if can_take_backups production "${existing[@]}"; then
      take_backups production "${existing[@]}"
      for s in "${existing[@]}"; do
        summary+="- ${s}: \`backup/production/wordpress-${s}/${BACKUP_TS[$s]}\`"$'\n'
      done
      gh pr comment "$pr_url" --body "$(cat <<EOF
本番バックアップを取得しました(\`scripts/wordpress-pipeline.sh promote-production\`、$(date '+%Y-%m-%d %H:%M'))。

${summary}
このあと長く時間が空いてからマージする場合は、Rundeck(WordPressControl)の \`tools/backup\` で取り直してください。
マージ後の反映確認はパイプラインが続けて行います。
EOF
)" >/dev/null
    else
      # 本番がRead-onlyのオペレータ。バックアップは承認する管理者がマージの直前に取る
      echo "本番でバックアップのJobを作る権限が無いため、バックアップは取りません。"
      echo "承認する管理者が、マージの直前に本番のバックアップを取る必要があります(PRにコメントしました)。"
      gh pr comment "$pr_url" --body "$(cat <<EOF
**本番バックアップは未取得です**(実行者に本番でJobを作る権限が無いため)。

承認する方は、**マージの直前に**次のサイトの本番バックアップを取ってから Approve・マージしてください
(Rundeck(WordPressControl)の \`tools/backup\`、\`env=production\`、サイト: ${existing[*]})。
マージ後の反映確認はパイプラインが続けて行います。
EOF
)" >/dev/null
    fi
  fi

  echo ""
  echo "=== PRのdiffが、stagingで確認した変更(helm.version・pluginsのversion等)だけであることを見てマージしてください ==="
  pr_wait_human_merge "$pr_url" "$MERGE_WAIT_MINUTES"
  pr_lock_repo
  git pull --ff-only origin main
  pr_unlock_repo

  for s in "${existing[@]}"; do wait_site_applied production "$s" "${before_rev[$s]}"; done
  for s in "${added[@]}"; do wait_site_applied production "$s"; done

  echo ""
  echo "=== 本番の確認 ==="
  local failed=0
  check_with_retry production "${changed[@]}" || failed=1
  echo ""
  echo "MariaDBのアップグレード状況(イメージを更新したときは、全サイトがイメージの版と同じになっていればよい):"
  for s in "${changed[@]}"; do
    echo "  ${s}: $(kc production -n "wordpress-$s" exec "wordpress-$s-mariadb-0" -c mariadb -- cat /bitnami/mariadb/data/mariadb_upgrade_info 2>/dev/null || echo 不明)"
  done
  [[ $failed -eq 0 ]] || die "本番の確認で問題があります(docs/runbook/troubleshooting.md)。戻すときはマージ前のバックアップから restore-wordpress.sh で。"
  echo "本番への昇格が完了しました: ${changed[*]}"
  echo "stagingの片付け: 各サイトで staging-cleanup <site>(staging1のメモリを空けるため、確認が済んだら必ず行う)。"
}

# ---------------------------------------------------------------------------

[[ $# -ge 1 ]] || usage
SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  dev-refresh)        cmd_dev_refresh "$@" ;;
  staging-start)      cmd_staging_start "$@" ;;
  staging-upgrade)    cmd_staging_upgrade "$@" ;;
  staging-cleanup)    cmd_staging_cleanup "$@" ;;
  promote-production) cmd_promote_production "$@" ;;
  backup)
    [[ $# -ge 2 ]] || usage
    env_name="$1"
    shift
    resolve_sites "$env_name" "$@"
    can_take_backups "$env_name" "${SITES[@]}" \
      || die "${env_name}でバックアップのJobを作る権限がありません(本番は管理者が実行してください)。"
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
