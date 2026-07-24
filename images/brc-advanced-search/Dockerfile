# riken_brc_advanced_search (https://github.com/PENQEinc/riken_brc_advanced_search,
# vue3-main-rikenブランチ)のNuxt 3 SSRサーバーを実行するイメージ。
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
#   1. アプリ側(vue3-main-rikenブランチ)の取り込みたいコミットのSHAを SRC_REF に書く
#   2. TAG を上げる(例: 2.0.0-r0 → 2.0.0-r1)
#   3. PR→マージでイメージが公開されたら、envs/dev/apps/brc-advanced-search/deployment.yaml の
#      image タグを切り替え、dev確認後にstaging/productionへ手動で反映する
#      (promoteワークフローは envs/<env>/sites/ のみが対象のため、apps/ は
#      docs/manual-apps.md の手順に従い手動でコピーする)
FROM node:20-bullseye AS build

WORKDIR /src
COPY app/ .
# @nuxtjs/i18n(SSR)は、Nitro側でリクエストごとの非同期コンテキストが有効でないと
# "Nuxt I18n server context has not been set up yet" 500エラーになる既知の問題がある。
# アプリ側nuxt.config.tsにexperimental.asyncContextの設定が無いため、ビルド前に補う。
# アプリ側での恒久対応(nuxt.config.tsへの追記)が本来の直し方。
RUN sed -i "s/^export default defineNuxtConfig({/export default defineNuxtConfig({\n  experimental: { asyncContext: true },/" nuxt.config.ts
RUN npm install
# ビルドスクリプトがNODE_OPTIONS=--max_old_space_size=8192を指定している
# (Viteビルドがメモリを要求するため)。Nitroのnode-serverプリセットにより
# .output/ 配下に実行可能なサーバー一式が出力される。
RUN npm run build

FROM node:20-bullseye-slim
WORKDIR /app
ENV NODE_ENV=production
# Nitro node-serverはデフォルトで0.0.0.0:3000を待ち受けるが、
# コンテナ外(Service)からの到達性のため明示しておく。
ENV HOST=0.0.0.0
ENV PORT=3000
COPY --from=build --chown=node:node /src/.output ./.output
USER node
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]
