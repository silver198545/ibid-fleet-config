# member-gateway (https://github.com/silver198545/member-gateway、mainブランチ)の
# Fastifyサーバー(メールアドレスをkintoneに照会して会員状態を判定する)を実行するイメージ。
#
# ビルド元はこのリポジトリ管理外のアプリ(プライベートリポジトリ)。
# 「何が動いているか」をコミットSHAで固定する運用は images/metadatabase-v2 と同じで、
# 認証情報をDockerイメージのレイヤー履歴に残さないため、ソース取得は Dockerfile内で
# git cloneせず、.github/workflows/build-member-gateway-image.yaml の
# actions/checkoutステップ(SRC_REFファイルの内容をrefに指定)で行い、
# ビルドコンテキストの app/ ディレクトリとして渡す。GHCRへの公開は mainへのマージで
# 同ワークフローが行う:
#   ghcr.io/silver198545/member-gateway:<TAGファイルの内容>
#
# 中身はアプリ本家のDockerfileと同じ構成(ビルド時はdevDependencies込みでtsc、
# 実行時は--omit=devで入れ直してdist/とpublic/だけを置く)。COPY元をapp/に変えただけ。
# HOST/PORTはここで固定する(Deployment側で変えない。Service/probeは3000番前提)。
#
# 更新手順:
#   1. アプリ側(mainブランチ)の取り込みたいコミットのSHAを SRC_REF に書く
#   2. TAG を上げる(例: 0.2.0-r0 → 0.2.0-r1)
#   3. PR→マージでイメージが公開されたら、envs/dev/apps/member-gateway/deployment.yaml の
#      image タグを切り替え、dev確認後にproductionへ昇格する
#   (通常は scripts/update-app-image.sh set-image member-gateway <SHA> で一括。docs/manual-apps.md参照)

# ---- ビルド ----
FROM node:22-slim AS build
WORKDIR /app
COPY app/package.json app/package-lock.json ./
RUN npm ci
COPY app/tsconfig.json ./
COPY app/src ./src
RUN npm run build

# ---- 実行 ----
FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000
COPY app/package.json app/package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY app/public ./public

USER node
EXPOSE 3000
CMD ["node", "dist/server.js"]
