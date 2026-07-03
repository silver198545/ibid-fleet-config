#!/usr/bin/env bash
# 【break-glass(緊急用)】WordPressをFleetを介さず helm upgrade --install で直接
# デプロイ/アップグレードする。
#
# 通常の変更適用は envs/<env>/sites/<site>/fleet.yaml を編集してPRをマージし、
# Fleetに適用させること。このスクリプトはFleet/Rancher/GitHubが使えない障害時や、
# devでのマージ前の検証にのみ使う。本番で使う場合は、Fleetによる二重適用を避けるため
# 先に production の GitRepo を paused にすること(docs/manual-multi-env.md 参照)。
#
# fleet.yaml の helm.chart / helm.version / helm.values を単一の情報源として読み取り、
# Fleetが適用するのと同じ内容をhelmで直接適用する。fleet.yamlが無いサイト(マージ前の
# 新規サイト等)は、サイト名から機械的に決まるデフォルト設定をその場で生成して使う。
#
# 認証情報のSecretが存在しない場合は scripts/bootstrap-site-secrets.sh を自動で呼び、
# サイトごとのランダムパスワードを生成する(出力されるパスワードは必ず控えること)。
#
# 前提:
#   - kubectl/helm が対象環境のクラスタを指すよう設定済みであること
#
# 使い方:
#   scripts/deploy-wordpress.sh <env> <サイト名> [追加のhelmオプション...]
#   例: scripts/deploy-wordpress.sh dev web            # devのサイト"web"を適用
#       scripts/deploy-wordpress.sh dev web --dry-run  # 同上、helmオプション付き
#
# 環境変数:
#   CHART_LOCAL=1 ... OCIレジストリ(ghcr.io)からではなく、このリポジトリ内の
#                     charts/ibid-wordpress を直接使う(レジストリ障害時用)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# scripts/new-wordpress-site.sh と揃えること
DEFAULT_CHART_REF="oci://ghcr.io/silver198545/charts/ibid-wordpress"
DEFAULT_CHART_VERSION="0.1.0"

if [[ $# -lt 2 || "$1" == -* || "$2" == -* ]]; then
  echo "使い方: $0 <env> <サイト名> [追加のhelmオプション...]" >&2
  echo "例: $0 dev web" >&2
  exit 1
fi

ENV_NAME="$1"
SITE="$2"
shift 2

case "$ENV_NAME" in
  dev|staging|production) ;;
  *)
    echo "エラー: envは dev / staging / production のいずれかを指定してください: $ENV_NAME" >&2
    exit 1
    ;;
esac

RELEASE_NAME="${RELEASE_NAME:-wordpress-$SITE}"
NAMESPACE="${NAMESPACE:-wordpress-$SITE}"
CREDENTIALS_SECRET="${CREDENTIALS_SECRET:-wordpress-$SITE-credentials}"
MARIADB_SECRET="${MARIADB_SECRET:-wordpress-$SITE-mariadb-credentials}"
MARIADB_UPGRADE_SECRET="${MARIADB_UPGRADE_SECRET:-wordpress-$SITE-mariadb-upgrade-values}"

FLEET_YAML="$REPO_ROOT/envs/$ENV_NAME/sites/$SITE/fleet.yaml"

for cmd in helm kubectl python3 openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: '$cmd' が見つかりません。インストールしてから再実行してください。" >&2
    exit 1
  fi
done

CONTEXT="$(kubectl config current-context)"
echo "対象: env=$ENV_NAME site=$SITE (kubectlコンテキスト: $CONTEXT)" >&2
if [[ "${IBID_ASSUME_YES:-}" != "1" ]]; then
  read -r -p "このクラスタが env=$ENV_NAME で正しければ y を入力: " REPLY
  if [[ "$REPLY" != "y" ]]; then
    echo "中断しました。" >&2
    exit 1
  fi
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
chmod 700 "$WORKDIR"

# fleet.yaml が無ければ、サイト名から機械的に決まるデフォルト設定を
# その場限り(WORKDIR配下)で生成して使う。リポジトリには何も残らない。
if [[ -f "$FLEET_YAML" ]]; then
  echo "envs/$ENV_NAME/sites/$SITE/fleet.yaml の設定を使用します。" >&2
else
  echo "fleet.yamlが無いため、デフォルト設定をその場で生成して使用します。" >&2
  FLEET_YAML="$WORKDIR/default-fleet-values.yaml"
  cat >"$FLEET_YAML" <<EOF
helm:
  chart: $DEFAULT_CHART_REF
  version: "$DEFAULT_CHART_VERSION"
  values:
    wordpress:
      existingSecret: $CREDENTIALS_SECRET
      mariadb:
        auth:
          existingSecret: $MARIADB_SECRET
EOF
fi

# 認証情報のSecretが1つも無ければ初回デプロイとみなし、bootstrap-site-secrets.sh で
# サイト専用のランダムパスワードを生成する(3つとも揃っていれば何もしない。
# 一部だけ存在する場合は同スクリプトがエラーで中断する)。
"$SCRIPT_DIR/bootstrap-site-secrets.sh" "$SITE"

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

# レジストリ障害時はリポジトリ内のチャートで代替できる(Fleetが適用するものと
# 同一内容になるよう、fleet.yamlのhelm.versionと一致するか確認する)。
if [[ "${CHART_LOCAL:-}" == "1" ]]; then
  CHART="$REPO_ROOT/charts/ibid-wordpress"
  LOCAL_VERSION="$(python3 -c "import yaml;print(yaml.safe_load(open('$CHART/Chart.yaml'))['version'])")"
  if [[ "$LOCAL_VERSION" != "$VERSION" ]]; then
    echo "警告: ローカルチャートのversion($LOCAL_VERSION)がfleet.yamlのversion($VERSION)と異なります。" >&2
    echo "      ローカルチャートの内容でデプロイします。" >&2
  fi
  helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
  helm dependency build "$CHART" >/dev/null
  helm upgrade --install "$RELEASE_NAME" "$CHART" \
    -n "$NAMESPACE" --create-namespace \
    -f "$FLEET_VALUES" \
    -f "$SECRET_VALUES" \
    "$@"
else
  helm upgrade --install "$RELEASE_NAME" "$CHART" \
    --version "$VERSION" \
    -n "$NAMESPACE" --create-namespace \
    -f "$FLEET_VALUES" \
    -f "$SECRET_VALUES" \
    "$@"
fi
