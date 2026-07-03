# 全サイト共通のカスタムWordPressイメージ。
#
# 背景: 2025年後半のBroadcom移行以降、docker.io/bitnami の無償イメージは `latest` タグ
# しか提供されない(バージョン付きタグは有償のSecure Imagesのみ)。数十サイトを本番運用
# する上で「いつ何が動いているか」をGitで固定するため、latestをdigestで固定した上で
# 自前タグ(images/wordpress/TAG)を付けてGHCRへ公開する。
#
# ビルド/公開: mainへのマージで .github/workflows/build-image.yaml が
#   ghcr.io/silver198545/wordpress:<TAGファイルの内容> を公開する。
#
# 更新手順:
#   1. 新しいdigestを確認: docker manifest inspect などで docker.io/bitnami/wordpress:latest
#   2. 下のFROMのdigestを差し替え、TAGファイルの値を上げる(例: 7.0.0-r0 → 7.0.0-r1)
#   3. PR→マージでイメージが公開されたら、charts/ibid-wordpress/values.yaml の
#      image.* をこのイメージ/タグに切り替え(またはdigest更新)、チャートバージョンを
#      上げて環境ごとに昇格させる
#
# プラグイン/テーマをGit管理(全環境で同一版を保証)したくなったら、ここに
# COPY/RUN を追加して焼き込む(Bitnamiイメージの配置先は /opt/bitnami/wordpress)。
FROM docker.io/bitnami/wordpress:latest@sha256:39d337946920c27adea7b0495692ab7c11734a2bd32564edb5a415d5ecf137bd

# 例: プラグインを焼き込む場合
# COPY plugins/my-plugin /opt/bitnami/wordpress/wp-content/plugins/my-plugin
