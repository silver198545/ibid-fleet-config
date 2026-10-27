# riken-diips (https://github.com/PENQEinc/riken-diips, mainブランチ)の
# Next.js 15 SSRサーバーを実行するイメージ。
#
# ビルド元はこのリポジトリ管理外のアプリ(プライベートリポジトリ)。
# 「何が動いているか」をコミットSHAで固定する運用は images/brc-advanced-search と
# 同じだが、認証情報をDockerイメージのレイヤー履歴に
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
FROM node:26.12.1-bookworm AS build

WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY app/ .
RUN npm ci --no-audit --no-fund
RUN npm run build

# 実行は Next.js の standalone 出力(上流の next.config.js の output: 'standalone'。2026-10-27〜)。
# 実行に要るファイルだけが .next/standalone に集められるので、node_modules を丸ごと持ち込まない。
# 静的ファイル(.next/static・public)と、APIルート・ページの描画が実行時に読む src/data・src/content は
# standalone に入らないので別にコピーする(上流の Dockerfile と同じ)。
FROM node:26.12.1-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0
COPY --from=build --chown=node:node /app/.next/standalone ./
COPY --from=build --chown=node:node /app/.next/static ./.next/static
COPY --from=build --chown=node:node /app/public ./public
COPY --from=build --chown=node:node /app/src/data ./src/data
COPY --from=build --chown=node:node /app/src/content ./src/content
USER node
EXPOSE 3000
CMD ["node", "server.js"]
