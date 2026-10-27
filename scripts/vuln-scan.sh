#!/usr/bin/env bash
# アプリ・WordPressサイトの脆弱性チェック(docs/manual-vuln-scan.md)。
# 動いているイメージをTrivyで検査し(OS・ランタイム・npm/gem等)、サイトはwp-cliで取ったコア・
# プラグイン・テーマの版をWordfence Intelligenceのフィードと照らし合わせる。ランタイムのEOLも見る。
# 判定の基準と除外は qa/vuln-policy.yaml(判定そのものは scripts/lib/vuln_report.py)。
#
# 使い方: scripts/vuln-scan.sh [--notify] <env> <apps|sites> <name...|all>
#   例: scripts/vuln-scan.sh staging apps riken-diips
#       scripts/vuln-scan.sh --notify production sites all   # 週次(Rundeckの tools/vuln-scan)
#
# env=staging では、結果(合否だけ)をcommit status vuln/<kind>/<name> として scripts/qa.sh と同じコミットに
# 記録する(scripts/lib/qa_status.sh)。stagingのQA(scripts/qa.sh)からも呼ばれる。
# --notify は結果をSlackへ送る。前回(同じ env・kind の前回の --notify)から新しく見つかったものを強調する。
# 詳細(パッケージ名・CVE)は標準出力(Rundeckのログ)とSlackにだけ出す。このリポジトリはpublicなので、
# GitHub(commit status・Actionsのログ)には出さない。
#
# 終了コード: qa/vuln-policy.yaml の enforce が true で、NG(または検査できないもの)があれば1。
# false の間は、NGがあっても0(記録・通知だけ)。
#
# 環境変数:
#   QA_NO_STATUS=1  stagingでも結果をGitHubに記録しない
#
# 認証情報(このホストの実行ユーザーのファイル。権限600。置き方は docs/manual-vuln-scan.md「準備」):
#   ~/.config/ibid-fleet-config/slack-webhook      Slack Incoming WebhookのURL(--notify 用)
#   ~/.config/ibid-fleet-config/wordfence-api-key  Wordfence IntelligenceのAPIキー(無ければWordPressの検査を飛ばす)
#   ~/.config/ibid-fleet-config/ghcr-read-token    非公開のGHCRイメージ(member-gateway)を読むトークン(read:packages)
#
# 前提: docker(dockerグループ)、kubectlのコンテキスト dev1/staging1/prod1、gh CLI、python3とPyYAML、curl。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Trivy はタグでなくdigestで固定する(スキャナ自体を意図せず差し替えられないように)。上げるときは
# リリースノートを確認してから、タグとdigestを一緒に変える。脆弱性DBは実行のたびに最新を取る
TRIVY_IMAGE="docker.io/aquasec/trivy:0.65.0@sha256:a22415a38938a56c379387a8163fcb0ce38b10ace73e593475d3658d578b2436"
WORDFENCE_FEED="https://www.wordfence.com/api/intelligence/v3/vulnerabilities/scanner"
WP_PATH="/opt/bitnami/wordpress"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ibid-fleet-config"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ibid-fleet-config/vuln"

die() { echo "エラー: $*" >&2; exit 1; }
usage() { die "使い方: $0 [--notify] <dev|staging|production> <apps|sites> <name...|all>"; }

NOTIFY=0
if [[ "${1:-}" == --notify ]]; then
  NOTIFY=1
  shift
fi
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

docker info >/dev/null 2>&1 || die "dockerを使えません(実行ユーザーを docker グループに入れ、ログインし直す。docs/manual-vuln-scan.md「準備」)。"
if [[ $NOTIFY -eq 1 && ! -s "$CONF_DIR/slack-webhook" ]]; then
  die "--notify には $CONF_DIR/slack-webhook(SlackのWebhook URL)が要ります(docs/manual-vuln-scan.md「準備」)。"
fi

ENFORCE=0
grep -qE '^enforce:[[:space:]]*true' qa/vuln-policy.yaml && ENFORCE=1

kc() { kubectl --context "$CTX" "$@"; }

# shellcheck source=lib/qa_status.sh
source "$SCRIPT_DIR/lib/qa_status.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$CACHE_DIR"
chmod 700 "$WORK" "$CACHE_DIR"

# 非公開のGHCRイメージ用(Trivyはレジストリから直接読むので、docker loginではなく環境変数で渡す)
TRIVY_ENV=()
if [[ -s "$CONF_DIR/ghcr-read-token" ]]; then
  TRIVY_USERNAME="$(gh api user --jq .login 2>/dev/null || echo ibid)"
  TRIVY_PASSWORD="$(tr -d '[:space:]' < "$CONF_DIR/ghcr-read-token")"
  export TRIVY_USERNAME TRIVY_PASSWORD
  TRIVY_ENV=(-e TRIVY_USERNAME -e TRIVY_PASSWORD)
