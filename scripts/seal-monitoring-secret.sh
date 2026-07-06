#!/usr/bin/env bash
# Alertmanager用Slack Webhook URLをSealedSecretとして
# envs/<env>/infra/monitoring-secrets/alertmanager-slack-webhook.yaml に出力する。
#
# Webhook URLの受け取り方(argvでは受け取らない=シェル履歴に残さない):
#   1) 環境変数 SLACK_WEBHOOK_URL が設定されていればそれを使う
#   2) 未設定なら非表示プロンプトで入力を求める
#
# 前提:
#   - 対象環境に Sealed Secretsコントローラが導入済み(envs/<env>/infra/sealed-secrets/)
#   - kubeseal CLI(コントローラと同版)がPATHにあること
#
# 使い方:
#   scripts/seal-monitoring-secret.sh <env>
#   例: SLACK_WEBHOOK_URL=https://hooks.slack.com/... scripts/seal-monitoring-secret.sh dev
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

for cmd in kubectl kubeseal; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: '$cmd' が見つかりません。" >&2
    exit 1
  fi
done

NAMESPACE="cattle-monitoring-system"
SECRET_NAME="alertmanager-slack-webhook"
OUT_DIR="$REPO_ROOT/envs/$ENV_NAME/infra/monitoring-secrets"
OUT_FILE="$OUT_DIR/$SECRET_NAME.yaml"

if [[ ! -d "$OUT_DIR" ]]; then
  echo "エラー: $OUT_DIR がありません(monitoring-secretsバンドルを先に作成してください)。" >&2
  exit 1
fi

echo "対象: env=$ENV_NAME (kubectlコンテキスト: $CONTEXT)" >&2

WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
if [[ -z "$WEBHOOK_URL" ]]; then
  read -rs -p "Slack Webhook URLを入力してください(表示されません): " WEBHOOK_URL
  echo >&2
fi
if [[ ! "$WEBHOOK_URL" =~ ^https:// ]]; then
  echo "エラー: Webhook URLは https:// で始まる必要があります。" >&2
  exit 1
fi

# 封印はkubeseal内で完結する(平文Secretはクラスタに作らない)。
# namespaceはこの時点で存在しなくてよい。
# 途中失敗で不完全なファイルが残らないよう、テンポラリに書いてからmvで置き換える。
TMP_FILE="$(mktemp "$OUT_DIR/.$SECRET_NAME.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT
{
  cat <<EOF
# Alertmanager用Slack Webhook URLのSealedSecret($ENV_NAME環境)。
# scripts/seal-monitoring-secret.sh で生成。封印された値はこの環境の
# コントローラでのみ復号できる(他環境へのコピー不可。環境ごとに生成し直すこと)。
# ローテーション手順は docs/manual-monitoring.md 参照。
---
EOF
  kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
    --from-literal=webhook-url="$WEBHOOK_URL" \
    --dry-run=client -o json \
    | kubeseal --context "$CONTEXT" --format yaml \
    | sed '1{/^---$/d}'
} >"$TMP_FILE"
mv "$TMP_FILE" "$OUT_FILE"
trap - EXIT

echo "作成しました: $OUT_FILE" >&2
echo "PRを作成してマージしてください。" >&2
