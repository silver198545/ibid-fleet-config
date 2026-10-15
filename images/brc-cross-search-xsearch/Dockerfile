# brc-cross-search (https://github.com/d-usuda/brc-cross-search、feature/docker-app-modeブランチ)の
# Sinatra + Pumaサーバーを「横断検索」(APP_MODE=xsearch、ページ設定 config/page_xsearch)として
# 実行するイメージ。
#
# 同じソースから「個別アプリ」(APP_MODE=resource)も別アプリとして展開しており
# (images/brc-cross-search-resource)、2つのDockerfileはAPP_MODE・PAGE_CONFIG_DIR・PORT
# だけが異なる。片方を直したらもう片方も同じように直すこと(docs/manual-apps.md
# 「brc-cross-search-xsearch / brc-cross-search-resource 固有のメモ」参照)。
#
# ビルド元はこのリポジトリ管理外のプライベートリポジトリ(d-usudaアカウント所有)。
# 認証情報をイメージのレイヤー履歴に残さないため、ソース取得は
# Dockerfile内でgit cloneせず、.github/workflows/build-brc-cross-search-xsearch-image.yaml の
# actions/checkoutステップ(SRC_REFファイルの内容をrefに指定)で行い、ビルドコンテキストの
# app/ ディレクトリとして渡す。GHCRへの公開は mainへのマージで同ワークフローが行う
# (パッケージは非公開。pull用SealedSecretが要る):
#   ghcr.io/silver198545/brc-cross-search-xsearch:<TAGファイルの内容>
#
# アプリ側のDockerfile/bin/docker-start.shはdocker-compose(ソースをボリュームでマウント、
# ログはホストのlog/へ)前提のため使わず、次の点を変えている:
#   - Gemfile.lockも取り込んでgemのバージョンを固定する(アプリ側はGemfileのみコピーして
#     その時点の最新を入れている)。lockのPLATFORMSに汎用のx86_64-linuxが無いため
#     frozenにはしない(バージョンはlockどおりに入る)。
#   - Pumaの設定はアプリ側のconfig/puma.rb.templateではなく同じディレクトリの puma.rb を使う
#     (stdout_redirectでファイルに出すとkubectl logsで見えないため。詳細はpuma.rb冒頭)。
#   - app.rbがアクセスログを log/<RACK_ENV>.log へ追記し続けるため、/dev/stdoutへの
#     シンボリックリンクにしてコンテナ内に溜まらないようにする。
#   - 非rootで実行する。
#
# 更新手順: scripts/update-app-image.sh set-image brc-cross-search-xsearch <SRC_REF>
# (resource側も同じSRC_REFで set-image brc-cross-search-resource を行うこと)
FROM ruby:4.0-slim AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY app/Gemfile app/Gemfile.lock ./
RUN bundle install
COPY app/ .
# actions/checkoutが取得したapp/の.gitを最終イメージに持ち込まない。
RUN rm -rf .git

FROM ruby:4.0-slim
WORKDIR /app
ENV RACK_ENV=production
ENV APP_MODE=xsearch
ENV PAGE_CONFIG_DIR=config/page_xsearch
ENV PORT=4042

RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=app:app /app ./
COPY --chown=app:app puma.rb config/puma.rb
RUN mkdir -p log tmp/puma \
  && ln -sf /dev/stdout "log/${RACK_ENV}.log" \
  && chown -R app:app log tmp

USER app
EXPOSE 4042
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
