#!/usr/bin/env bash
# 新しいWordPressサイト用のディレクトリ(wordpress-<site>/fleet.yaml)をテンプレートから
# 生成する。生成後の手順(namespace/Secret作成・デプロイ)は
# docs/manual-wordpress.md を参照。
#
# 使い方:
#   scripts/new-wordpress-site.sh <site>
#   例: scripts/new-wordpress-site.sh web
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "使い方: $0 <site>" >&2
  echo "例: $0 web" >&2
  exit 1
fi

SITE="$1"
if [[ ! "$SITE" =~ ^[a-z0-9-]+$ ]]; then
  echo "エラー: サイト名は英小文字・数字・ハイフンのみ使用できます: $SITE" >&2
  exit 1
fi

SITE_DIR="$REPO_ROOT/wordpress-$SITE"
if [[ -e "$SITE_DIR" ]]; then
  echo "エラー: $SITE_DIR は既に存在します。" >&2
  exit 1
fi

mkdir -p "$SITE_DIR"

cat >"$SITE_DIR/fleet.yaml" <<EOF
defaultNamespace: wordpress-$SITE
targetNamespace: wordpress-$SITE

helm:
  chart: wordpress
  repo: https://charts.bitnami.com/bitnami
  version: 32.1.10
  # BitnamiのmariadbサブチャートはHelmアップグレード時、existingSecretを
  # 使っていてもauth.rootPassword/auth.passwordの明示指定を要求してくる
  # (PASSWORDS ERROR)。Gitにパスワードを書かないよう、事前に作成した
  # Secret経由でこれらの値を注入する。docs/manual-wordpress.md参照。
  valuesFrom:
    - secretKeyRef:
        name: wordpress-$SITE-mariadb-upgrade-values
        namespace: wordpress-$SITE
        key: values.yaml
  # 共通のデフォルト値は ../wordpress-base-values.yaml にまとめてあり、
  # scripts/deploy-wordpress.sh がここより先に読み込む。ここにはこのサイト固有の
  # 差分のみを書く。
  values:
    # 管理者パスワードは Git に含めず、事前に作成した Secret を参照する。
    # docs/manual-wordpress.md の手順に従って事前に作成すること。
    existingSecret: wordpress-$SITE-credentials

    mariadb:
      auth:
        existingSecret: wordpress-$SITE-mariadb-credentials
EOF

echo "作成しました: $SITE_DIR/fleet.yaml"
echo "次の手順は docs/manual-wordpress.md を参照してください。"
