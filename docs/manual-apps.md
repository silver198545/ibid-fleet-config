# WordPress以外の自作アプリ追加手順

このリポジトリは元々WordPressサイト専用のFleet構成だったが、同じ3クラスタ
(dev→staging→production)・同じ昇格運用に乗せたい自作アプリ(DBを持たない
ステートレスなフロントエンドなど)は `sites/` とは別に `apps/` 配下で管理する。
`sites/<site>/` はBitnami WordPress前提(ラッパーチャート、3種のSecret、PVC、
`keepResources` 等の注意点)を暗黙に含むため、性質の異なるアプリを混ぜると
事故のもとになる。

最初の例: [riken_brc_advanced_search](https://github.com/PENQEinc/riken_brc_advanced_search)
(`vue3-main-riken`ブランチ、Nuxt 3製、DBなし。`npm run build`でビルドし、
NitroのSSRサーバー(`node .output/server/index.mjs`)を常駐実行する)。

## 構成

- `images/<app>/`: アプリのビルド定義。アプリ本体は別リポジトリにあるため、
  `SRC_REF`(取り込むコミットSHA)と `TAG`(公開イメージタグ)をファイルで固定し、
  `images/wordpress/` と同じ「ファイルを書き換えてPR→マージで公開」の運用にする。
  対応する `.github/workflows/build-<app>-image.yaml` が
  `ghcr.io/silver198545/<app>:<TAG>` を公開する。
- `envs/<env>/apps/<app>/`: Fleetバンドル本体。`fleet.yaml` + 素のKubernetesマニフェスト
  (Deployment/Service/Ingressなど)。Helmチャートを使わない場合は `helm.releaseName`
  のみを指定する(`envs/dev/infra/catalog-repos/fleet.yaml` と同じやり方)。

## 昇格(プロモーション)についての注意

**`.github/workflows/promote.yaml` は `envs/<from>/sites/` しかコピーしない。**
`apps/` を追加・変更した場合、staging/productionへの反映は今のところ手動でPRを
作成する(`cp -r envs/dev/apps/<app> envs/staging/apps/<app>` のように昇格元を
そのままコピーし、他サイトの昇格PRと同様にレビュー・承認を経てマージする)。
`apps/` を継続的に追加していく場合は、promoteワークフローに `sites`/`apps` の
対象切り替えを足すことを検討する([docs/roadmap.md](roadmap.md)参照)。

## 新しいアプリを追加する手順(例: brc-advanced-search)

1. `images/<app>/` にDockerfile・ビルドに必要な付随ファイル(あれば)・
   `TAG`・(外部リポジトリのソースを取り込む場合は)`SRC_REF` を作成する。
   ソース取得元がプライベートリポジトリの場合、認証情報をDockerイメージの
   レイヤー履歴に残さないため、Dockerfile内で`git clone`せず、ワークフロー側の
   `actions/checkout`(`repository:`/`ssh-key:`指定)でソースを取得し、
   `COPY app/ .` でビルドコンテキストに取り込む(`.gitignore`にも
   `/images/<app>/app/` を追加し、取得したソースが誤ってコミットされないようにする。
   このリポジトリはpublicなので特に注意)。
2. `.github/workflows/build-<app>-image.yaml` を追加する
   (`build-brc-advanced-search-image.yaml` をコピーしてアプリ名を置換すればよい)。
   ソース取得元がプライベートリポジトリの場合、対象リポジトリに読み取り専用の
   Deploy Key(SSH)を登録し、対応する秘密鍵をこのリポジトリのActions Secretsに
   登録する(例: `BRC_ADVANCED_SEARCH_DEPLOY_KEY`)。
   - ソース取得元のリポジトリがOrganization所有の場合、**fine-grained PAT + tokenでの
     HTTPS取得は避ける**こと。Organization側の「fine-grained PATを許可する」設定や
     トークン承認が別途必要になり、リポジトリ側がadminでも403で失敗することがある
     (brc-advanced-searchで実際に踏んだ)。Deploy Keyはリポジトリ単位で完結し
     Organizationの承認プロセスに左右されないため、こちらを標準にする。
3. `envs/dev/apps/<app>/` に `fleet.yaml` とマニフェストを作成する。
   - Namespaceはアプリ名をそのまま使う。
   - 公開が必要なら、既存WordPressサイトと同様にTraefik Ingress + ホスト名
     (`<app>.<env>.ibid.lan`)+ cert-manager(`freeipa-acme`)で行う
     (WordPress専用LoadBalancer方式ではなくIngress方式)。
4. PRを作成しマージすると、devクラスタのFleetが自動適用する。
   GHCRパッケージの可視性は次のいずれか:
   - **公開してよい場合**: 初回のみGitHubのPackage設定でpublicに変更する
     (`docs/roadmap.md`/各build-imageワークフローのコメント参照)。
   - **公開できない場合**(brc-advanced-searchはこちら。ソースが外部組織の
     プライベートリポジトリのため、ビルド済みイメージも非公開のままにする):
     `read:packages` スコープのPersonal access token(専用に新規発行したものを
     推奨。既存の広いスコープのPATを流用しない)で`kubernetes.io/dockerconfigjson`
     Secretを作り、`scripts/seal-site-secrets.sh`と同じ要領で対象環境の
     SealedSecretsコントローラ宛にkubesealで封印し、`envs/<env>/secrets/<app>.yaml`
     としてコミットする(手元の端末で実行し、封印済みYAML以外は共有しないこと。
     PATの生の値をコミットログやチャットに残さない)。
     ```bash
     kubectl create secret docker-registry ghcr-<app> \
       -n <app> \
       --docker-server=ghcr.io \
       --docker-username=<GitHubユーザー名> \
       --docker-password=<PAT> \
       --docker-email=unused@example.com \
       --dry-run=client -o json \
     | kubeseal --context <kubectlコンテキスト> --format yaml
     ```
     生成したSecret名をDeploymentの`imagePullSecrets`に追加する
     (`envs/dev/apps/brc-advanced-search/deployment.yaml`参照)。
5. dev確認後、staging/productionへは上記「昇格についての注意」の手順で
   手動PRを作成する(pull用SealedSecretは環境ごとに作り直しが必要。
   他環境のSealedSecretはコピーできない)。

## staging結合テスト → 本番反映 → stagingクリーンアップ

WordPressサイトと同じサイクル([operations-flow.md](operations-flow.md)参照)で運用する。
DBを持たないアプリの場合はWordPressより手順が単純になる:

1. **dev → staging**: 上記「昇格についての注意」の手順で手動PRを作成・マージ
2. **stagingで結合テスト**: `https://<app>.staging.ibid.lan/` 等で動作確認
   (WordPressと異なりDBが無いので、本番データのリストアは不要。
   Deploymentが上がりIngress経由で表示できれば十分)
3. **staging → production**: 同様に手動PRを作成。CODEOWNERS承認のうえマージ
4. **stagingを削除する**: 本番反映後、待機コストを残さないようstagingから
   完全に削除する
   - Git側: `envs/staging/apps/<app>/` を削除するPRを作成・マージ
   - クラスタ側(`fleet.yaml`の`keepResources: true`によりGit側の削除だけでは
     Fleetがリソースを消さないため、手動で):
     ```bash
     kubectl delete namespace <app>
     ```
     PVCを持たないため、WordPressのような容量解放待ちの考慮は不要

## brc-advanced-search 固有のメモ

- ソースは`vue3-main-riken`ブランチ(旧`main`はNuxt 2版で廃止。SRC_REFはこちらの
  コミットSHAを指すこと)。Nuxt 3 + Viteのため、旧Nuxt 2版で踏んだNode 16固定・
  `fibers`ネイティブビルド・package-lock.jsonの破損/integrity不整合の問題はない
  (lockfileVersion 3、`npm install`で問題なく解決できる)。ただし後述の
  `@nuxtjs/i18n@latest`への個別更新が`@intlify/core`等でNode >= 22を要求するため、
  ビルド/実行ともNode 22系にしている。
- **静的生成ではなくSSR(常駐Nodeサーバー)方式**にした。`npm run build`
  (Nitro node-serverプリセット)で`.output/`配下にサーバー一式が出力され、
  `node .output/server/index.mjs`で起動する(`images/brc-advanced-search/Dockerfile`)。
  ビルドスクリプトが`NODE_OPTIONS=--max_old_space_size=8192`を指定しているため、
  CIランナーのメモリ不足でビルドが落ちる場合は要調整。
- Nitroはデフォルトで`0.0.0.0:3000`を待ち受けるが、`HOST`/`PORT`環境変数で明示している。
  Service/Deploymentの`containerPort`/`targetPort`は3000。
- アプリ側`nuxt.config.ts`の`app.baseURL`が`NODE_ENV=production`時に`/advanced`固定
  (開発時は`/work3/advanced`)。ベアの`/`へのアクセスはアプリ側で自動リダイレクトされない
  (Nuxt自体が`/advanced`配下のルートしか認識しない)ため、Deploymentの
  readiness/livenessProbeは`/advanced/en/`を直接見ている。実際の本番URL構造
  (RIKEN BRC公式サイト配下の`/advanced`パスに載せるのか、専用ホスト名にするのか)
  が確定したら、Ingressのホスト名/パス設定を見直すこと。
- アプリ側`nuxt.config.ts`に`experimental.asyncContext`の設定が無く、`@nuxtjs/i18n`が
  SSRリクエストごとの非同期コンテキストを取得できず全リクエストが
  `[500] Nuxt I18n server context has not been set up yet` になっていた
  (Nuxt3 + `@nuxtjs/i18n`の既知の問題)。Dockerfile内で`sed`により
  `experimental: { asyncContext: true }` を`nuxt.config.ts`へ追記しているが、
  それだけでは解消せず、`package-lock.json`固定の`@nuxtjs/i18n@10.3.0`自体に
  該当の不具合があった。ビルド時に`npm install @nuxtjs/i18n@latest`で
  個別に最新版へ上げることで解消している。アプリ側リポジトリでの恒久対応
  (`package.json`の`@nuxtjs/i18n`バージョン更新、`nuxt.config.ts`への追記)を
  PENQEinc側に依頼すること。
