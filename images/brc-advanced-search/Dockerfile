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
# 実運用(PENQEinc側サーバー)ではPM2 + `nuxt start`(node_modules込みのフル構成)で
# 素のpackage.json/package-lock.jsonのまま動作実績がある。そのため
# experimental.asyncContext追加・@nuxtjs/i18n強制アップグレード・Node22化は
# 行わず、素の npm install + npm run build + nuxt start に合わせる
# (K8sでのプロセス並列化はPM2のclusterモードではなくDeploymentのreplicasで行う)。
#
# 更新手順:
#   1. アプリ側(vue3-main-rikenブランチ)の取り込みたいコミットのSHAを SRC_REF に書く
#   2. TAG を上げる(例: 2.0.0-r0 → 2.0.0-r1)
#   3. PR→マージでイメージが公開されたら、envs/dev/apps/brc-advanced-search/deployment.yaml の
#      image タグを切り替え、dev確認後にstaging/productionへ手動で反映する
#      (promoteワークフローは envs/<env>/sites/ のみが対象のため、apps/ は
#      docs/manual-apps.md の手順に従い手動でコピーする)
FROM node:20-bullseye AS build

WORKDIR /app
COPY app/ .
RUN npm install
# ビルドスクリプトがNODE_OPTIONS=--max_old_space_size=8192を指定している
# (Viteビルドがメモリを要求するため)。
RUN npm run build
# 実行時に不要なdevDependencies(histoire/typescript/vue-tsc等)を落とす。
# nuxt自体はdependencies側なので残る。
RUN npm prune --omit=dev

FROM node:20-bullseye-slim
WORKDIR /app
ENV NODE_ENV=production
# nuxt startが待ち受けるホスト/ポート。Service/Deploymentからの到達性のため明示する。
ENV HOST=0.0.0.0
ENV PORT=3000
COPY --from=build --chown=node:node /app ./
USER node
EXPOSE 3000
# 実サーバーのPM2設定(script: node_modules/nuxt/bin/nuxt.mjs, args: start)と
# 同じ起動方式に合わせる。
CMD ["node_modules/.bin/nuxt", "start"]
