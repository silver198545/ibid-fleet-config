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

### 手順(brc-advanced-searchのdev→staging昇格で実施・確認済み)

昇格先の環境ディレクトリに`apps/`が無ければ作成しつつコピーする。

```bash
mkdir -p envs/staging/apps
cp -r envs/dev/apps/<app> envs/staging/apps/<app>
```

コピーしただけでは昇格元環境のホスト名が残っているため、必ず以下を昇格先の値へ
書き換える(忘れると昇格先のIngressが昇格元のホスト名で証明書発行を試みる):

- `envs/<to>/apps/<app>/ingress.yaml`の`spec.tls[].hosts`と`spec.rules[].host`
  (`<app>.<from>.ibid.lan` → `<app>.<to>.ibid.lan`)

イメージが非公開でpull用SealedSecretがある場合(brc-advanced-searchはこちら)、
上の「新しいアプリを追加する手順」の4番と同じ要領で**昇格先クラスタ向けに
kubesealで作り直す**(`kubeseal --context <昇格先のkubectlコンテキスト>`。
devのSealedSecretはコピー不可)。

新しいホスト名は昇格先環境で初めて使うため、DNS Aレコード登録
([manual-cert-manager-freeipa-acme.md](manual-cert-manager-freeipa-acme.md)参照)も
このタイミングで行う必要がある(手順は次節)。

PR作成・マージ後、昇格先環境のGitRepoが自動適用する。動作確認は:

```bash
kubectl --context <昇格先のkubectlコンテキスト> -n <app> get pods,ingress
curl -k https://<app>.<to>.ibid.lan/<readinessProbeのpath>
```

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
   - マージ前後どこかのタイミングで、新ホスト名(`<app>.staging.ibid.lan`)の
     DNS AレコードをFreeIPAに登録しておく(未登録だとcert-managerの証明書発行が
     進まず、Ingressへアクセスできない)。TSIG鍵はTXTレコードのみ許可のため
     `ipa dnsrecord-add`をIPA管理者権限で直接実行する
     ([manual-cert-manager-freeipa-acme.md](manual-cert-manager-freeipa-acme.md)参照)。
     ```bash
     kinit admin
     # <TraefikのLB IP>はstagingクラスタのTraefik共有LB IP(2026-07-26時点で192.168.1.63)
     ipa dnsrecord-add ibid.lan <app>.staging --a-rec <TraefikのLB IP>
     ```
     確認:
     ```bash
     dig @192.168.100.21 <app>.staging.ibid.lan +short
     ```
     (例: brc-advanced-searchでは `ipa dnsrecord-add ibid.lan brc-advanced-search.staging --a-rec 192.168.1.63`)
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
  コミットSHAを指すこと)。実サーバー(PENQEinc側)ではPM2 + `nuxt start`
  (`node_modules`込みのフル構成、`npm install`/`npm run build`は素の
  package.json/package-lock.jsonのまま)で稼働実績があるため、Dockerfileも
  それに合わせて素の状態でビルドする(Node 16固定・`fibers`ネイティブビルド・
  lockfile破損/integrity不整合はNuxt2版の問題でありNuxt3版では発生しない)。
  一時Node 22化や`experimental.asyncContext`追加、`@nuxtjs/i18n@latest`への
  強制アップグレードを試したことがあるが、いずれも本質的な解決ではなく
  実サーバーの構成に合わせて元に戻した経緯がある。

  **`Nuxt I18n server context has not been set up yet`(全リクエスト500)の
  根本原因はアプリ側で特定済み**: `package.json`固定の`@nuxtjs/i18n@^10.3.0`
  (2026-05-19付のバージョンアップコミットで導入)がNuxt 4前提のバージョンで、
  本アプリのNuxt 3.14.1592とは非互換だった(i18nのサーバープラグインが
  `useRuntimeConfig(event)`を呼ぶ際に`event.context.nitro`が未初期化のタイミングで
  実行され例外になる)。`@nuxtjs/i18n@8.5.6`(Nuxt3互換)へ戻すことで解消する。
  アプリ側`package.json`/`package-lock.json`の恒久修正はまだコミットされていないため、
  `images/brc-advanced-search/Dockerfile`でビルド時に個別バージョンへ上書きする
  暫定対応をしている。**アプリ側でこの修正がコミットされたら、Dockerfileの
  `RUN npm install @nuxtjs/i18n@8.5.6`を削除し、SRC_REFをそのコミットへ更新すること。**
