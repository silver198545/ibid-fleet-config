# SPARQList (https://github.com/dbcls/sparqlist, mainブランチ)のExpressサーバーを
# 実行するイメージ。
#
# ビルド元は公開リポジトリ(dbcls/sparqlist)。WordPressのdigest固定と同じく
# 「何が動いているか」をコミットSHAで固定する運用にするため、ソース取得は
# Dockerfile内でgit cloneせず、.github/workflows/build-sparqlist-image.yaml の
# actions/checkoutステップ(SRC_REFファイルの内容をrefに指定)で行い、ビルド
# コンテキストの app/ ディレクトリとして渡す(公開リポジトリのため認証情報は不要。
# images/brc-advanced-search・images/riken-diips のようなDeploy Key/PATは無し)。
# GHCRへの公開は mainへのマージで同ワークフローが行う(パッケージは公開設定):
#   ghcr.io/silver198545/sparqlist:<TAGファイルの内容>
#
# ROOT_PATH: 既存運用(オンプレ)で /sparqlist/ サブディレクトリ配下に置かれているため、
# この構成でも同じサブパスを維持する(docs/manual-apps.md参照)。frontendの
# vite.config.jsがビルド時にprocess.env.ROOT_PATHをbase(アセットURLの接頭辞)へ
# 埋め込み、index.mjsが実行時にpathPrefixとして同じ値を読むため、ビルド時・実行時で
# 必ず同じ値である必要がある。Deployment側で指定させず、この2ステージに固定で
# 焼き込むことで値のズレを防ぐ。
#
# 更新手順:
#   1. アプリ側(mainブランチ)の取り込みたいコミットのSHAを SRC_REF に書く
#   2. TAG を上げる(例: 1.0.0-r0 → 1.0.0-r1)
#   3. PR→マージでイメージが公開されたら、envs/dev/apps/sparqlist/deployment.yaml の
#      image タグを切り替え、dev確認後にstaging/productionへ手動で反映する
#      (docs/manual-apps.md参照)
FROM node:24-bookworm AS build

WORKDIR /app
ENV ROOT_PATH=/sparqlist/
COPY app/ .
# 上流のlockfileより新しいパッチ版を使う依存がある(2026-10-27〜)。handlebarsは直接の依存なので版を書き換え
# (overridesだと直接の依存と矛盾してnpmが止まる)、proxy-addr(express経由)はoverridesで上げる。
# lockfileを直すため npm ci ではなく npm install にする。上流(dbcls/sparqlist)のlockfileが
# これ以上の版になったら、この2行を外して npm ci に戻す
RUN npm pkg set dependencies.handlebars=4.7.10 overrides.proxy-addr=2.0.8 \
  && npm install --no-audit --no-fund
RUN npm run build
# 実行時に不要なdevDependencies(vite/playwright等)を落とす。
RUN npm prune --omit=dev

FROM node:24-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
ENV ROOT_PATH=/sparqlist/
COPY --from=build --chown=node:node /app ./
USER node
EXPOSE 3000
CMD ["npm", "start"]
