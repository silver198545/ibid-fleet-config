#!/usr/bin/env bash
# 既存サイトのバックアップ(tar.lzo + dump.lzo)を、稼働中のWordPressサイトへリストアする。
# docs/manual-wordpress-restore.md の手順0(事前確認)と手順3〜5(転送・wp-content復元・
# DB復元)を自動化したもの。
#
# 対象とするバックアップ形式(ディレクトリ名=バックアップ元サイト名):
#   <バックアップディレクトリ>/yyyymmdd_hhmm.tar.lzo  ... サイトルート一式のtar(lzop圧縮)。
#       wp-content 以外のファイル(WordPress本体等)も含まれるが、復元に使うのは
#       wp-content のみ(本体はコンテナイメージ側のものを使うため、上書きしてはいけない)
#   <バックアップディレクトリ>/yyyymmdd_hhmm.dump.lzo ... mysqldumpのプレーンSQL(lzop圧縮)
#
# 転送方式: kubectl exec の1本の長いストリームは、Rancherプロキシ経由などで途中の
# i/oタイムアウトにより切断されることがある(実際にdev1で発生)。そのため、
#   1. 圧縮したファイルを小さなチャンクに分割し、1チャンクずつ転送する
#      (チャンクごとにサイズを検証し、失敗したチャンクだけ再試行する)
#   2. 展開・DBインポートはPod内に置いたファイルから行う(その間はハートビートを
#      出力し続けて、無出力による切断を防ぐ)
# という2段構えにしている。転送が終わるまで既存のwp-content/DBには手を付けないので、
# 転送中に失敗してもサイトは元のまま残る。
#
# 自動化しない(できない)手順 — 実行前後に必ず docs/manual-wordpress-restore.md を確認すること:
#   - 手順1: Longhornスナップショット取得(実行前に必ずLonghorn UIで取る)
#   - 手順2: テーブル接頭辞が食い違う場合の fleet.yaml 修正とPVC再作成
#     (このスクリプトは食い違いを検出したらエラーで中断するのみ)
#   - 手順6: URL置換(終了時に実行すべきコマンドを表示する)
#   - 手順7: 動作確認
#
# 前提:
#   - kubectl が対象環境のクラスタを指すよう設定済みであること
#   - lzop がローカルにインストール済みであること
#   - 対象サイトのwordpress/mariadb PodがRunningであること
#
# 使い方:
#   scripts/restore-wordpress.sh <サイト名> <バックアップディレクトリ> [yyyymmdd_hhmm]
#   例: scripts/restore-wordpress.sh web /backups/oldsite                 # 最新を使用
#       scripts/restore-wordpress.sh web /backups/oldsite 20260630_0300   # 時刻指定
#
# 環境変数:
#   IBID_ASSUME_YES=1        ... 確認プロンプトを省略する
#   RESTORE_CHUNK_SIZE=<size> ... 分割転送のチャンクサイズ(既定: 32m。接続が不安定なら
#                                小さくする。splitの-b書式)
#   TMPDIR=<path>            ... 作業ディレクトリの場所(既定は/tmp)。wp-contentの展開と
#                                再圧縮に使うため、展開後サイズ+圧縮サイズ分の空きが必要
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "使い方: $0 <サイト名> <バックアップディレクトリ> [yyyymmdd_hhmm]" >&2
  echo "例: $0 web /backups/oldsite" >&2
  exit 1
fi

SITE="$1"
BACKUP_DIR="$2"
TIMESTAMP="${3:-}"

if [[ ! "$SITE" =~ ^[a-z0-9-]+$ ]]; then
  echo "エラー: サイト名は英小文字・数字・ハイフンのみ使用できます: $SITE" >&2
  exit 1
fi
if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "エラー: バックアップディレクトリが見つかりません: $BACKUP_DIR" >&2
  exit 1
fi

