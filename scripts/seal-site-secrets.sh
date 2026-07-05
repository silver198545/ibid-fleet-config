#!/usr/bin/env bash
# WordPressサイト1つ分の認証情報Secret(3種)をSealedSecretとして
# envs/<env>/secrets/<site>.yaml に出力する(Sealed Secrets運用。Phase 2)。
#
# 2つのモードを自動判別する:
#   1) 対象クラスタに3つのSecretが既に存在する → その値をそのまま封印(移行モード)。
#      あわせて既存Secretに sealedsecrets.bitnami.com/managed=true を付与し、
#      コントローラが既存Secretを引き取れるようにする。
#   2) 1つも存在しない → 新規パスワードを生成して封印(新規サイトモード)。
#      パスワードは最後に一度だけ表示されるので必ず控えること。
#      実クラスタへのSecret投入はGitマージ後にコントローラが行う。
#
# 前提:
#   - 対象環境に Sealed Secretsコントローラが導入済み(envs/<env>/infra/sealed-secrets/)
#   - kubeseal CLI(コントローラと同版)がPATHにあること
#
# 使い方:
#   scripts/seal-site-secrets.sh <env> <site>
#   例: scripts/seal-site-secrets.sh dev web
#   環境→kubectlコンテキストの対応は既定(dev1/staging1/prod1)。
#   異なる場合は KUBE_CONTEXT=<コンテキスト名> で上書きする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -ne 2 ]]; then
  echo "使い方: $0 <env> <site>" >&2
  exit 1
fi

ENV_NAME="$1"
SITE="$2"

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

if [[ ! "$SITE" =~ ^[a-z0-9-]+$ ]]; then
  echo "エラー: サイト名は英小文字・数字・ハイフンのみ使用できます: $SITE" >&2
  exit 1
fi

for cmd in kubectl kubeseal openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: '$cmd' が見つかりません。" >&2
    exit 1
  fi
done

NAMESPACE="wordpress-$SITE"
CREDENTIALS_SECRET="wordpress-$SITE-credentials"
MARIADB_SECRET="wordpress-$SITE-mariadb-credentials"
MARIADB_UPGRADE_SECRET="wordpress-$SITE-mariadb-upgrade-values"
OUT_DIR="$REPO_ROOT/envs/$ENV_NAME/secrets"
OUT_FILE="$OUT_DIR/$SITE.yaml"

echo "対象: env=$ENV_NAME site=$SITE (kubectlコンテキスト: $CONTEXT)" >&2

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
chmod 700 "$WORKDIR"

EXISTING=0
for s in "$CREDENTIALS_SECRET" "$MARIADB_SECRET" "$MARIADB_UPGRADE_SECRET"; do
  if kubectl --context "$CONTEXT" -n "$NAMESPACE" get secret "$s" >/dev/null 2>&1; then
    EXISTING=$((EXISTING + 1))
  fi
done

if [[ $EXISTING -eq 3 ]]; then
  echo "既存のSecretを封印します(移行モード。パスワードは変わりません)。" >&2
  for s in "$CREDENTIALS_SECRET" "$MARIADB_SECRET" "$MARIADB_UPGRADE_SECRET"; do
    # コントローラが既存Secretを引き取れるようにする(無いと "not managed" エラーになる)。
    # エクスポートより先に付与することで、SealedSecretのtemplateにも同アノテーションが
    # 含まれ、Secretを手動で作り直した場合の再引き取りにも耐える。
    kubectl --context "$CONTEXT" -n "$NAMESPACE" annotate secret "$s" \
      sealedsecrets.bitnami.com/managed=true --overwrite >/dev/null
    kubectl --context "$CONTEXT" -n "$NAMESPACE" get secret "$s" -o json >"$WORKDIR/$s.json"
  done