fi

# namespaceで動いているイメージ(Deployment・StatefulSet・DaemonSet・CronJob。initContainersを含む)
images_of() {
  kc -n "$1" get deploy,statefulset,daemonset,cronjob -o json | python3 -I -c '
import json, sys
seen = []
for o in json.load(sys.stdin)["items"]:
    spec = o["spec"]
    pod = spec["jobTemplate"]["spec"]["template"]["spec"] if o["kind"] == "CronJob" else spec["template"]["spec"]
    for c in pod.get("initContainers", []) + pod.get("containers", []):
        if c["image"] not in seen:
            seen.append(c["image"])
print("\n".join(seen))'
}

# イメージをTrivyで検査して結果のJSONのパスを返す。同じ実行の中では1回だけ検査する(サイトは同じイメージが多い)。
# --list-all-pkgs はBitnamiの部品(PHP・MariaDB)の版をEOLの確認に使うため
scan_image() {
  local img="$1" f
  f="$WORK/trivy-$(sha1sum <<<"$img" | cut -c1-16).json"
  if [[ ! -s "$f" && ! -e "$f.err" ]]; then
    echo "    Trivy: ${img} ..." >&2
    docker run --rm "${TRIVY_ENV[@]}" -v ibid-trivy-cache:/root/.cache "$TRIVY_IMAGE" \
      image --quiet --scanners vuln --list-all-pkgs --timeout 15m --format json "$img" >"$f" 2>"$f.log" || { mv "$f.log" "$f.err"; rm -f "$f"; }
  fi
  [[ -s "$f" ]] && echo "$f"
  return 0
}

# Wordfenceのフィード(12時間キャッシュ)。キーが無い・取れなければ空を返す
WORDFENCE=""
wordfence_feed() {
  local key="$CONF_DIR/wordfence-api-key" cache="$CACHE_DIR/wordfence-scanner.json"
  [[ -s "$key" ]] || return 0
  if [[ ! -s "$cache" || -n "$(find "$cache" -mmin +720 2>/dev/null)" ]]; then
    # キーをコマンドラインに出さないよう、ヘッダはファイルで渡す
    printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$key")" >"$WORK/wf-header"
    if curl -fsS --compressed --max-time 600 -H @"$WORK/wf-header" -o "$cache.tmp" "$WORDFENCE_FEED"; then
      mv "$cache.tmp" "$cache"
    else
      rm -f "$cache.tmp"
      echo "警告: Wordfenceのフィードを取得できませんでした$([[ -s "$cache" ]] && echo '(前回の分を使います)')。" >&2
    fi
    rm -f "$WORK/wf-header"
  fi
  [[ -s "$cache" ]] && echo "$cache"
  return 0
}

# サイトのコア・プラグイン・テーマの版(wp-cli)。プラグイン・テーマのコードは読み込まない(警告が出力に混ざるため)
wp_inventory() {
  local site="$1" out="$2" ns="wordpress-$1"
  local -a wp=(kc -n "$ns" exec "deploy/wordpress-$site" -c wordpress -- wp --path="$WP_PATH" --skip-plugins --skip-themes)
  "${wp[@]}" core version >"$WORK/core" 2>/dev/null \
    && "${wp[@]}" plugin list --format=json --fields=name,version,status,update_version >"$WORK/plugins" 2>/dev/null \
    && "${wp[@]}" theme list --format=json --fields=name,version,status,update_version >"$WORK/themes" 2>/dev/null \
    || return 1
  python3 -I -c '
import json, sys
core, plugins, themes, out = sys.argv[1:]
json.dump({"core": open(core).read().strip(), "plugins": json.load(open(plugins)), "themes": json.load(open(themes))}, open(out, "w"))' \
    "$WORK/core" "$WORK/plugins" "$WORK/themes" "$out"
}

# 自作アプリの「更新を促す」情報(週次の通知のときだけ): 上流に未取り込みのコミットがあるか、devより古い版か
app_updates() {
  local app="$1" latest want tag
  latest="$("$SCRIPT_DIR/update-app-image.sh" latest-src-ref "$app" 2>/dev/null || true)"
  if [[ -n "$latest" && -f "images/$app/SRC_REF" && "$latest" != "$(tr -d '[:space:]' < "images/$app/SRC_REF")" ]]; then
    echo "上流に未取り込みのコミットがあります(最新 ${latest:0:7}。scripts/update-app-image.sh set-image $app $latest)"
  fi
  tag="$(tr -d '[:space:]' < "images/$app/TAG" 2>/dev/null || true)"
  want="$(grep -rhoP '^\s*image: \S+:\K[^@\s]+' "envs/$ENV/apps/$app/deployment.yaml" 2>/dev/null | head -1 || true)"
  if [[ "$ENV" != dev && -n "$tag" && -n "$want" && "$tag" != "$want" ]]; then
    echo "devより古い版です(${ENV}: ${want} / images: ${tag})"
  fi
  return 0
}