NAMESPACE="wordpress-$SITE"
MARIADB_SECRET="wordpress-$SITE-mariadb-credentials"
DB_NAME="bitnami_wordpress"
WP_ROOT="/bitnami/wordpress"
REMOTE_TMP="/tmp/ibid-restore"
CHUNK_SIZE="${RESTORE_CHUNK_SIZE:-32m}"

for cmd in kubectl lzop tar gzip split; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "エラー: '$cmd' が見つかりません。インストールしてから再実行してください。" >&2
    exit 1
  fi
done

# --- バックアップファイルの特定(時刻未指定なら最新のペアを使う) ---
if [[ -z "$TIMESTAMP" ]]; then
  TAR_LZO="$(find "$BACKUP_DIR" -maxdepth 1 -name '[0-9]*_[0-9]*.tar.lzo' | sort | tail -1)"
  if [[ -z "$TAR_LZO" ]]; then
    echo "エラー: $BACKUP_DIR に yyyymmdd_hhmm.tar.lzo 形式のファイルがありません。" >&2
    exit 1
  fi
  TIMESTAMP="$(basename "$TAR_LZO" .tar.lzo)"
else
  TAR_LZO="$BACKUP_DIR/$TIMESTAMP.tar.lzo"
fi
DUMP_LZO="$BACKUP_DIR/$TIMESTAMP.dump.lzo"

for f in "$TAR_LZO" "$DUMP_LZO"; do
  if [[ ! -f "$f" ]]; then
    echo "エラー: バックアップファイルが見つかりません: $f" >&2
    echo "(tar.lzo と dump.lzo は同じ時刻のペアで揃っている必要があります)" >&2
    exit 1
  fi
done

# --- 対象Podの特定 ---
CONTEXT="$(kubectl config current-context)"
WP_POD="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=wordpress \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
DB_POD="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=mariadb \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$WP_POD" || -z "$DB_POD" ]]; then
  echo "エラー: '$NAMESPACE' にRunningなwordpress/mariadb Podが見つかりません" >&2
  echo "(kubectlコンテキスト: $CONTEXT)。サイトが稼働していることを確認してください。" >&2
  exit 1
fi

kexec_wp() { kubectl -n "$NAMESPACE" exec -c wordpress "$WP_POD" -- "$@"; }
kexec_db() { kubectl -n "$NAMESPACE" exec -c mariadb "$DB_POD" -- "$@"; }

# 前回のリストアの退避ディレクトリが残っていると上書きしてしまうため中断する。
if kexec_wp test -e "$WP_ROOT/wp-content.orig" 2>/dev/null; then
  echo "エラー: $WP_ROOT/wp-content.orig が既に存在します(前回リストアの退避分)。" >&2
  echo "内容を確認のうえ削除してから再実行してください:" >&2
  echo "  kubectl -n $NAMESPACE exec -c wordpress $WP_POD -- rm -rf $WP_ROOT/wp-content.orig" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
chmod 700 "$WORKDIR"

# --- ヘルパー ---

# ファイルをチャンクに分割してPodの$REMOTE_TMPへ転送する。チャンクごとに
# 転送後のサイズを検証し、失敗・不一致なら3回まで再試行する。
# 使い方: transfer_to_pod <pod> <コンテナ名> <ローカルファイル>
transfer_to_pod() {
  local pod="$1" container="$2" src="$3"
  local dir="$WORKDIR/chunks" chunk base size attempt remote_size total i=0
  rm -rf "$dir"
  mkdir -p "$dir"
  split -b "$CHUNK_SIZE" -a 4 -d "$src" "$dir/chunk_"
  total="$(find "$dir" -name 'chunk_*' | wc -l)"
  kubectl -n "$NAMESPACE" exec -c "$container" "$pod" -- \
    bash -c "rm -rf $REMOTE_TMP && mkdir -p $REMOTE_TMP"
  for chunk in "$dir"/chunk_*; do
    base="$(basename "$chunk")"
    size="$(wc -c <"$chunk")"
    i=$((i + 1))
    for attempt in 1 2 3; do
      if kubectl -n "$NAMESPACE" exec -i -c "$container" "$pod" -- \
        bash -c "cat >$REMOTE_TMP/$base" <"$chunk"; then
        remote_size="$(kubectl -n "$NAMESPACE" exec -c "$container" "$pod" -- \
          bash -c "wc -c <$REMOTE_TMP/$base" | tr -d '[:space:]')"
        if [[ "$remote_size" == "$size" ]]; then
          echo "  チャンク $i/$total 転送済み" >&2
          continue 2
        fi
      fi
      echo "  チャンク $base の転送に失敗しました(試行 $attempt/3)。再試行します..." >&2
      sleep 3
    done
    echo "エラー: チャンク $base の転送に3回失敗しました。" >&2
    echo "RESTORE_CHUNK_SIZE を小さくして(例: RESTORE_CHUNK_SIZE=8m)再実行してみてください。" >&2
    return 1
  done
}

