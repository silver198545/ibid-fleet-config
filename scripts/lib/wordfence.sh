# Wordfence Intelligenceの脆弱性フィード(production、v3)を取得する共通処理。
# scripts/vuln-scan.sh・scripts/plugin-check.sh が source して使う。要 curl。
#
# APIキーは実行ユーザーのファイル ~/.config/ibid-fleet-config/wordfence-api-key(権限600)に置く
# (docs/manual-vuln-scan.md「準備」)。フィードは12時間キャッシュする(2つのスクリプトで共有)。
# このリポジトリはpublicなので、フィードやその照合結果(パッケージ・CVE)はGitHubに出さないこと。

WORDFENCE_FEED_URL="https://www.wordfence.com/api/intelligence/v3/vulnerabilities/production"
WORDFENCE_CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ibid-fleet-config"
WORDFENCE_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ibid-fleet-config/vuln"

# フィードのファイルのパスを標準出力に返す。キーが無い・取れず前回の分も無ければ空を返す(終了コードは0)。
# 引数: <一時ファイルを置くディレクトリ(権限700)>
wordfence_feed() {
  local work="$1" key="$WORDFENCE_CONF_DIR/wordfence-api-key" cache="$WORDFENCE_CACHE_DIR/wordfence-production.json"
  [[ -s "$key" ]] || return 0
  mkdir -p "$WORDFENCE_CACHE_DIR"
  chmod 700 "$WORDFENCE_CACHE_DIR"
  if [[ ! -s "$cache" || -n "$(find "$cache" -mmin +720 2>/dev/null)" ]]; then
    # キーをコマンドラインに出さないよう、ヘッダはファイルで渡す
    printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$key")" >"$work/wf-header"
    if curl -fsS --compressed --max-time 600 -H @"$work/wf-header" -o "$cache.tmp" "$WORDFENCE_FEED_URL"; then
      mv "$cache.tmp" "$cache"
    else
      rm -f "$cache.tmp"
      echo "警告: Wordfenceのフィードを取得できませんでした$([[ -s "$cache" ]] && echo '(前回の分を使います)')。" >&2
    fi
    rm -f "$work/wf-header"
  fi
  [[ -s "$cache" ]] && echo "$cache"
  return 0
}
