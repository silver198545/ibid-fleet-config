#!/usr/bin/env bash
# sparqlist(envs/<env>/apps/sparqlist)の管理API用ADMIN_PASSWORDを
# SealedSecretとして envs/<env>/secrets/sparqlist.yaml に出力する。
#
# brc-advanced-search/riken-diips の envs/<env>/secrets/<app>.yaml はGHCR pull用だが、
# sparqlistはGHCRイメージを公開設定にしているためpull用Secretは不要(docs/manual-apps.md参照)。
# 代わりにここではDeploymentのADMIN_PASSWORD環境変数(secretKeyRef)用のSecretを封印する。
#
# このリポジトリの方針(CLAUDE.md)では、パスワードは環境ごとに新規生成し
# 他環境からのコピーや使い回しをしないことが基本だが、既存運用からの移行等で
# 特定の値を使いたい場合は環境変数 ADMIN_PASSWORD で明示指定できる(argvでは
# 受け取らない=シェル履歴に残さない)。未指定ならランダム生成する。
#
# 前提:
#   - 対象環境に Sealed Secretsコントローラが導入済み(envs/<env>/infra/sealed-secrets/)
#   - kubeseal CLI(コントローラと同版)がPATHにあること
#
# 使い方:
#   scripts/seal-sparqlist-secret.sh <env>
#   例: scripts/seal-sparqlist-secret.sh dev
#   例(値を指定): ADMIN_PASSWORD='...' scripts/seal-sparqlist-secret.sh dev
#   環境→kubectlコンテキストの対応は既定(dev1/staging1/prod1)。
#   異なる場合は KUBE_CONTEXT=<コンテキスト名> で上書きする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "使い方: $0 <env>" >&2
  exit 1
fi

ENV_NAME="$1"

case "$ENV_NAME" in
  dev) DEFAULT_CONTEXT="dev1" ;;
  staging) DEFAULT_CONTEXT="staging1" ;;
  production) DEFAULT_CONTEXT="prod1" ;;
  *)
    echo "エラー: envは dev / staging / production のいずれかを指定してください: $ENV_NAME" >&2
    exit 1
    ;;
esac
CONTEXT="${KUBE_CONTEXT:-$DEFAULT_CONTEXT}"

for cmd in kubectl kubeseal openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: '$cmd' が見つかりません。" >&2
    exit 1
  fi
done

NAMESPACE="sparqlist"
SECRET_NAME="sparqlist-admin-password"
OUT_DIR="$REPO_ROOT/envs/$ENV_NAME/secrets"
OUT_FILE="$OUT_DIR/sparqlist.yaml"

[[ -d "$OUT_DIR" ]] || { echo "エラー: $OUT_DIR がありません(secretsバンドルを先に作成してください)。" >&2; exit 1; }

echo "対象: env=$ENV_NAME (kubectlコンテキスト: $CONTEXT)" >&2

GENERATED=0
if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
  ADMIN_PASSWORD="$(openssl rand -base64 24)"
  GENERATED=1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
chmod 700 "$WORKDIR"

kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-literal=admin-password="$ADMIN_PASSWORD" \
  --dry-run=client -o json >"$WORKDIR/$SECRET_NAME.json"

# 途中失敗で不完全なファイルが残らないよう、テンポラリに書いてからmvで置き換える。
TMP_FILE="$(mktemp "$OUT_DIR/.sparqlist.XXXXXX")"
trap 'rm -f "$TMP_FILE"; rm -rf "$WORKDIR"' EXIT
{
  cat <<EOF
# sparqlist ($ENV_NAME環境)のADMIN_PASSWORD用SealedSecret。
# scripts/seal-sparqlist-secret.sh で生成。封印された値はこの環境の
# コントローラでのみ復号できる(他環境へのコピー不可。環境ごとに生成し直すこと)。
---
# アプリのnamespace。SealedSecretより先に適用されるようバンドルに含める
# (DR時の手動 kubectl create ns を不要にする)。既存namespaceの引き取りは
# envs/<env>/secrets/fleet.yaml の takeOwnership: true が担う。
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
EOF
  echo "---"
  kubeseal --context "$CONTEXT" --format yaml <"$WORKDIR/$SECRET_NAME.json" \
    | sed '1{/^---$/d}'
} >"$TMP_FILE"
mv "$TMP_FILE" "$OUT_FILE"
trap - EXIT
rm -rf "$WORKDIR"

echo "作成しました: $OUT_FILE" >&2
echo "PRを作成してマージしてください。" >&2
if [[ "$GENERATED" == "1" ]]; then
  cat >&2 <<EOF

生成したパスワード('$NAMESPACE' @ $ENV_NAME。ここにしか表示されないので必ず控えてください):
  ADMIN_PASSWORD: $ADMIN_PASSWORD

EOF
else
  echo "指定されたADMIN_PASSWORDを封印しました('$NAMESPACE' @ $ENV_NAME)。" >&2
fi