# 長時間かかるコマンドをPod内で実行する。無出力が続くと途中の機器に接続を
# 切られることがあるため、完了までハートビートを出力し続ける。
# 使い方: exec_with_heartbeat <pod> <コンテナ名> <コマンド文字列> [env VAR=VALUE...]
exec_with_heartbeat() {
  local pod="$1" container="$2" cmd="$3"
  shift 3
  kubectl -n "$NAMESPACE" exec -c "$container" "$pod" -- env "$@" bash -c \
    "set -o pipefail; ( $cmd ) & p=\$!; while kill -0 \$p 2>/dev/null; do echo '  ...実行中'; sleep 15; done; wait \$p"
}

# --- 手順0: DBダンプの事前確認 ---
echo "DBダンプを解凍して内容を確認します..." >&2
DUMP_SQL="$WORKDIR/backup.dump"
lzop -dc "$DUMP_LZO" >"$DUMP_SQL"

# プレーンSQLであること("-- MySQL dump"等のテキストで始まること)を確認する。
FIRST_LINE="$(head -n 1 "$DUMP_SQL")"
case "$FIRST_LINE" in
  --*|/\**|SET*|CREATE*|DROP*) ;;
  *)
    echo "エラー: ダンプがプレーンSQLに見えません(先頭行: ${FIRST_LINE:0:60})。" >&2
    echo "バイナリ形式等の場合は別途プレーンSQLへ変換してください。" >&2
    exit 1
    ;;
esac

# CREATE DATABASE / USE 行が入っていると意図しないDBへ書き込まれるため取り除く。
if grep -qaE '^(CREATE DATABASE|USE `)' "$DUMP_SQL"; then
  echo "注意: ダンプに CREATE DATABASE / USE 行が含まれていたため、除去して続行します。" >&2
  sed -E '/^(CREATE DATABASE|USE `)/d' "$DUMP_SQL" >"$DUMP_SQL.clean"
  mv "$DUMP_SQL.clean" "$DUMP_SQL"
fi

# --- 手順2: テーブル接頭辞の突き合わせ ---
# ダンプ側: <prefix>options / <prefix>posts / <prefix>users が揃う接頭辞を探す。
# (単に "options" で終わるテーブル名だと、プラグインのテーブルを誤検出しうるため)
mapfile -t DUMP_TABLES < <(grep -aoE '^CREATE TABLE `[A-Za-z0-9_]+`' "$DUMP_SQL" \
  | sed 's/^CREATE TABLE `//; s/`$//' | sort -u)
DUMP_PREFIX=""
for t in "${DUMP_TABLES[@]}"; do
  case "$t" in
    *options)
      p="${t%options}"
      if printf '%s\n' "${DUMP_TABLES[@]}" | grep -qx "${p}posts" \
        && printf '%s\n' "${DUMP_TABLES[@]}" | grep -qx "${p}users"; then
        DUMP_PREFIX="$p"
        break
      fi
      ;;
  esac
done

