# WordPress以外の自作アプリ追加手順

このリポジトリは元々WordPressサイト専用のFleet構成だったが、同じ3クラスタ
(dev→staging→production)・同じ昇格運用に乗せたい自作アプリ(DBを持たない
ステートレスなフロントエンドなど)は `sites/` とは別に `apps/` 配下で管理する。
`sites/<site>/` はBitnami WordPress前提(ラッパーチャート、3種のSecret、PVC、
`keepResources` 等の注意点)を暗黙に含むため、性質の異なるアプリを混ぜると
事故のもとになる。

最初の例: [riken_brc_advanced_search](https://github.com/PENQEinc/riken_brc_advanced_search)
(Nuxt.js製、DBなし。`npm run generate` で静的サイトを生成しnginxで配信する)。

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

1. `images/<app>/` にDockerfile・ビルドに必要なファイル(nginx.confなど)・
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
4. PRを作成しマージすると、devクラスタのFleetが自動適用する
   (パッケージの可視性を最初にpublicへ変更する必要あり。
   `docs/roadmap.md`/各build-imageワークフローのコメント参照)。
5. dev確認後、staging/productionへは上記「昇格についての注意」の手順で
   手動PRを作成する。

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

- アプリ側 `nuxt.config.js` の `router.base` が `NODE_ENV=production` 時に
  `/advanced` 固定になっているため、生成物は `/advanced/` 配下に配置し、
  nginx側で `/` → `/advanced/en/` にリダイレクトしている
  (`images/brc-advanced-search/nginx.conf`)。実際の本番URL構造
  (RIKEN BRC公式サイト配下の `/advanced` パスに載せるのか、専用ホスト名にするのか)
  が確定したら、Ingressのホスト名/パス設定を見直すこと。
- アプリはNuxt 2 + `fibers`(sass-loaderの依存)を使うため、ビルドはNode 16系で
  行う(`images/brc-advanced-search/Dockerfile`)。
- アプリ側の`package-lock.json`に壊れたエントリが1件混入している
  (`@vue/component-compiler-utils`が要求する`postcss@^7.0.36`ではなく、
  トップレベルの`postcss@8.4.32`のエントリがそのまま誤って上書きされており、
  versionフィールドも`"postcss@8.4.32"`のように二重結合されてsemverとして不正)。
  文字列としての破損はDockerfile内で`sed`により補正しているが、バージョン不整合
  (`lock file's postcss@8.4.32 does not satisfy postcss@7.0.39`)は`npm ci`の
  「lockfileと完全一致」要求を満たせないため、`npm ci`ではなく`npm install`を使い
  レジストリから再解決させている(アプリ側リポジトリでのlockfile再生成が本来の
  直し方。PENQEinc側に報告・修正依頼を検討)。
