# riken_brc_advanced_search (https://github.com/PENQEinc/riken_brc_advanced_search) を
# 静的サイトとしてビルドし、nginxで配信するイメージ。
#
# ビルド元はこのリポジトリ管理外のアプリなので、images/wordpress と同様に
# 「何が動いているか」をコミットSHAで固定する(SRC_REFファイル)。
# GHCRへの公開は mainへのマージで .github/workflows/build-brc-advanced-search-image.yaml が行う:
#   ghcr.io/silver198545/brc-advanced-search:<TAGファイルの内容>
#
# 更新手順:
#   1. アプリ側の取り込みたいコミットのSHAを SRC_REF に書く
#   2. TAG を上げる(例: 1.0.0-r0 → 1.0.0-r1)
#   3. PR→マージでイメージが公開されたら、envs/dev/apps/brc-advanced-search/deployment.yaml の
#      image タグを切り替え、dev確認後にstaging/productionへ手動で反映する
#      (promoteワークフローは envs/<env>/sites/ のみが対象のため、apps/ は
#      docs/manual-apps.md の手順に従い手動でコピーする)
FROM node:16-bullseye AS build

# fibers (sass-loaderの依存)のネイティブビルドにはgit/python/make/g++が要る。
# node:16-bullseyeにはpython3/make/g++が同梱済みのため、gitのみ追加する。
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
ARG SRC_REPO=https://github.com/PENQEinc/riken_brc_advanced_search.git
ARG SRC_REF
RUN test -n "$SRC_REF" && git clone "$SRC_REPO" . && git checkout "$SRC_REF"

RUN npm ci
# SSRサーバーは立てず、静的サイトとして生成する。
# 出力先(brc_advanced)とURLのベースパス(/advanced、NODE_ENV=production時)は
# アプリ側 nuxt.config.js の generate.dir / router.base に由来する。
RUN npm run generate-production

FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=build /src/brc_advanced /usr/share/nginx/html/advanced
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