# 復元先: wp-config.php の $table_prefix を読む(永続ボリューム上の実際の値)。
TARGET_PREFIX="$(kexec_wp sed -n 's/^\$table_prefix *= *.\([A-Za-z0-9_]*\).;.*/\1/p' "$WP_ROOT/wp-config.php")"
TARGET_PREFIX="${TARGET_PREFIX%%$'\n'*}"
if [[ -z "$TARGET_PREFIX" ]]; then
  echo "エラー: 復元先の wp-config.php からテーブル接頭辞を読み取れませんでした。" >&2
  exit 1
fi

if [[ -z "$DUMP_PREFIX" ]]; then
  echo "警告: ダンプからWordPressのテーブル接頭辞を特定できませんでした。" >&2
  echo "      復元先の接頭辞($TARGET_PREFIX)と一致しているか手動で確認してください。" >&2
elif [[ "$DUMP_PREFIX" != "$TARGET_PREFIX" ]]; then
  echo "エラー: テーブル接頭辞が一致しません。" >&2
  echo "  バックアップ側: $DUMP_PREFIX / 復元先($NAMESPACE): $TARGET_PREFIX" >&2
  echo "docs/manual-wordpress-restore.md の手順2に従い、fleet.yaml の wordpressTablePrefix を" >&2
  echo "設定してPVCを作り直してから再実行してください。" >&2
  exit 1
fi

# --- 実行確認 ---
cat >&2 <<EOF

===== リストア内容の確認 =====
  kubectlコンテキスト: $CONTEXT
  復元先サイト:        $SITE (namespace: $NAMESPACE)
  wp-content:          $TAR_LZO
  DBダンプ:            $DUMP_LZO
  テーブル接頭辞:      ${DUMP_PREFIX:-不明} -> $TARGET_PREFIX

このサイトの wp-content と DB($DB_NAME)を丸ごと上書きします。
実行前にLonghorn UIで両PVC(wp-content用/mariadb用)のスナップショットを取ってください
(docs/manual-wordpress-restore.md 手順1)。
EOF
if [[ "${IBID_ASSUME_YES:-}" != "1" ]]; then
  read -r -p "スナップショット取得済みで、上記の内容で実行してよければ y を入力: " REPLY
  if [[ "$REPLY" != "y" ]]; then
    echo "中断しました。" >&2
    exit 1
  fi
fi

# --- 手順3: バックアップの転送(ここまでは既存のwp-content/DBに手を付けない) ---
# tar.lzo にはサイトルート一式(WordPress本体を含む)が入っているため、
# まずアーカイブ内での wp-content の位置(パス接頭辞)を特定し、そこだけを取り出す。
echo "アーカイブ内の wp-content の位置を特定しています..." >&2
lzop -dc "$TAR_LZO" | tar tf - >"$WORKDIR/tar-list.txt"
if ! grep -qE '(^|/)wp-content/' "$WORKDIR/tar-list.txt"; then
  echo "エラー: アーカイブ内に wp-content ディレクトリが見つかりません: $TAR_LZO" >&2
  exit 1
fi
# 複数マッチした場合(テーマ内のwp-content等)は、最も浅い(=サイトルート直下の)ものを採用する。
WPC_PREFIX="$(grep -E '(^|/)wp-content/' "$WORKDIR/tar-list.txt" \
  | sed -E 's#(^|(.*/))wp-content/.*#\2#' \
  | awk 'NR==1 || length($0) < len { len = length($0); best = $0 } END { print best }')"

echo "wp-content を取り出して圧縮しています(アーカイブ内パス: ${WPC_PREFIX}wp-content)..." >&2
mkdir -p "$WORKDIR/extract"
lzop -dc "$TAR_LZO" | tar xf - -C "$WORKDIR/extract" "${WPC_PREFIX}wp-content"
tar cf - -C "$WORKDIR/extract/${WPC_PREFIX:-.}" wp-content | gzip >"$WORKDIR/wp-content.tar.gz"
rm -rf "$WORKDIR/extract"
gzip -c "$DUMP_SQL" >"$WORKDIR/dump.sql.gz"

