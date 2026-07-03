#!/usr/bin/env bash
# wordpress-base-values.yaml(全サイト共通の値)と wordpress-<site>/fleet.yaml(サイト固有の差分)
# を一次情報源として、Fleet(Continuous Delivery)を介さず helm upgrade --install で
# 直接WordPressをデプロイ/アップグレードする。サイトの新規作成は scripts/new-wordpress-site.sh、
# 運用手順全体は docs/manual-wordpress.md を参照。
#
# 前提:
#   - kubectl/helm が対象クラスタ(dev1)を指すよう設定済みであること
#
# 認証情報のSecret(wordpress-<site>-credentials等)がまだ存在しない場合は、初回実行時に
# サイトごとのランダムなパスワードを自動生成して作成する(全サイトでパスワードを使い回すと
# 1サイトの漏洩が他サイトに波及するため)。生成したパスワードはhelmコマンド完了後、末尾で
# 標準エラー出力にしか表示されないので、初回実行時は必ず控えること。
# 詳細は docs/manual-wordpress.md 参照。
#
# 使い方:
#   scripts/deploy-wordpress.sh <サイト名> [追加のhelmオプション...]
#   例: scripts/deploy-wordpress.sh web               # wordpress-web/fleet.yaml
#       scripts/deploy-wordpress.sh web --dry-run     # 同上、helmオプション付き
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -eq 0 || "$1" == -* ]]; then
  echo "使い方: $0 <サイト名> [追加のhelmオプション...]" >&2
  echo "例: $0 web" >&2
  exit 1
fi

SITE="$1"
shift

SITE_DIR="wordpress-$SITE"
RELEASE_NAME="${RELEASE_NAME:-wordpress-$SITE}"
NAMESPACE="${NAMESPACE:-wordpress-$SITE}"
CREDENTIALS_SECRET="${CREDENTIALS_SECRET:-wordpress-$SITE-credentials}"
MARIADB_SECRET="${MARIADB_SECRET:-wordpress-$SITE-mariadb-credentials}"
MARIADB_UPGRADE_SECRET="${MARIADB_UPGRADE_SECRET:-wordpress-$SITE-mariadb-upgrade-values}"

FLEET_YAML="$REPO_ROOT/$SITE_DIR/fleet.yaml"
BASE_VALUES="$REPO_ROOT/wordpress-base-values.yaml"

for cmd in helm kubectl python3 openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: '$cmd' が見つかりません。インストールしてから再実行してください。" >&2
    exit 1
  fi
done

if [[ ! -f "$FLEET_YAML" ]]; then
  echo "エラー: $FLEET_YAML が見つかりません。" >&2
  exit 1
fi

if [[ ! -f "$BASE_VALUES" ]]; then
  echo "エラー: $BASE_VALUES が見つかりません。" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
chmod 700 "$WORKDIR"

# 認証情報のSecretが1つも無ければ、このサイトの初回デプロイとみなし、サイト専用のランダム
# パスワードを生成してSecretを作成する。一部だけ存在する場合(手動で作り直し中など)は
# 意図しない上書きを避けるため何もしない。
if ! kubectl -n "$NAMESPACE" get secret "$MARIADB_UPGRADE_SECRET" >/dev/null 2>&1 \
  && ! kubectl -n "$NAMESPACE" get secret "$CREDENTIALS_SECRET" >/dev/null 2>&1 \
  && ! kubectl -n "$NAMESPACE" get secret "$MARIADB_SECRET" >/dev/null 2>&1; then
  echo "認証情報のSecretが見つからないため、'$NAMESPACE' 用に新規パスワードを生成します。" >&2

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  WP_PASSWORD="$(openssl rand -base64 24)"
  DB_ROOT_PASSWORD="$(openssl rand -base64 24)"
  DB_PASSWORD="$(openssl rand -base64 24)"

  kubectl -n "$NAMESPACE" create secret generic "$CREDENTIALS_SECRET" \
    --from-literal=wordpress-password="$WP_PASSWORD"

  kubectl -n "$NAMESPACE" create secret generic "$MARIADB_SECRET" \
    --from-literal=mariadb-root-password="$DB_ROOT_PASSWORD" \
    --from-literal=mariadb-password="$DB_PASSWORD"

  # BitnamiのmariadbサブチャートはHelmアップグレード時、existingSecretを使っていても
  # auth.rootPassword/auth.passwordの明示指定を要求してくる(PASSWORDS ERROR)ため、
  # 同じ値をHelm values形式でも保持しておく。
  cat >"$WORKDIR/mariadb-upgrade-values.yaml" <<EOF
mariadb:
  auth:
    rootPassword: "$DB_ROOT_PASSWORD"
    password: "$DB_PASSWORD"
EOF

  kubectl -n "$NAMESPACE" create secret generic "$MARIADB_UPGRADE_SECRET" \
    --from-file=values.yaml="$WORKDIR/mariadb-upgrade-values.yaml"

  BOOTSTRAPPED=1
fi

FLEET_VALUES="$WORKDIR/fleet-values.yaml"
SECRET_VALUES="$WORKDIR/secret-values.yaml"

# fleet.yaml の helm.chart / helm.version / helm.values を単一の情報源として読み取る。
# (helm.valuesの内容をこのスクリプトに複製すると、fleet.yamlと二重管理になり差分が生まれるため)
read -r CHART VERSION <<<"$(python3 - "$FLEET_YAML" "$FLEET_VALUES" <<'PYEOF'
import sys
import yaml

fleet_yaml_path, values_out_path = sys.argv[1], sys.argv[2]
with open(fleet_yaml_path) as f:
    doc = yaml.safe_load(f)

helm = doc.get("helm", {})
with open(values_out_path, "w") as f:
    yaml.safe_dump(helm.get("values", {}), f)

print(helm["chart"], helm["version"])
PYEOF
)"

# fleet.yaml の helm.valuesFrom.secretKeyRef 相当を再現する。
# helm CLIには valuesFrom(Secret参照)に相当する機能がないため、ここでSecretから読み出して
# 通常のvaluesファイルとしてマージする。
kubectl -n "$NAMESPACE" get secret "$MARIADB_UPGRADE_SECRET" \
  -o jsonpath='{.data.values\.yaml}' | base64 -d >"$SECRET_VALUES"

helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update bitnami >/dev/null

helm upgrade --install "$RELEASE_NAME" bitnami/wordpress \
  --version "$VERSION" \
  -n "$NAMESPACE" --create-namespace \
  -f "$BASE_VALUES" \
  -f "$FLEET_VALUES" \
  -f "$SECRET_VALUES" \
  "$@"

# helmコマンドの出力(NOTES/WARNING等)に埋もれないよう、生成したパスワードは最後にまとめて表示する。
if [[ "${BOOTSTRAPPED:-}" == "1" ]]; then
  cat >&2 <<EOF

生成したパスワード('$NAMESPACE'。ここにしか表示されないので必ず控えてください):
  WordPress管理者(admin)パスワード:      $WP_PASSWORD
  MariaDB rootパスワード:               $DB_ROOT_PASSWORD
  MariaDB bn_wordpressユーザーパスワード: $DB_PASSWORD

EOF
fi