[[ "$KIND" == sites ]] && WORDFENCE="$(wordfence_feed)"

total_ng=0
total_warn=0
summary=()
for n in "${NAMES[@]}"; do
  echo ""
  echo "=== 脆弱性チェック: ${ENV} ${KIND}/${n} ==="
  ns="$n"
  [[ "$KIND" == sites ]] && ns="wordpress-$n"
  args=(--policy qa/vuln-policy.yaml --name "$n" --eol-cache "$CACHE_DIR" --findings-out "$WORK/findings-$n.json")
  [[ $ENFORCE -eq 1 ]] && args+=(--strict)

  trivy_files=()
  if ! images="$(images_of "$ns" 2>"$WORK/err")" || [[ -z "$images" ]]; then
    args+=(--unscanned "動いているイメージを取得できません(${ns}: $(head -c 200 "$WORK/err"))")
  else
    while read -r img; do
      f="$(scan_image "$img")"
      if [[ -n "$f" ]]; then
        trivy_files+=("$f")
      else
        args+=(--unscanned "Trivy: ${img}: $(grep -v '^\s*$' "$WORK/trivy-$(sha1sum <<<"$img" | cut -c1-16).json.err" | tail -2 | tr '\n' ' ' | head -c 300)")
      fi
    done <<<"$images"
  fi
  [[ ${#trivy_files[@]} -gt 0 ]] && args+=(--trivy "${trivy_files[@]}")

  if [[ "$KIND" == sites ]]; then
    if wp_inventory "$n" "$WORK/wp-$n.json"; then
      args+=(--wp "$WORK/wp-$n.json")
      [[ -n "$WORDFENCE" ]] && args+=(--wordfence "$WORDFENCE")
    else
      args+=(--unscanned "wp-cliでプラグイン一覧を取れません(${ns}。Podへのexec権限・Podの状態を確認)")
    fi
  elif [[ $NOTIFY -eq 1 ]]; then
    while read -r line; do
      [[ -n "$line" ]] && args+=(--info "$line")
    done < <(app_updates "$n")
  fi

  out="$(python3 -I "$SCRIPT_DIR/lib/vuln_report.py" "${args[@]}")"
  grep -v '^VULN_RESULT ' <<<"$out" || true
  read -r _ ng warn < <(grep '^VULN_RESULT ' <<<"$out")
  total_ng=$((total_ng + ng))
  total_warn=$((total_warn + warn))
  summary+=("$n $ng $warn")

  actor="${PIPELINE_ACTOR:-$(whoami)}"
  if [[ $ng -eq 0 ]]; then
    echo "結果: OK(NG 0件・警告 ${warn}件)"
    state=success
    desc="OK: 対応が必要な脆弱性なし(警告${warn}件)(${actor})"
  else
    echo "結果: NG(NG ${ng}件・警告 ${warn}件)$([[ $ENFORCE -eq 1 ]] || echo '。enforce: false のため止めません')"
    state=failure
    desc="NG: 対応が必要な脆弱性あり。詳細はRundeckのログ(${actor})"
  fi
  # 詳細は出さず合否だけを記録する(publicリポジトリのため)
  if [[ "$ENV" == staging && "${QA_NO_STATUS:-0}" != 1 ]]; then
    post_status vuln "$KIND" "$n" "$state" "$desc"
  fi
done

if [[ $NOTIFY -eq 1 ]]; then
  baseline="$CACHE_DIR/baseline-$ENV-$KIND.json"
  python3 -I "$SCRIPT_DIR/lib/vuln_notify.py" --env "$ENV" --kind "$KIND" --baseline "$baseline" \
    --baseline-out "$WORK/baseline.new.json" --enforce "$ENFORCE" --url "${RUNDECK_EXEC_URL:-}" \
    --payload-out "$WORK/slack.json" \
    --summary "${summary[@]}" --findings "$WORK"/findings-*.json
  # Webhook URLをコマンドラインに出さないよう、curlの設定ファイルで渡す
  printf 'url = "%s"\n' "$(tr -d '[:space:]' < "$CONF_DIR/slack-webhook")" >"$WORK/slack.curl"
  if curl -fsS -K "$WORK/slack.curl" -X POST -H 'Content-Type: application/json' --data-binary @"$WORK/slack.json" >/dev/null; then
    echo "Slackへ通知しました。"
    mv "$WORK/baseline.new.json" "$baseline"
  else
    echo "警告: Slackへ通知できませんでした(次回も今回の分を「新規」として通知します)。" >&2
  fi
fi

echo ""
echo "脆弱性チェック(${ENV} ${KIND}): NG ${total_ng}件・警告 ${total_warn}件"
if [[ $total_ng -gt 0 && $ENFORCE -eq 1 ]]; then
  exit 1
fi
exit 0