echo "wp-content をwordpress Podへ転送します($(du -h "$WORKDIR/wp-content.tar.gz" | cut -f1))..." >&2
transfer_to_pod "$WP_POD" wordpress "$WORKDIR/wp-content.tar.gz"

echo "DBダンプをmariadb Podへ転送します($(du -h "$WORKDIR/dump.sql.gz" | cut -f1))..." >&2
transfer_to_pod "$DB_POD" mariadb "$WORKDIR/dump.sql.gz"

# --- 手順4: wp-content の復元 ---
echo "既存の wp-content を wp-content.orig へ退避します..." >&2
kexec_wp mv "$WP_ROOT/wp-content" "$WP_ROOT/wp-content.orig"

# wp-contentはRWX共有ボリュームなので、1つのPodで展開すれば全レプリカに反映される。
echo "wp-content をPod内で展開しています(サイズにより時間がかかります)..." >&2
exec_with_heartbeat "$WP_POD" wordpress \
  "cat $REMOTE_TMP/chunk_* | gunzip | tar xf - -C $WP_ROOT && rm -rf $REMOTE_TMP"

kexec_wp test -d "$WP_ROOT/wp-content"
echo "wp-content の復元が完了しました。" >&2

# --- 手順5: DBの復元 ---
echo "DB($DB_NAME)を初期化してダンプをインポートします..." >&2
ROOTPW="$(kubectl -n "$NAMESPACE" get secret "$MARIADB_SECRET" \
  -o jsonpath='{.data.mariadb-root-password}' | base64 -d)"

# (パスワードは引数に載せず MYSQL_PWD 環境変数で渡す)
kubectl -n "$NAMESPACE" exec -i -c mariadb "$DB_POD" -- env MYSQL_PWD="$ROOTPW" mysql -u root <<SQL
DROP DATABASE IF EXISTS $DB_NAME;
CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON $DB_NAME.* TO 'bn_wordpress'@'%';
FLUSH PRIVILEGES;
SQL

exec_with_heartbeat "$DB_POD" mariadb \
  "cat $REMOTE_TMP/chunk_* | gunzip | mysql -u root $DB_NAME && rm -rf $REMOTE_TMP" \
  MYSQL_PWD="$ROOTPW"

echo "インポート後のテーブル一覧:" >&2
kexec_db env MYSQL_PWD="$ROOTPW" mysql -u root "$DB_NAME" -e "SHOW TABLES;" >&2

# --- 残りの手動手順の案内 ---
SITEURL="$(kexec_db env MYSQL_PWD="$ROOTPW" mysql -u root "$DB_NAME" -N \
  -e "SELECT option_value FROM ${TARGET_PREFIX}options WHERE option_name='siteurl';" 2>/dev/null || true)"
LB_IP="$(kubectl -n "$NAMESPACE" get svc "wordpress-$SITE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

cat >&2 <<EOF

リストアが完了しました。残りの手順(docs/manual-wordpress-restore.md 手順6〜7):

1. URLが変わる場合は置換する(復元されたsiteurl: ${SITEURL:-取得失敗} / LBのIP: ${LB_IP:-取得失敗}):
     kubectl -n $NAMESPACE exec -c wordpress $WP_POD -- wp search-replace \\
       '${SITEURL:-http://旧ドメイン}' 'http://新ドメインまたは${LB_IP:-LB-IP}' --all-tables --precise
     kubectl -n $NAMESPACE exec -c wordpress $WP_POD -- wp rewrite flush --hard

2. 動作確認(トップページ・パーマリンク・/wp-admin/ログイン・メディア表示・プラグイン)

3. 確認が済んだら退避した旧wp-contentを削除する:
     kubectl -n $NAMESPACE exec -c wordpress $WP_POD -- rm -rf $WP_ROOT/wp-content.orig
EOF
