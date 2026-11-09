# SlackのIncoming Webhookへ通知する共通処理。
# scripts/vuln-scan.sh・scripts/plugin-check.sh が source して使う。要 curl。
#
# Webhook URLは実行ユーザーのファイル ~/.config/ibid-fleet-config/slack-webhook(権限600)に置く
# (置き方は docs/manual-vuln-scan.md「準備」)。URLはログやコマンドラインに出さない。

SLACK_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ibid-fleet-config"

# Webhook URLを標準出力に返す。無い・形が違うときはエラーを出して1を返す。
# Slackの画面によっては T…/B…/… の部分だけが表示されるので、その形なら先頭を補う。
slack_webhook_url() {
  local f="$SLACK_CONF_DIR/slack-webhook" url
  if [[ ! -s "$f" ]]; then
    echo "エラー: Slackへの通知には $f(SlackのWebhook URL)が要ります(docs/manual-vuln-scan.md「準備」)。" >&2
    return 1
  fi
  url="$(tr -d '[:space:]' < "$f")"
  if [[ "$url" =~ ^T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+$ ]]; then
    url="https://hooks.slack.com/services/$url"
  fi
  if [[ ! "$url" =~ ^https://hooks\.slack\.com/ ]]; then
    echo "エラー: $f が https://hooks.slack.com/services/T…/B…/… の形ではありません(docs/manual-vuln-scan.md「準備」)。" >&2
    return 1
  fi
  echo "$url"
}

# SlackへJSON({"text": ...})を送る。成功で0。
# 引数: <Webhook URL> <JSONのファイル> <一時ファイルを置くディレクトリ(権限700)>
slack_post() {
  local url="$1" payload="$2" work="$3"
  # Webhook URLをコマンドラインに出さないよう、curlの設定ファイルで渡す
  printf 'url = "%s"\n' "$url" >"$work/slack.curl"
  curl -fsS -K "$work/slack.curl" -X POST -H 'Content-Type: application/json' --data-binary @"$payload" >/dev/null
  local rc=$?
  rm -f "$work/slack.curl"
  return $rc
}