- **静的生成ではなくSSR(常駐Nodeサーバー)方式**。`npm run build`で`.output/`が
  生成され、実サーバーと同じ`nuxt start`(`node_modules/.bin/nuxt start`)で
  起動する(`images/brc-advanced-search/Dockerfile`)。`npm prune --omit=dev`で
  実行時に不要なdevDependenciesのみ落とし、`node_modules`自体は保持する
  (Nitro standaloneの`.output`のみを直接起動する方式ではない)。
  ビルドスクリプトが`NODE_OPTIONS=--max_old_space_size=8192`を指定しているため、
  CIランナーのメモリ不足でビルドが落ちる場合は要調整。
- PM2の`cluster`モード(1ホスト内で複数プロセス)に相当する並列化は、
  K8sではDeploymentの`replicas`で行う(PM2はプロセス監視・自動再起動も担うが、
  K8sではkubeletがその役割を担うため、コンテナ内にPM2を入れる必要はない)。
- Nitro(nuxt start)はデフォルトで`0.0.0.0:3000`を待ち受けるが、`HOST`/`PORT`
  環境変数で明示している。Service/Deploymentの`containerPort`/`targetPort`は3000。
- アプリ側`nuxt.config.ts`の`app.baseURL`が`NODE_ENV=production`時に`/advanced`固定
  (開発時は`/work3/advanced`)。ベアの`/`へのアクセスはアプリ側で自動リダイレクトされない
  (Nuxt自体が`/advanced`配下のルートしか認識しない)ため、Deploymentの
  readiness/livenessProbeは`/advanced/en/`を直接見ている。実際の本番URL構造
  (RIKEN BRC公式サイト配下の`/advanced`パスに載せるのか、専用ホスト名にするのか)
  が確定したら、Ingressのホスト名/パス設定を見直すこと。
- **2026-07-26、dev→stagingの昇格を実施・確認済み**(このリポジトリで`apps/`昇格の
  最初の実例)。上記「昇格(プロモーション)についての注意」の手順どおり
  `envs/staging/apps/brc-advanced-search`を新規作成し、`ingress.yaml`のホスト名を
  `brc-advanced-search.staging.ibid.lan`に変更、GHCR pull用SealedSecretを
  `staging1`向けに作り直し、DNS Aレコード
  (`ipa dnsrecord-add ibid.lan brc-advanced-search.staging --a-rec 192.168.1.63`)を
  登録して問題なく稼働した。
- **2026-07-26、staging→productionの昇格・stagingクリーンアップまで完了**。
  `envs/production/apps/brc-advanced-search`を作成し、ホスト名を
  `brc-advanced-search.production.ibid.lan`に変更、GHCR pull用SealedSecretを
  `prod1`向けに作り直し、DNS Aレコード
  (`ipa dnsrecord-add ibid.lan brc-advanced-search.production --a-rec 192.168.1.91`)を
  登録して本番で稼働確認済み。
  その後stagingを削除(`envs/staging/apps/brc-advanced-search`・
  `envs/staging/secrets/brc-advanced-search.yaml`をGitから削除するPRをマージし、
  `kubectl --context staging1 delete namespace brc-advanced-search`)。
  **注意点(実際に踏んだ)**: Git側の削除がマージされる前に`kubectl delete namespace`を
  実行すると、stagingのGitRepoがまだ`fleet.yaml`を検知してFleetがnamespaceを
  再作成してしまう。必ず「Gitの削除PRをマージ→その後にkubectl delete namespace」の
  順序を守ること。

## riken-diips 固有のメモ

- ソースは[PENQEinc/riken-diips](https://github.com/PENQEinc/riken-diips)の`main`ブランチ
  (Next.js 15 / React 18 / TypeScript製、DBなし)。`SRC_REF`は同ブランチのコミットSHAを指す。
- `next.config.js`にbasePath指定がないため、brc-advanced-searchの`/advanced`のような制約は
  なく、Deployment の readiness/livenessProbe はベアの`/`を見ている。
- 非機密の環境変数`GOOGLE_ANALYTICS_ID`(アプリ側`.env`のデフォルト`G-XYZ`)のみ、
  Deploymentの`env`にプレースホルダとして設定している。実際の計測IDが決まったら
  `envs/<env>/apps/riken-diips/deployment.yaml`を書き換える。
- ソースが非公開のOrganizationリポジトリのため、brc-advanced-searchと同様に
  GHCRイメージも非公開のまま運用し、GHCR pull用SealedSecret
  (`envs/<env>/secrets/riken-diips.yaml`)が必要。
- **2026-07-26、devへの初回展開を実施**(`envs/dev/apps/riken-diips`一式、
  `images/riken-diips`、`build-riken-diips-image.yaml`を追加)。
  staging/productionへの昇格は未実施。
