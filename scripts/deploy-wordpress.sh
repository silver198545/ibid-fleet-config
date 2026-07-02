#!/usr/bin/env bash
# wordpress-base-values.yaml(全サイト共通の値)と <site>/fleet.yaml(サイト固有の差分)
# を一次情報源として、Fleet(Continuous Delivery)を介さず helm upgrade --install で
# 直接WordPressをデプロイ/アップグレードする。複数サイトの管理方法は
# docs/manual-wordpress-multi-site.md を参照。
#
# 前提:
#   - kubectl/helm が対象クラスタ(dev1)を指すよう設定済みであること
#   - docs/manual-wordpress.md (最初のサイト) または
#     docs/manual-wordpress-multi-site.md (追加サイト) の手順でSecretを作成済みであること
#   - Fleetの管理下から外す一度きりの切替作業は docs/manual-wordpress-fleet-cutover.md を参照
#
# 使い方:
#   scripts/deploy-wordpress.sh [サイト名] [追加のhelmオプション...]
#   例: scripts/deploy-wordpress.sh                  # 最初のサイト(wordpress/fleet.yaml)
#       scripts/deploy-wordpress.sh --dry-run         # 同上、helmオプション付き
#       scripts/deploy-wordpress.sh web               # 追加サイト(wordpress-web/fleet.yaml)
#       scripts/deploy-wordpress.sh web --dry-run     # 同上、helmオプション付き
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 第1引数が"-"始まりでなければサイト名として扱う(それ以外はすべてhelmへの追加オプション)。
SITE=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  SITE="$1"
  shift
fi

if [[ -z "$SITE" || "$SITE" == "wordpress" ]]; then
  # 最初のサイト。既存の運用(namespace/リリース名)との後方互換のためデフォルトを維持する。
  SITE_DIR="wordpress"
  RELEASE_NAME="${RELEASE_NAME:-base-infra-wordpress}"
  NAMESPACE="${NAMESPACE:-wordpress}"
  MARIADB_UPGRADE_SECRET="${MARIADB_UPGRADE_SECRET:-wordpress-mariadb-upgrade-values}"
  # Fleet時代から使っている既存PVC(リリース名と同名)にそのままバインドさせる
  # (下記の`persistence.existingClaim`コメント参照)。最初のサイトだけの特殊事情であり、
  # PVCが存在しない新規サイトに適用するとchartがPVCを作成せずPodがマウント失敗する。
  EXISTING_CLAIM_ARGS=(--set "persistence.existingClaim=$RELEASE_NAME")
else
  # 追加サイト。wordpress-<site>/fleet.yaml と、揃った命名規則のnamespace/リリース名/Secretを使う。
  # PVCはchartに新規作成させるため、existingClaimは指定しない。
  SITE_DIR="wordpress-$SITE"
  RELEASE_NAME="${RELEASE_NAME:-wordpress-$SITE}"
  NAMESPACE="${NAMESPACE:-wordpress-$SITE}"
  MARIADB_UPGRADE_SECRET="${MARIADB_UPGRADE_SECRET:-wordpress-$SITE-mariadb-upgrade-values}"
  EXISTING_CLAIM_ARGS=()
fi

FLEET_YAML="$REPO_ROOT/$SITE_DIR/fleet.yaml"
BASE_VALUES="$REPO_ROOT/wordpress-base-values.yaml"

for cmd in helm kubectl python3; do
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

# persistence.existingClaim(最初のサイトのみ): WordPress本体用PVCを新規作成させず、
# Fleet時代から使っている既存PVC(リリース名と同名)にそのままバインドさせる。これにより
# Fleet管理からの切替時にPVC名の衝突やデータ引き継ぎ漏れを起こさない。
helm upgrade --install "$RELEASE_NAME" bitnami/wordpress \
  --version "$VERSION" \
  -n "$NAMESPACE" --create-namespace \
  -f "$BASE_VALUES" \
  -f "$FLEET_VALUES" \
  -f "$SECRET_VALUES" \
  "${EXISTING_CLAIM_ARGS[@]}" \
  "$@"
