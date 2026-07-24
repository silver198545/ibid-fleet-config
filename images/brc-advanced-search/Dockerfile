# riken_brc_advanced_search (https://github.com/PENQEinc/riken_brc_advanced_search) を
# 静的サイトとしてビルドし、nginxで配信するイメージ。
#
# ビルド元はこのリポジトリ管理外のアプリ(プライベートリポジトリ)。
# 「何が動いているか」をコミットSHAで固定する運用は images/wordpress と同じだが、
# 認証情報をDockerイメージのレイヤー履歴に残さないため、ソース取得は
# Dockerfile内でgit cloneせず、.github/workflows/build-brc-advanced-search-image.yaml の
# actions/checkoutステップ(SRC_REFファイルの内容をrefに指定)で行い、
# ビルドコンテキストの app/ ディレクトリとして渡す。
# GHCRへの公開は mainへのマージで同ワークフローが行う:
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

WORKDIR /src
COPY app/ .
# package-lock.json(2024年1月頃生成)には、npm側でのtarball再ハッシュ化により
# integrityが現在のレジストリと食い違うパッケージが複数あり(axios@1.6.0で確認済み)、
# さらに個別の破損エントリ(@vue/component-compiler-utils配下のpostcssが、本来必要な
# postcss@^7.0.36ではなくトップレベルのpostcss@8.4.32のコピーに誤って上書きされ、
# versionフィールドも"postcss@8.4.32"のように壊れている)も混入している。
# 1件ずつ補正するのは持続的でないため、lockfileを使わずpackage.jsonから解決し直す。
RUN rm -f package-lock.json && npm install
# SSRサーバーは立てず、静的サイトとして生成する。
# 出力先(brc_advanced)とURLのベースパス(/advanced、NODE_ENV=production時)は
# アプリ側 nuxt.config.js の generate.dir / router.base に由来する。
RUN npm run generate-production

FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=build /src/brc_advanced /usr/share/nginx/html/advanced
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
