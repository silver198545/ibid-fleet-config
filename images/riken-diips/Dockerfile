# riken-diips (https://github.com/PENQEinc/riken-diips, mainブランチ)の
# Next.js 15 SSRサーバーを実行するイメージ。
#
# ビルド元はこのリポジトリ管理外のアプリ(プライベートリポジトリ)。
# 「何が動いているか」をコミットSHAで固定する運用は images/wordpress や
# images/brc-advanced-search と同じだが、認証情報をDockerイメージのレイヤー履歴に
# 残さないため、ソース取得は Dockerfile内でgit cloneせず、
# .github/workflows/build-riken-diips-image.yaml の actions/checkoutステップ
# (SRC_REFファイルの内容をrefに指定)で行い、ビルドコンテキストの app/ ディレクトリ
# として渡す。GHCRへの公開は mainへのマージで同ワークフローが行う:
#   ghcr.io/silver198545/riken-diips:<TAGファイルの内容>
#
# 更新手順:
#   1. アプリ側(mainブランチ)の取り込みたいコミットのSHAを SRC_REF に書く
#   2. TAG を上げる(例: 0.1.0-r0 → 0.1.0-r1)
#   3. PR→マージでイメージが公開されたら、envs/dev/apps/riken-diips/deployment.yaml の
#      image タグを切り替え、dev確認後にstaging/productionへ手動で反映する
#      (docs/manual-apps.md参照)
FROM node:20-bullseye AS build

WORKDIR /app
COPY app/ .
RUN npm install
RUN npm run build
# 実行時に不要なdevDependencies(eslint/jest/typescript等)を落とす。
RUN npm prune --omit=dev

FROM node:20-bullseye-slim
WORKDIR /app
ENV NODE_ENV=production
# next startが待ち受けるポート。Service/Deploymentからの到達性のため明示する。
ENV PORT=3000
COPY --from=build --chown=node:node /app ./
USER node
EXPOSE 3000
CMD ["npm", "run", "start"]
