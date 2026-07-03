#!/usr/bin/env bash
# WordPressサイト1つ分の認証情報Secret(3種)を、kubectlのカレントコンテキストが指す
# クラスタへ作成する。Fleetがサイトのバンドル(envs/<env>/sites/<site>/fleet.yaml)を
# 適用する前に、環境(クラスタ)ごとに1回実行しておく必要がある。
#
# パスワードはサイトごと・環境ごとにランダム生成する(サイト間・環境間で使い回すと
# 1箇所の漏洩が他に波及するため)。生成したパスワードは実行の最後に標準エラー出力へ
# 一度だけ表示されるので、必ず控えること(Gitにも他の場所にも保存されない)。
#
# 作成するSecret(namespace: wordpress-<site>):
#   - wordpress-<site>-credentials             ... WordPress管理者パスワード
#   - wordpress-<site>-mariadb-credentials     ... MariaDB root/ユーザーパスワード
#   - wordpress-<site>-mariadb-upgrade-values  ... 同じ値のHelm values形式
#     (BitnamiのmariadbサブチャートはHelmアップグレード時、existingSecretを使っていても
#      auth.rootPassword/auth.passwordの明示指定を要求してくる=PASSWORDS ERROR対策。
#      Fleetは各サイトのfleet.yamlの helm.valuesFrom でこのSecretを読み込む。
#      値はラッパーチャート(charts/ibid-wordpress)向けに `wordpress:` 配下にネストする)
#
# 使い方:
#   kubectl config use-context <対象環境のコンテキスト>
#   scripts/bootstrap-site-secrets.sh <サイト名>
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "使い方: $0 <サイト名>" >&2
  echo "例: $0 web" >&2
  exit 1
fi

SITE="$1"
if [[ ! "$SITE" =~ ^[a-z0-9-]+$ ]]; then
  echo "エラー: サイト名は英小文字・数字・ハイフンのみ使用できます: $SITE" >&2
  exit 1
fi

NAMESPACE="wordpress-$SITE"
CREDENTIALS_SECRET="wordpress-$SITE-credentials"
MARIADB_SECRET="wordpress-$SITE-mariadb-credentials"
MARIADB_UPGRADE_SECRET="wordpress-$SITE-mariadb-upgrade-values"

for cmd in kubectl openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: '$cmd' が見つかりません。インストールしてから再実行してください。" >&2
    exit 1
  fi
done

CONTEXT="$(kubectl config current-context)"
echo "対象クラスタ(kubectlコンテキスト): $CONTEXT" >&2

# 一部だけ存在する場合(手動で作り直し中など)は意図しない上書きを避けるため中断する。
EXISTING=()
for s in "$CREDENTIALS_SECRET" "$MARIADB_SECRET" "$MARIADB_UPGRADE_SECRET"; do
  if kubectl -n "$NAMESPACE" get secret "$s" >/dev/null 2>&1; then
    EXISTING+=("$s")
  fi
done
if [[ ${#EXISTING[@]} -eq 3 ]]; then
  echo "3つのSecretはすべて作成済みです。何もしません。" >&2
  exit 0
elif [[ ${#EXISTING[@]} -gt 0 ]]; then
  echo "エラー: 一部のSecretのみが存在します(${EXISTING[*]})。" >&2
  echo "パスワードをローテーションする場合は3つとも削除してから再実行してください" >&2
  echo "(稼働中のMariaDBの実パスワードはSecretを作り直しても変わらない点に注意。" >&2
  echo " docs/manual-wordpress.md 参照)。" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
chmod 700 "$WORKDIR"

echo "'$NAMESPACE' 用に新規パスワードを生成してSecretを作成します。" >&2

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

WP_PASSWORD="$(openssl rand -base64 24)"
DB_ROOT_PASSWORD="$(openssl rand -base64 24)"
DB_PASSWORD="$(openssl rand -base64 24)"

kubectl -n "$NAMESPACE" create secret generic "$CREDENTIALS_SECRET" \
  --from-literal=wordpress-password="$WP_PASSWORD"

kubectl -n "$NAMESPACE" create secret generic "$MARIADB_SECRET" \
  --from-literal=mariadb-root-password="$DB_ROOT_PASSWORD" \
  --from-literal=mariadb-password="$DB_PASSWORD"

# ラッパーチャート(charts/ibid-wordpress)のvaluesとしてマージされるため、
# bitnami/wordpressサブチャートへの値は `wordpress:` 配下にネストする。
cat >"$WORKDIR/mariadb-upgrade-values.yaml" <<EOF
wordpress:
  mariadb:
    auth:
      rootPassword: "$DB_ROOT_PASSWORD"
      password: "$DB_PASSWORD"
EOF

kubectl -n "$NAMESPACE" create secret generic "$MARIADB_UPGRADE_SECRET" \
  --from-file=values.yaml="$WORKDIR/mariadb-upgrade-values.yaml"

cat >&2 <<EOF

生成したパスワード('$NAMESPACE' @ $CONTEXT。ここにしか表示されないので必ず控えてください):
  WordPress管理者(admin)パスワード:      $WP_PASSWORD
  MariaDB rootパスワード:               $DB_ROOT_PASSWORD
  MariaDB bn_wordpressユーザーパスワード: $DB_PASSWORD

EOF
