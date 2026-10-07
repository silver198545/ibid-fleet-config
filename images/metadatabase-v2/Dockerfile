# metadatabase-v2 (https://github.com/silver198545/metadatabase-v2、mainブランチ)の
# Next.js 15 SSRサーバーを実行するイメージ。
#
# ビルド元はこのリポジトリ管理外のアプリ(プライベートリポジトリ)。
# 「何が動いているか」をコミットSHAで固定する運用は images/riken-diips と同じだが、
# 認証情報をDockerイメージのレイヤー履歴に残さないため、ソース取得は Dockerfile内で
# git cloneせず、.github/workflows/build-metadatabase-v2-image.yaml の
# actions/checkoutステップ(SRC_REFファイルの内容をrefに指定)で行い、
# ビルドコンテキストの app/ ディレクトリとして渡す。GHCRへの公開は mainへのマージで
# 同ワークフローが行う:
#   ghcr.io/silver198545/metadatabase-v2:<TAGファイルの内容>
#
# next.config.ts に output: "standalone" の指定は無いため、実行時もフルの
# node_modules が必要(riken-diipsと同じ構成)。
#
# 更新手順:
#   1. アプリ側(mainブランチ)の取り込みたいコミットのSHAを SRC_REF に書く
#   2. TAG を上げる(例: 0.1.0-r0 → 0.1.0-r1)
#   3. PR→マージでイメージが公開されたら、envs/dev/apps/metadatabase-v2/deployment.yaml の
#      image タグを切り替え、dev確認後にstaging/productionへ手動で反映する
#      (docs/manual-apps.md参照)
#
# bullseye(glibc 2.31)からbookwormへ変更(0.4.0rで管理画面機能が入った際):
# アプリがpackage.jsonでnode>=22を要求するようになり、better-sqlite3の
# prebuildバイナリもglibc 2.33以上を要求するため、bullseyeではERR_DLOPEN_FAILEDになる。
FROM node:22-bookworm AS build

WORKDIR /app
COPY app/ .
# actions/checkoutが取得したapp/には.gitが含まれる。マルチステージの最終イメージにも
# コピーされてしまうため(サイズ増加、プライベートソースの全履歴がイメージレイヤーに
# 残る)、依存インストール前に削除する。
RUN rm -rf .git
# better-sqlite3はネイティブモジュールのため、プリビルドバイナリがglibc/Node ABIと
# 合わない場合に備えてソースからのビルドツールを入れておく(アプリ本家のDockerfileと同じ対応)。
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*
RUN npm install
# アプリを置くパス。Next.jsのbasePathはビルド時に埋め込まれるため、ビルド引数で渡す
# (docs/manual-apps.md「metadatabase-v2 固有のメモ」参照。dev/staging/productionとも
# 同じ/tsukubaにする運用)。
ARG BASE_PATH=/tsukuba
ENV BASE_PATH=${BASE_PATH}
RUN npm run build
# 実行時に不要なdevDependencies(eslint/typescript等)を落とす。
RUN npm prune --omit=dev

FROM node:22-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
# next startが待ち受けるポート。Service/Deploymentからの到達性のため明示する。
ENV PORT=3000

# 管理画面のVirtuoso isql機能(データのロード・グラフURIの変更)で使うisql-vtを入れる。
RUN apt-get update \
  && apt-get install -y --no-install-recommends virtuoso-opensource-7-bin \
  && rm -rf /var/lib/apt/lists/*
ENV VIRTUOSO_ISQL_PATH=/usr/bin/isql-vt

# アップロード先(NFS)に書き込むため、UID/GIDをNFS上の所有者に合わせられるようにする
# (アプリ本家のDockerfileと同じ対応)。ベースイメージのnodeユーザー(UID/GID 1000)と
# 既定値が重なるため、先に削除してから作り直す。
ARG APP_UID=1000
ARG APP_GID=1000
RUN (userdel node 2>/dev/null || true) \
  && (groupdel node 2>/dev/null || true) \
  && groupadd --non-unique --gid ${APP_GID} nodejs \
  && useradd --non-unique --uid ${APP_UID} --gid nodejs --no-create-home --shell /usr/sbin/nologin nextjs

COPY --from=build --chown=nextjs:nodejs /app ./

# 管理画面の設定・LDAP認証設定・ユーザー情報(SQLite)の保存先。PVCをここにマウントする。
ENV ADMIN_DB_PATH=/app/data/metadb-admin.sqlite
RUN mkdir -p /app/data && chown nextjs:nodejs /app/data

# next startがnext.config.tsを読み直すため、実行時もビルド時と同じベースパスにする。
ARG BASE_PATH=/tsukuba
ENV BASE_PATH=${BASE_PATH}

USER nextjs
EXPOSE 3000
CMD ["npm", "run", "start"]
