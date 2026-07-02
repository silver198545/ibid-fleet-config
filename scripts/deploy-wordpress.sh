#!/usr/bin/env bash
# wordpress/fleet.yaml の内容を一次情報源として、Fleet(Continuous Delivery)を介さず
# helm upgrade --install で直接WordPressをデプロイ/アップグレードする。
#
# 前提:
#   - kubectl/helm が対象クラスタ(dev1)を指すよう設定済みであること
#   - docs/manual-wordpress.md の手順1でSecret(wordpress-credentials等)を作成済みであること
#   - Fleetの管理下から外す一度きりの切替作業は docs/manual-wordpress-fleet-cutover.md を参照
#
# 使い方:
#   scripts/deploy-wordpress.sh [追加のhelmオプション...]
#   例: scripts/deploy-wordpress.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLEET_YAML="$REPO_ROOT/wordpress/fleet.yaml"

RELEASE_NAME="${RELEASE_NAME:-base-infra-wordpress}"
NAMESPACE="${NAMESPACE:-wordpress}"

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
kubectl -n "$NAMESPACE" get secret wordpress-mariadb-upgrade-values \
  -o jsonpath='{.data.values\.yaml}' | base64 -d >"$SECRET_VALUES"

helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update bitnami >/dev/null

# persistence.existingClaim: WordPress本体用PVCを新規作成させず、Fleet時代から使っている
# 既存PVC(リリース名と同名)にそのままバインドさせる。これによりFleet管理からの切替時に
# PVC名の衝突やデータ引き継ぎ漏れを起こさない。
helm upgrade --install "$RELEASE_NAME" bitnami/wordpress \
  --version "$VERSION" \
  -n "$NAMESPACE" --create-namespace \
  -f "$FLEET_VALUES" \
  -f "$SECRET_VALUES" \
  --set "persistence.existingClaim=$RELEASE_NAME" \
  "$@"
