#!/usr/bin/env bash
# 本番データリハーサル用の一時サイト(<site>-rh)のFleetバンドルを、既存サイトの
# fleet.yamlから生成・更新する。staging廃止(2026-10-08)後、本番相当データでの
# DBマイグレーション確認をdev1上で行うためのもの(docs/operations-flow.md
# 「本番データリハーサル」参照)。
#
# envs/<from>/sites/<site>/fleet.yaml をコピーし、名前を <site>-rh 向けに置き換えて
# envs/dev/sites/<site>-rh/fleet.yaml に書き出す(既にあれば上書き)。
#   - from=production: 本番と同じ構成(チャート版・プラグイン)でリハーサルサイトを作る。
#                      本番データをリストアする前の初期状態にする
#   - from=dev:        devで検証中の構成(昇格させたい変更)へ切り替える。
#                      本番データに対するアップグレードを実際に踏ませる
#
# Secret(scripts/seal-site-secrets.sh dev <site>-rh)・PR作成・リストアは別途行う。
#
# 使い方:
#   scripts/rehearsal-site.sh <site> <production|dev>
#   例: scripts/rehearsal-site.sh web production
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -ne 2 ]]; then
  echo "使い方: $0 <site> <production|dev>" >&2
  echo "例: $0 web production" >&2
  exit 1
fi

SITE="$1"
FROM_ENV="$2"
RH_SITE="$SITE-rh"

case "$FROM_ENV" in
  dev|production) ;;
  *)
    echo "エラー: 構成の取得元は production / dev のいずれかを指定してください: $FROM_ENV" >&2
    exit 1
    ;;
esac

if [[ ! "$SITE" =~ ^[a-z0-9-]+$ || "$SITE" == *-rh ]]; then
  echo "エラー: リハーサル元のサイト名を指定してください(英小文字・数字・ハイフン、-rhで終わらないこと): $SITE" >&2
  exit 1
fi

SRC="$REPO_ROOT/envs/$FROM_ENV/sites/$SITE/fleet.yaml"
DST_DIR="$REPO_ROOT/envs/dev/sites/$RH_SITE"
if [[ ! -f "$SRC" ]]; then
  echo "エラー: $SRC がありません。" >&2
  exit 1
fi

mkdir -p "$DST_DIR"
# 名前はすべて wordpress-<site>(namespace・リリース名・Secret名・NetworkPolicy名)から
# 機械的に派生しているので、その接頭辞とingressのホスト名だけを置き換える。
sed -e "s/wordpress-${SITE}\\b/wordpress-${RH_SITE}/g" \
    -e "s/^\\(\\s*hostname: \\)${SITE}\\./\\1${RH_SITE}./" \
    "$SRC" >"$DST_DIR/fleet.yaml"

# 置き換え漏れ(元サイトのリソースを指したまま)が無いことを確認する。
if grep -nE "wordpress-${SITE}([^-a-z0-9]|$|-(credentials|mariadb))" "$DST_DIR/fleet.yaml" \
    | grep -v "wordpress-${RH_SITE}"; then
  echo "エラー: 上記の行に元サイト(${SITE})の名前が残っています。$DST_DIR/fleet.yaml を確認してください。" >&2
  exit 1
fi

echo "作成しました: envs/dev/sites/$RH_SITE/fleet.yaml(envs/$FROM_ENV/sites/$SITE の構成)"
echo "差分を確認してください: diff $SRC $DST_DIR/fleet.yaml"
if [[ "$FROM_ENV" == "production" && ! -f "$REPO_ROOT/envs/dev/secrets/$RH_SITE.yaml" ]]; then
  echo "次に: scripts/seal-site-secrets.sh dev $RH_SITE でSecretを生成し、両方を1つのPRにまとめる。"
fi
echo "手順の全体は docs/operations-flow.md「本番データリハーサル」を参照。"