elif [[ $EXISTING -eq 0 ]]; then
  echo "Secretが無いため新規パスワードを生成して封印します(新規サイトモード)。" >&2
  kubectl --context "$CONTEXT" create namespace "$NAMESPACE" --dry-run=client -o yaml \
    | kubectl --context "$CONTEXT" apply -f - >/dev/null

  WP_PASSWORD="$(openssl rand -base64 24)"
  DB_ROOT_PASSWORD="$(openssl rand -base64 24)"
  DB_PASSWORD="$(openssl rand -base64 24)"

  kubectl create secret generic "$CREDENTIALS_SECRET" -n "$NAMESPACE" \
    --from-literal=wordpress-password="$WP_PASSWORD" \
    --dry-run=client -o json >"$WORKDIR/$CREDENTIALS_SECRET.json"

  kubectl create secret generic "$MARIADB_SECRET" -n "$NAMESPACE" \
    --from-literal=mariadb-root-password="$DB_ROOT_PASSWORD" \
    --from-literal=mariadb-password="$DB_PASSWORD" \
    --dry-run=client -o json >"$WORKDIR/$MARIADB_SECRET.json"

  # ラッパーチャートのvaluesとしてマージされるため wordpress: 配下にネストする
  cat >"$WORKDIR/upgrade-values.yaml" <<EOF
wordpress:
  mariadb:
    auth:
      rootPassword: "$DB_ROOT_PASSWORD"
      password: "$DB_PASSWORD"
EOF
  kubectl create secret generic "$MARIADB_UPGRADE_SECRET" -n "$NAMESPACE" \
    --from-file=values.yaml="$WORKDIR/upgrade-values.yaml" \
    --dry-run=client -o json >"$WORKDIR/$MARIADB_UPGRADE_SECRET.json"

  GENERATED=1
else
  echo "エラー: 一部のSecretのみが存在します。手動で状態を確認してください。" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
cat >"$OUT_FILE" <<EOF
# サイト $SITE ($ENV_NAME環境)の認証情報SealedSecret。
# scripts/seal-site-secrets.sh で生成。封印された値はこの環境のコントローラ
# でのみ復号できる(他環境へのコピー不可。環境ごとに生成し直すこと)。
# パスワードのローテーション手順は docs/manual-wordpress.md 参照。
EOF
for s in "$CREDENTIALS_SECRET" "$MARIADB_SECRET" "$MARIADB_UPGRADE_SECRET"; do
  # kubesealの出力は先頭に"---"を含むことがあるため、除去してから
  # こちらで区切りを1つだけ付ける(重複すると空ドキュメントが混入する)
  echo "---" >>"$OUT_FILE"
  kubeseal --context "$CONTEXT" --format yaml <"$WORKDIR/$s.json" \
    | sed '1{/^---$/d}' >>"$OUT_FILE"
done

# 環境のsecretsバンドルが未作成なら足場を作る
FLEET_FILE="$OUT_DIR/fleet.yaml"
if [[ ! -f "$FLEET_FILE" ]]; then
  cat >"$FLEET_FILE" <<'EOF'
# サイト認証情報のSealedSecretバンドル(1サイト=1ファイル)。
# SealedSecretを消すと復号済みSecretも連動削除されるため、
# バンドル削除でもリソースを残す(サイト削除は手動手順で)。
keepResources: true

helm:
  releaseName: site-secrets
EOF
  echo "作成しました: $FLEET_FILE" >&2
fi

echo "作成しました: $OUT_FILE" >&2
echo "PRを作成してマージしてください。" >&2

if [[ "${GENERATED:-}" == "1" ]]; then
  cat >&2 <<EOF

生成したパスワード('$NAMESPACE' @ $ENV_NAME。ここにしか表示されないので必ず控えてください):
  WordPress管理者(admin)パスワード:      $WP_PASSWORD
  MariaDB rootパスワード:               $DB_ROOT_PASSWORD
  MariaDB bn_wordpressユーザーパスワード: $DB_PASSWORD

EOF
fi
