#!/usr/bin/env bash
# 指定環境のWordPressサイト用Fleetバンドル(envs/<env>/sites/<site>/fleet.yaml)を
# ひな形から生成する。Fleet管理下のサイトはこのファイルが適用の起点になるため、
# サイトを追加する際は必ず実行する(旧構成と異なり任意ではない)。
#
# 生成後の流れ(詳細は docs/manual-wordpress.md):
#   1. scripts/bootstrap-site-secrets.sh <site> で対象クラスタにSecretを作成
#   2. 生成されたfleet.yamlを必要に応じて編集(テーブル接頭辞の上書き等)
#   3. PRを作成してマージ → 対象環境のFleetが自動適用
#
# サイトは原則devに追加し、staging/productionへは昇格PR
# (.github/workflows/promote.yaml)で展開する。
#
# 使い方:
#   scripts/new-wordpress-site.sh <env> <site>
#   例: scripts/new-wordpress-site.sh dev web
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ラッパーチャート(charts/ibid-wordpress)の参照先。チャートを更新したら
# ここではなく、各環境のfleet.yamlのhelm.versionを昇格させて追従する。
CHART_REF="oci://ghcr.io/silver198545/charts/ibid-wordpress"
CHART_VERSION="0.2.0"

if [[ $# -ne 2 ]]; then
  echo "使い方: $0 <env> <site>" >&2
  echo "例: $0 dev web" >&2
  exit 1
fi

ENV_NAME="$1"
SITE="$2"

case "$ENV_NAME" in
  dev|staging|production) ;;
  *)
    echo "エラー: envは dev / staging / production のいずれかを指定してください: $ENV_NAME" >&2
    exit 1
    ;;
esac

if [[ ! "$SITE" =~ ^[a-z0-9-]+$ ]]; then
  echo "エラー: サイト名は英小文字・数字・ハイフンのみ使用できます: $SITE" >&2
  exit 1
fi

SITE_DIR="$REPO_ROOT/envs/$ENV_NAME/sites/$SITE"
if [[ -e "$SITE_DIR" ]]; then
  echo "エラー: $SITE_DIR は既に存在します。" >&2
  exit 1
fi

mkdir -p "$SITE_DIR"

cat >"$SITE_DIR/fleet.yaml" <<EOF
defaultNamespace: wordpress-$SITE
targetNamespace: wordpress-$SITE

# このサイトをGitから削除してもFleetにリソース(PVC=データ含む)を削除させない。
# サイトの完全削除は docs/manual-wordpress.md の手順に従って手動で行う。
keepResources: true

helm:
  # リリース名を明示する(Fleetのバンドル名由来の自動命名にしない)。
  # 既存の手動デプロイ済みリリースをFleetが引き継ぐためにも必須。
  releaseName: wordpress-$SITE
  # 全サイト共通デフォルトを内包したラッパーチャート(charts/ibid-wordpress)。
  # バージョンを上げる=このサイトへの変更適用。環境ごとに段階的に昇格させる。
  chart: $CHART_REF
  version: "$CHART_VERSION"
  # BitnamiのmariadbサブチャートはHelmアップグレード時、existingSecretを
  # 使っていてもauth.rootPassword/auth.passwordの明示指定を要求してくる
  # (PASSWORDS ERROR)。Gitにパスワードを書かないよう、
  # scripts/bootstrap-site-secrets.sh で事前作成したSecret経由で注入する。
  valuesFrom:
    - secretKeyRef:
        name: wordpress-$SITE-mariadb-upgrade-values
        namespace: wordpress-$SITE
        key: values.yaml
  # 共通のデフォルト値はラッパーチャート側にまとめてある。ここにはこのサイト固有の
  # 差分のみを書く。Bitnamiサブチャートへ渡す値は wordpress: 配下に、ラッパー
  # チャート自身の設定(plugins等)は values 直下に置く。
  values:
    # このサイトが必要とするプラグイン(宣言的)。適用のたびにwp-cliのJobが
    # インストール(バージョン固定)・有効化する。再現性のためversion明示を推奨。
    # 一覧から消しても自動削除はしない(削除は手動)。docs/manual-wordpress.md参照。
    # plugins:
    #   - name: advanced-custom-fields
    #     version: "6.8.4"
    wordpress:
      # 管理者パスワードはGitに含めず、事前に作成したSecretを参照する。
      existingSecret: wordpress-$SITE-credentials
      mariadb:
        auth:
          existingSecret: wordpress-$SITE-mariadb-credentials

# Kubernetes APIはNetworkPolicyのportsにprotocol: TCPを自動補完するが、
# Bitnamiチャートのマニフェストには無いため、Fleetが常時「Modified」と
# 誤検知する。ingress部分を差分比較の対象から除外して抑止する。
diff:
  comparePatches:
    - apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: wordpress-$SITE
      namespace: wordpress-$SITE
      jsonPointers:
        - /spec/ingress
    - apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: wordpress-$SITE-mariadb
      namespace: wordpress-$SITE
      jsonPointers:
        - /spec/ingress
EOF

echo "作成しました: $SITE_DIR/fleet.yaml"
echo "次の手順は docs/manual-wordpress.md を参照してください。"
