# WordPress以外の自作アプリ追加手順

このリポジトリは元々WordPressサイト専用のFleet構成だったが、同じクラスタ
(dev→production)・同じ昇格運用に乗せたい自作アプリ(DBを持たない
ステートレスなフロントエンドなど)は `sites/` とは別に `apps/` 配下で管理する。
`sites/<site>/` はBitnami WordPress前提(ラッパーチャート、3種のSecret、PVC、
`keepResources` 等の注意点)を暗黙に含むため、性質の異なるアプリを混ぜると
事故のもとになる。

最初の例: [riken_brc_advanced_search](https://github.com/PENQEinc/riken_brc_advanced_search)
(`vue3-main-riken`ブランチ、Nuxt 3製、DBなし。`npm run build`でビルドし、
NitroのSSRサーバー(`node .output/server/index.mjs`)を常駐実行する)。

[sparqlist](https://github.com/dbcls/sparqlist)(Express製、DBなし)は保存した
SPARQLet(`repository/`配下のMarkdown設定ファイル)の永続化が必要な点が上記2つと異なる。
dev/production共有のNFSディレクトリ(`envs/<env>/apps/sparqlist/pv-nfs-shared.yaml`)を
マウントする以外は同じ`apps/`パターンに乗せている
(詳細は下記「sparqlist 固有のメモ」参照)。

[metadatabase-v2](https://github.com/silver198545/metadatabase-v2)(Next.js 15製、
DBなし。外部のSPARQLエンドポイントを参照するのみ)はriken-diipsと同じ構成
(SSR・PVCなし)。詳細は下記「metadatabase-v2 固有のメモ」参照。

[brc-cross-search](https://github.com/d-usuda/brc-cross-search)(Sinatra + Puma製、DBなし。
外部のSPARQLエンドポイントを参照するのみ)は、同じソースを「横断検索」(`brc-cross-search-xsearch`)と
「個別アプリ」(`brc-cross-search-resource`)の2つのアプリとして展開している。
詳細は下記「brc-cross-search-xsearch / brc-cross-search-resource 固有のメモ」参照。

## 構成

- `images/<app>/`: アプリのビルド定義。アプリ本体は別リポジトリにあるため、
  `SRC_REF`(取り込むコミットSHA)と `TAG`(公開イメージタグ)をファイルで固定し、
  「ファイルを書き換えてPR→マージで公開」の運用にする。
  対応する `.github/workflows/build-<app>-image.yaml` が
  `ghcr.io/silver198545/<app>:<TAG>` を公開する。
- `envs/<env>/apps/<app>/`: Fleetバンドル本体。`fleet.yaml` + 素のKubernetesマニフェスト
  (Deployment/Service/Ingressなど)。Helmチャートを使わない場合は `helm.releaseName`
  のみを指定する(`envs/dev/infra/catalog-repos/fleet.yaml` と同じやり方)。

## 昇格(プロモーション)についての注意

`apps/` のdev→production昇格も、サイトと同じ `.github/workflows/promote.yaml` で行う
(2026-10-10から。`gh workflow run promote.yaml -f kind=apps -f name=<app>`、`name=all` で本番にある全アプリ)。
`scripts/update-app-image.sh deploy-production <app>` はこのワークフローを起動してPRができるのを待つ
(Rundeck(プロジェクト `Rancher-AppControll`)の `<app>/2-production-update` は、これに続けて人のマージを待ち本番の確認まで行う。[manual-rundeck.md](manual-rundeck.md))。
**本番への初回昇格だけは** SealedSecretをkubesealで作る必要があるため、ワークフローでは行わず
`update-app-image.sh promote-production` / `promote-production-finish` を使う(ワークフローは
本番に無いアプリを指定するとエラーにして案内する)。

昇格は**ディレクトリの丸ごとコピー**(`envs/dev/apps/<app>` → `envs/production/apps/<app>`)。
productionで変える値(ホスト名、レプリカ数、アフィニティ等)はdev側のディレクトリ内に
`overlays/production/<マニフェスト名>_patch.yaml` として置き、`fleet.yaml` の
`targetCustomizations` で `env: production` のクラスタにだけ適用させる
(Fleetのyaml overlay機能。[operations-flow.md](operations-flow.md)「環境差分の書き方」)。
そのためコピー後のホスト名書き換え等は不要で、`envs/dev/apps/<app>` と
`envs/production/apps/<app>` は、昇格待ちの変更(イメージタグ等)を除き同じ内容になる。

- **2回目以降(通常のイメージ更新)**: `set-image`(イメージPR→ビルド→`deploy-dev`→`check-dev`
  まで自動で進む)→ devで動作確認 → `deploy-production`(productionをdevと同じ内容に同期するPR。イメージタグに限らず
  devに入っている変更はすべて昇格対象になるので、PRのdiffを確認する)→ `check-production`
- **初回昇格(新規アプリ)**: `promote-production` → SealedSecret作成 →
  `promote-production-finish`。devのディレクトリに `overlays/production/` が無いと
  エラーになる(下記「新しいアプリを追加する手順」5.)
- **2026-10-08以前**(dev→staging→productionの3環境時代)は、昇格のたびにホスト名を
  `ingress.yaml`内で書き換え、production固有のレプリカ数等をproduction側のファイルにだけ
  持たせていた。現在の方式に移行済み

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
   - **PATの有効期限に注意する。** 期限が切れても、すでに動いているPodはイメージのキャッシュで動き続けるので
     気づきにくい。Podが別のノードへ移ったとき(ノードの入れ替えなど)に初めて`ImagePullBackOff`
     (`failed to fetch oauth token`)になる。2026-10-09に、brc-advanced-searchとriken-diipsで共有していた
     PATの期限切れがこの形で見つかった。発行時に期限の日を控えておき、期限が来る前に新しいPATを発行して、
     **全環境分**(dev1とprod1それぞれの鍵)を封印し直す。PATが使えるかは、値を表示せずに
     `curl -s -o /dev/null -w '%{http_code}' -u <ユーザー名>:<PAT> 'https://ghcr.io/token?scope=repository:<owner>/<app>:pull'`
     が200を返すかで確かめられる。
5. productionへ出す前に、devのディレクトリに production 用の差分を用意してdevへマージする
   (dev1では使われないので、devの動作には影響しない)。既存の
   `envs/dev/apps/brc-advanced-search/` をひな形にする:
   - `overlays/production/ingress_patch.yaml`: `spec.tls`/`spec.rules` を
     `<app>.production.ibid.lan` で丸ごと書く(リストは置き換えになるため全体を書く)
   - `overlays/production/deployment_patch.yaml`: `spec.replicas: 2` 等の冗長化設定
   - `fleet.yaml` 末尾の `targetCustomizations`(`env: production` → `yaml.overlays: [production]`)
6. dev確認後、上記「昇格についての注意」の初回昇格でproductionへ出す
   (pull用SealedSecretは環境ごとに作り直しが必要。他環境のSealedSecretはコピーできない)。
   DNSは環境ごとのワイルドカード(`*.production.ibid.lan`)なので、ホスト名の登録は不要
   ([manual-cert-manager-freeipa-acme.md](manual-cert-manager-freeipa-acme.md)「サイトホスト名のDNS」)。

## 本番反映のサイクル

WordPressサイトと同じサイクル([operations-flow.md](operations-flow.md)参照)で運用する。
DBを持たないアプリの場合はWordPressより単純で、devで動作確認できればそのまま
productionへ昇格してよい(本番データのリハーサルは基本不要)。

PVCで永続データを持つアプリは、`update-app-image.sh`の`persistent_data_dir_for`に登録すれば
本番の永続データをdevへコピーして本番相当データで確認できる(`update-app-image.sh sync-dev-data <app>`。
**devの内容は上書きされる**)。現状は登録なし(sparqlistの`repository/`は2026-10-21から
devとproductionで同じNFSディレクトリを共有しているためコピー不要。「sparqlist 固有のメモ」参照)。

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
- **`RIKEN_DIIPS_ACCESS_TOKEN`が期限切れになった場合**: コード変更は不要、Secretの値を
  差し替えるだけでよい。
  1. `PENQEinc/riken-diips`へのread権限を持つアカウントで新しいclassic PATを発行
     (`repo`スコープ必須。抜けていると下記「実際に踏んだ問題」と同じ
     `Write access to repository not granted.`エラーになり、期限切れと紛らわしいので注意)。
  2. `gh secret set RIKEN_DIIPS_ACCESS_TOKEN --repo silver198545/ibid-fleet-config`
     で値を更新する(GitHub UIのSettings > Secrets and variables > Actionsからでも可)。
  3. `build-riken-diips-image.yaml`は`workflow_dispatch`対応なので、
     `gh workflow run build-riken-diips-image.yaml --repo silver198545/ibid-fleet-config`
     で`images/riken-diips/TAG`を変えずに再実行して疎通確認できる。
- **ソース取得はDeploy Keyではなくclassic PAT方式**(`RIKEN_DIIPS_ACCESS_TOKEN`)。
  brc-advanced-searchで標準化したDeploy Key方式(上記「新しいアプリを追加する手順」の
  1番)の代わりに、`repo`スコープのPersonal access token (classic)を
  `actions/checkout`の`token:`に渡している。riken-diipsに対して既にread権限を持つ
  アカウント(このリポジトリを運用しているアカウント自身)でトークンを発行した場合、
  classic PATはOrganization側の追加承認を必要としない(fine-grained PATのみが
  Organizationの許可制の対象になる)。対象リポジトリ側でDeploy Key登録という
  管理操作が不要になる分、新しいアプリを追加する手順がシンプルになる。
  ただしこの方式はトークン発行者アカウントの権限がそのまま使われるため、
  そのアカウントが対象リポジトリへのアクセスを失う(Organizationを離脱する等)と
  ビルドが失敗する点に注意。他人が管理するリポジトリ、または長期間他者依存に
  したくない場合はDeploy Key方式を選ぶこと。
  **実際に踏んだ問題**: `build-riken-diips-image`の初回実行が
  `remote: Write access to repository not granted.`で403になった。当初は
  「プライベートリポジトリへの生コミットSHA指定でのfetchはread権限では許可されない」
  という仮説で`main`ブランチ名でのfetch+ローカル`git checkout <SRC_REF>`に変更したが、
  ブランチ名指定でのfetchでも同じ403が再現し、この仮説は誤りだったと判明した。
  **真因は`RIKEN_DIIPS_ACCESS_TOKEN`(classic PAT)に`repo`スコープが
  付与されていなかったこと**(スコープ不足でも同じ`Write access to repository not
  granted.`というメッセージになる)。トークンに`repo`スコープを追加したところ
  即座に解消した。ブランチ名fetch+ローカルcheckoutへの変更自体は原因ではなかったが、
  害もないためそのまま残している。**classic PATを発行する際は必ず`repo`スコープが
  入っているか確認すること。**
- **2026-07-26、devへの初回展開を完了**(`envs/dev/apps/riken-diips`一式、
  `images/riken-diips`、`build-riken-diips-image.yaml`を追加、GHCR pull用
  SealedSecret・DNS Aレコード登録済み)。`https://riken-diips.dev.ibid.lan/`で
  200・`<title>DiiPS</title>`のレンダリングを確認済み。
- **2026-07-27、dev→stagingの昇格PRを作成**(上記「昇格(プロモーション)についての
  注意」の手順どおり`envs/staging/apps/riken-diips`を新規作成し、`ingress.yaml`の
  ホスト名を`riken-diips.staging.ibid.lan`に変更、GHCR pull用SealedSecretを
  `staging1`向けに作り直し、DNS Aレコード
  (`ipa dnsrecord-add ibid.lan riken-diips.staging --a-rec 192.168.1.63`)を
  登録のうえ[#88](https://github.com/silver198545/ibid-fleet-config/pull/88)を作成・マージ済み)。
- **2026-07-27、staging→productionの昇格・冗長化・stagingクリーンアップまで完了**。
  `envs/production/apps/riken-diips`を作成し、ホスト名を
  `riken-diips.production.ibid.lan`に変更、GHCR pull用SealedSecretを`prod1`向けに
  作り直して[#89](https://github.com/silver198545/ibid-fleet-config/pull/89)をマージ。
  続けてbrc-advanced-search本番と揃える形で`replicas`を1→2に変更
  ([#91](https://github.com/silver198545/ibid-fleet-config/pull/91))。
  その後stagingを削除(`envs/staging/apps/riken-diips`・
  `envs/staging/secrets/riken-diips.yaml`を削除する
  [#92](https://github.com/silver198545/ibid-fleet-config/pull/92)をマージ後、
  `kubectl --context staging1 delete namespace riken-diips`を実行)。
  **実際に踏んだ問題**: PR #89マージ後(squash merge)、同じローカルブランチに
  そのままreplicas変更のコミットを積んで#91用に作ろうとしたところ、mainとの
  共通祖先がPR #89のマージ前に戻ってしまい、変更していないファイルまで
  すべて`add/add`コンフリクトになった(squash mergeは新しいコミットハッシュを
  作るため、マージ済みブランチの続きにコミットしても祖先関係が繋がらない)。
  **squash mergeされたPRのブランチは使い捨てにし、追加の変更は必ずmainから
  新しくブランチを切り直すこと。**

## sparqlist 固有のメモ

- ソースは[dbcls/sparqlist](https://github.com/dbcls/sparqlist)の`main`ブランチ
  (Express製REST APIサーバー + Reactフロントエンド、DBなし。Node.js 24以上必須)。
  `SRC_REF`は同ブランチのコミットSHAを指す。
- **公開リポジトリのため、brc-advanced-search(Deploy Key)・riken-diips(classic PAT)と
  異なり認証情報が一切不要**。`.github/workflows/build-sparqlist-image.yaml`の
  `actions/checkout`は`token:`/`ssh-key:`を渡さずそのまま取得している。ソースにも
  ビルド済みイメージにも非公開にする理由がないため、**GHCRパッケージは初回のみ
  GitHubのPackage設定でpublicに変更する**こと(brc-advanced-search/riken-diipsとは
  逆の運用)。イメージが公開されていれば`envs/<env>/apps/sparqlist`にGHCR pull用
  SealedSecretもDeploymentの`imagePullSecrets`も不要(`scripts/update-app-image.sh`の
  `ghcr_secret_needed_for`に`sparqlist`を`no`として登録済み)。
- **既存運用(オンプレ)の`/sparqlist/`サブディレクトリ配下という公開パスを維持する**
  (他の`apps/`アプリは専用ホスト名配下のベア`/`だが、今回は移行元の互換性を優先)。
  `ROOT_PATH`はsparqlistのfrontendビルド(`frontend/vite.config.js`)がビルド時に
  アセットURLの接頭辞へ焼き込み、`index.mjs`が実行時にも同じ値をpathPrefixとして
  読むため、ビルド時・実行時で必ず一致させる必要がある。Deployment側で指定させず
  `images/sparqlist/Dockerfile`の両ステージに`ENV ROOT_PATH=/sparqlist/`を固定で
  焼き込むことで値のズレを防いでいる(値を変える場合はDockerfileを書き換えて
  イメージを作り直すこと)。Ingress側も`ingress.yaml`の`path: /sparqlist`と揃えてある。
- **`repository/`配下(保存したSPARQLetのMarkdown設定)の永続化が必要**な点が
  brc-advanced-search/riken-diipsと異なる唯一の点。**devとproductionは同じNFSディレクトリ
  (`192.168.1.1:/data/nfs/sparqlist/shared/repository`)を参照する**(2026-10-21〜。
  静的PV/PVC `sparqlist-repository-shared`、`envs/<env>/apps/sparqlist/pv-nfs-shared.yaml`)。
  `deployment.yaml`で`/app/repository`(`REPOSITORY_PATH`のデフォルト値`./repository`が
  WORKDIR `/app`からの相対パスで解決される)にマウントしている。
  - **SPARQLetの作成・編集はproductionの管理画面でだけ行う**。devは読み取り専用でマウントしており
    (productionだけ`overlays/production/deployment_patch.yaml`で書き込み可)、devの画面から保存しても
    失敗する(Express 5のため500/404が返るだけでPodは落ちない)。代わりに「新しいSPARQLetをdevだけで
    先に試す」ことはできない。sparqlistはリクエストのたびにファイルを読み直すので、本番で保存した
    内容はdevにもすぐ見える(以前の本番→devのコピー`sync-dev-data`は不要になったので廃止した)。
  - 非rootコンテナ(`USER node`、uid/gid 1000)からの書き込みを許可するため、Pod
    `securityContext.fsGroup`を設定している(bitnamiチャートの`podSecurityContext.fsGroup`と
    同じ考え方。ベースイメージのUID/GIDを調べる必要がない)。
  - 以前は環境ごとのLonghorn RWX(`longhorn-r1`、PVC `sparqlist-repository`)に置いていたが、
    share-manager経由のマウントで`Remote I/O error`が断続的に出ていた(2026-10-13)。2026-10-21に
    下記「`repository/`のNFS共有ディレクトリへの移行」で移し、旧PVCは同日両環境とも削除した。
  - バックアップはNFSサーバー側(組織のBaculaによる二次コピー。本リポジトリの管理外)だけになり、
    ゲストLonghornの日次バックアップの対象からは外れる。
- **管理API(SPARQLetの作成・編集)は`ADMIN_PASSWORD`環境変数で保護される**
  (空にすると管理機能自体が無効化される仕様)。パスワードをGit管理下に置かないため、
  `scripts/seal-sparqlist-secret.sh <env>`でSealedSecretとして
  `envs/<env>/secrets/sparqlist.yaml`に封印する(brc-advanced-search/riken-diipsの
  同名ファイルはGHCR pull用Secretだが、sparqlistでは用途が異なる。`update-app-image.sh`の
  `promote-production`もこの違いを認識し、GHCR pull用の代わりに
  このコマンドの実行を促す)。デフォルトは環境ごとにランダム生成(CLAUDE.mdの方針どおり
  使い回さない)だが、既存運用からの移行等で特定の値を使いたい場合は
  `ADMIN_PASSWORD='...' scripts/seal-sparqlist-secret.sh <env>`のように環境変数で指定できる
  (argvではなく環境変数で渡すのはシェル履歴に残さないため)。
- **導入時に必要な手動手順(dev)**:
  1. このPRをマージし、`build-sparqlist-image.yaml`の成功を確認した上でGHCRパッケージを
     public化する
  2. `scripts/seal-sparqlist-secret.sh dev`を実行し、`envs/dev/secrets/sparqlist.yaml`を
     作成するPRを作成・マージする(namespaceは`envs/dev/apps/sparqlist`のFleetバンドルが
     作成するため、このPRが先行してもnamespace未作成エラーにはならないが、
     ADMIN_PASSWORDが注入されないままではPodがCrashLoopBackOffにはならず起動するので
     気付きにくい点に注意。マージ後は`kubectl -n sparqlist get secret sparqlist-admin-password`
     で存在を確認すること)
  3. `sparqlist.dev.ibid.lan`のDNS AレコードをFreeIPAに登録
     (`docs/manual-cert-manager-freeipa-acme.md`参照)
  4. `https://sparqlist.dev.ibid.lan/sparqlist/`で200を確認
     (`scripts/update-app-image.sh check-dev sparqlist`でも可)
- **`repository/`のNFS共有ディレクトリへの移行(2026-10-21〜)**: 環境ごとのLonghorn PVC
  (`sparqlist-repository`)から共有NFS(`sparqlist-repository-shared`)へ移す。productionの内容を
  正とし、devの内容は捨てる。本番Podへの操作・NFSへの書き込みは管理者が行う:
  1. 移行が終わるまで(手順4まで)、本番の管理画面でのSPARQLetの編集を止めてもらう
  2. productionの`repository/`を取り出し、NFSをマウントしたホスト(`N`は
     `192.168.1.1:/data/nfs`のマウント先)で共有ディレクトリに展開する。
     Podのuid/gid(1000)の所有にしておく(productionのPodが既存ファイルを上書きできるように):
     ```bash
     kubectl --context prod1 -n sparqlist exec deploy/sparqlist -- \
       tar czf - -C /app/repository --exclude=./lost+found . > sparqlist-repository-prod.tgz
     tar tzf sparqlist-repository-prod.tgz | grep -c '\.md$'   # 件数を控える

     # NFSをマウントしたホストで
     install -d -m 0777 $N/sparqlist/shared/repository
     tar xzf sparqlist-repository-prod.tgz -C $N/sparqlist/shared/repository --no-same-owner
     chown -R 1000:1000 $N/sparqlist/shared/repository
     ls $N/sparqlist/shared/repository | grep -c '\.md$'      # 上の件数と一致すること
     ```
  3. devの切替(`pv-nfs-shared.yaml`を追加したPR)をマージし、devの一覧API
     `https://sparqlist.dev.ibid.lan/sparqlist/-api/sparqlets`(`data`配列)の件数が手順2と
     一致することを確かめる
  4. productionへ昇格する(`scripts/update-app-image.sh deploy-production sparqlist`)。
     手順2より後に本番で編集してしまった場合は、マージ前に手順2をやり直す。マージ後、
     `https://sparqlist.production.ibid.lan/sparqlist/-api/sparqlets`の件数と、管理画面で
     SPARQLetを1件保存できること(本番は書き込み可)を確かめる。ここで編集の停止を解除する
  5. 旧Longhorn PVC(`pvc.yaml`)をバンドルから消すPRをdev→productionの順に出す
     (Helmが`sparqlist-repository`を削除し、Longhornボリュームも消える。それまでは切り戻し用で、
     切り戻すときは`deployment.yaml`の`claimName`を`sparqlist-repository`に戻す)。
     手元の`sparqlist-repository-prod.tgz`は確認後に削除する。
     2026-10-21の移行では、手順1〜5を同日中に両環境で終えた
- **既存運用からの`repository/`データの投入**: DBが無いためWordPressのような
  DBダンプ復元は不要で、`repository/`ディレクトリのファイルを共有NFSディレクトリへ置くだけでよい
  (上記の移行手順2と同じ要領。tarballを直接`$N/sparqlist/shared/repository`へ展開し、
  uid/gid 1000の所有にする)。devとproductionの両方に即座に反映される。
  (2026-10-13に既存運用の129件をdev1/prod1それぞれのLonghorn PVCへ`kubectl cp`で投入したのが
  最初の移行。その際に踏んだ問題: `/app`がroot所有のため`mv /app/repository ...`は
  `Permission denied`になる、マウントポイントに`tar xzf`すると`-m --no-same-permissions`無しでは
  ディレクトリ自体の属性復元に失敗して終了コードが非0になる)

## metadatabase-v2 固有のメモ

- ソースは[silver198545/metadatabase-v2](https://github.com/silver198545/metadatabase-v2)の
  `main`ブランチ(Next.js 15 App Router / React 19 / TypeScript製。理研BRCの既存システムを
  踏襲したデザインで、外部のVirtuoso SPARQLエンドポイントを参照するのみでDBは持たない)。
  `SRC_REF`は同ブランチのコミットSHAを指す。`next.config.ts`に`output: "standalone"`の
  指定は無いため、riken-diipsと同様に実行時もフルの`node_modules`が必要
  (`images/metadatabase-v2/Dockerfile`は`npm prune --omit=dev`のみでdevDependenciesを
  落とす構成)。
- **ソースリポジトリはこのリポジトリ(ibid-fleet-config)と同じsilver198545アカウント
  所有のプライベートリポジトリ**。riken-diipsと同じくOrganizationの承認プロセスに
  阻まれる問題は起きないため、classic PAT方式(`METADATABASE_V2_ACCESS_TOKEN`、
  `repo`スコープ)でソース取得している。ただし同一アカウント所有だからといって
  既存の広いスコープのPAT(このリポジトリの運用に使っているgh CLIのトークン等)を
  流用しないこと(CLAUDE.mdの秘密情報使い回し禁止方針と同じ理由。専用に新規発行した
  トークンを使う)。riken-diipsと同じ理由([riken-diips 固有のメモ]参照)で、
  ワークフローは生SHA指定ではなく`main`ブランチ名でfetchしてからローカルで
  `git checkout <SRC_REF>`する構成にしてある。
- ソースが非公開のため、GHCRイメージも非公開のまま運用する。devクラスタからのpullには
  GHCR pull用SealedSecret(`envs/<env>/secrets/metadatabase-v2.yaml`、
  `read:packages`スコープのPersonal access token(専用に新規発行したものを推奨)から
  作成)が必要(`scripts/update-app-image.sh`の`ghcr_secret_needed_for`に`yes`として
  登録済み)。
- 環境変数`SPARQL_ENDPOINT`/`NEXT_PUBLIC_SPARQL_ENDPOINT`は設定せず、`SITE_ENV`に応じた
  アプリ側の既定値(development: `https://knowledge.brc.riken.jp/sparql2`、
  production: `https://knowledge.brc.riken.jp/sparql`)を使う。管理画面のシステム設定で
  保存した値があればそちらが優先される。
- 管理用SQLite(`metadatabase-v2-admin-data`、Longhorn RWO)と、既存NFS上の実データを
  直接指す静的PV/PVC(`pv-nfs-uploadrdf.yaml`・`pv-nfs-download.yaml`、`Retain`)を持つ。
  RWOのため`replicas: 1`・`strategy: Recreate`で運用する(productionも1レプリカ)。
- **dev/productionの差分**(`overlays/production/`):

  | 項目 | dev | production |
  |---|---|---|
  | イメージ(`BASE_PATH`) | `metadatabase-v2:<TAG>`(`/tsukuba`) | `metadatabase-v2-bioresource:<TAG>`(`/bioresource`) |
  | `SITE_ENV` | `development`(基調色が赤) | `production`(青) |
  | `TRUSTED_ORIGINS` | `https://wpdev2.brc.riken.jp` | `https://knowledge.brc.riken.jp` |
  | `VIRTUOSO_ISQL_HOST` | `192.168.1.102:1111` | `192.168.1.101:1111` |
  | NFSマウント | `/mnt/{uploadrdf,download}/tsukuba` | `/mnt/{uploadrdf,download}/bioresource` |

  - Next.jsの`basePath`はビルド時に埋め込まれるため、`build-metadatabase-v2-image.yaml`が
    同じ`TAG`・`SRC_REF`から2つのイメージを公開する。`deploy-dev`は
    `deployment.yaml`と`overlays/production/deployment_patch.yaml`の両方のタグを揃えて
    更新する(両者のタグがずれないよう、手で片方だけ直さないこと)。
  - アップロード先はVirtuosoのホストと同じ絶対パスで見える必要があるため、NFSの
    マウント先パスも環境ごとに変える。Deploymentのパッチは`$patch: replace`で
    `volumeMounts`/`volumes`を丸ごと置き換え、PVファイルは同名ファイルで丸ごと置き換える
    (Fleetのoverlayは`_patch.yaml`をstrategic merge patchとして、同名ファイルは
    置き換えとして扱う)。直下のマウント・ボリュームを変えたらパッチ側も直すこと。
  - 管理画面の「アップロード先ディレクトリ」「ダウンロード用ディレクトリ」は
    SQLiteに保存される設定で、Gitでは管理しない。productionは初回ログイン後に
    `/mnt/uploadrdf/bioresource`(オントロジーは`…/ontology`)・`/mnt/download/bioresource`
    を設定する。
- **productionの管理画面用Secret**(`envs/production/secrets/metadatabase-v2-admin.yaml`):
  `ADMIN_SECRET_KEY`/`ADMIN_INITIAL_PASSWORD`はproduction用に新規生成し、
  `VIRTUOSO_ISQL_PASSWORD`はproductionのVirtuoso(192.168.1.101)のdbaパスワードを入れる
  (2026-10-09時点ではdevと同じ値)。作成コマンドは`update-app-image.sh promote-production`が表示する。
  初期管理者パスワードは`kubectl --context prod1 -n metadatabase-v2 get secret
  metadatabase-v2-admin -o jsonpath='{.data.ADMIN_INITIAL_PASSWORD}' | base64 -d`で確認し、
  初回ログイン後に変更する。
- **導入時に必要な手動手順(dev)**:
  1. `METADATABASE_V2_ACCESS_TOKEN`(`repo`スコープのclassic PAT、専用に新規発行)を
     `gh secret set METADATABASE_V2_ACCESS_TOKEN --repo silver198545/ibid-fleet-config`
     で登録し、このPRをマージして`build-metadatabase-v2-image.yaml`の成功を確認する
  2. GHCR上の`metadatabase-v2`パッケージの可視性設定を確認する(非公開のままでよい。
     公開に変更する必要はない)
  3. `read:packages`スコープのclassic PAT(専用に新規発行)で
     GHCR pull用SealedSecretを作成する(`docs/manual-apps.md`冒頭「新しいアプリを
     追加する手順」4番のコマンド例を`<app>=metadatabase-v2`で実行し、
     `envs/dev/secrets/metadatabase-v2.yaml`としてコミット・マージする)
  4. `metadatabase-v2.dev.ibid.lan`のDNS AレコードをFreeIPAに登録
     (`docs/manual-cert-manager-freeipa-acme.md`参照)
  5. `https://metadatabase-v2.dev.ibid.lan/`で200を確認
     (`scripts/update-app-image.sh check-dev metadatabase-v2`でも可)

## brc-cross-search-xsearch / brc-cross-search-resource 固有のメモ

- ソースは[d-usuda/brc-cross-search](https://github.com/d-usuda/brc-cross-search)の
  `main`ブランチ(Sinatra + Puma、DBなし。外部のSPARQLエンドポイント
  `https://knowledge.brc.riken.jp/sparql`を参照するのみ)。Docker対応(`APP_MODE`・
  `PAGE_CONFIG_DIR`)が入るまでは作業ブランチ`feature/docker-app-mode`を追っていたが、2026-10-15に
  mainへマージされ(取り込み元PR #3)ブランチが削除されたため、`scripts/update-app-image.sh`の
  `upstream_branch_for`と両ワークフローのcheckoutの`ref:`をmainに切り替えた。
- **同じソースを2つのアプリとして展開している**。アプリ側の`docker-compose.yml`の
  profileに対応する:

  | アプリ | compose profile | ページ設定 | ポート | 確認用URL(dev) |
  |---|---|---|---|---|
  | `brc-cross-search-xsearch`(横断検索) | `xsearch` | `config/page_xsearch` | 4042 | `https://brc-cross-search-xsearch.dev.ibid.lan/xsearch/catalog/` |
  | `brc-cross-search-resource`(個別アプリ) | `resource` | `config/page_resource` | 4043 | `https://brc-cross-search-resource.dev.ibid.lan/resource/animal/` |

  ツール(`update-app-image.sh`・build workflow・`check-dev`)が「アプリ名 = イメージ名 =
  namespace = Deployment名」前提のため、1つのイメージ・1つのnamespaceにまとめず、
  `images/`・ワークフロー・`envs/<env>/apps/`をアプリごとに持たせている。2つの
  Dockerfileは`APP_MODE`・`PAGE_CONFIG_DIR`・`PORT`以外同じ内容なので、片方を直したら
  もう片方も直す。**ソース更新時は両方に同じSRC_REFで`set-image`を行う**:
  ```bash
  scripts/update-app-image.sh latest-src-ref brc-cross-search-xsearch
  scripts/update-app-image.sh set-image brc-cross-search-xsearch <SRC_REF>
  scripts/update-app-image.sh set-image brc-cross-search-resource <SRC_REF>
  ```
- **URLのパス**: アプリはルート`/`を404固定にしており、ページは
  `/<任意の接頭辞>/<ページ名>/`(`list`・`card`等も同様)で開く。接頭辞は何でもよいが、
  ページ内の相対リンク(`../../../animal/card/...`等)が既存運用(`knowledge.brc.riken.jp`)の
  階層を前提にしているため、既存と同じ`/xsearch/...`・`/resource/...`で開く。Ingressは
  ホスト名ごとに`/`をそのまま転送するだけで、パスの書き換えはしない。
  **外部nginxも接頭辞を外さずに転送する**(`location /xsearch/ { proxy_pass https://brc-cross-search-xsearch.<env>.ibid.lan; }`
  のように`proxy_pass`の末尾に`/`を付けない)。旧サーバー(xsearch01)は辞書を`public/`直下に置き、
  nginxが`/xsearch`を外して転送していたため、同じ書き方のままk8sへ向けるとページは表示されるが
  辞書(`/xsearch/<辞書>.json`)が404になりサジェストが出ない(2026-10-23に本番で発生)。
- **ヘルスチェック**は検索フォームのページ(`/xsearch/catalog/`・`/resource/animal/`)。
  ページ設定のJSONを読んで描画するだけで外部SPARQLには問い合わせないため、
  エンドポイント側の障害でPodが再起動されることはない。一覧・カード表示は
  クラスタから`knowledge.brc.riken.jp`へのHTTPS通信が通る必要がある。
- **アプリ側のDockerfile/`bin/docker-start.sh`は使っていない**(ソースのボリューム
  マウント・ホストのlog/への出力というdocker-compose前提のため)。違いは
  `images/brc-cross-search-*/Dockerfile`冒頭のコメント参照。要点:
  - Pumaの設定は`images/brc-cross-search-*/puma.rb`(アプリ側`config/puma.rb.template`を
    もとに、`stdout_redirect`を外してログを標準出力へ。`kubectl logs`で見られる)。
    アクセスログ(`log/production.log`)も`/dev/stdout`へのリンクにしている。
  - worker数(`WEB_CONCURRENCY`、既定2)とPumaWorkerKillerのメモリ上限
    (`PUMA_WORKER_KILLER_RAM_MB`)はDeploymentの`env`で指定する。上限は
    `resources.limits.memory`と揃える。テンプレートの物理サーバー向けの値(4worker・6442MB)は
    使わない。12時間ごとのローリング再起動はテンプレートどおり残している。
  - `SPARQL_DEBUG=true`をDeploymentの`env`に足すと、実行したSPARQLクエリが`kubectl logs`に出る。
- **devは`RACK_ENV=development`で動かしている**(2026-10-15〜、開発用のため)。SPARQLクエリが
  DEBUGで`kubectl logs`に出る、エラー時にスタックトレースを画面に表示する、reloaderが
  リクエストごとにソース変更を確認する(少し遅くなる)。`deployment.yaml`の値は昇格で本番へ
  そのままコピーされるため、`overlays/production/deployment_patch.yaml`で`RACK_ENV=production`に
  戻している(`env`は名前で突き合わせてマージされるので、他の`env`はそのまま残る)。
  アクセスログは`log/<RACK_ENV>.log`に書かれるため、イメージ側で`production.log`・
  `development.log`の両方を`/dev/stdout`にリンクしている。
  また、Sinatra 4.1以降はdevelopmentモードでHost名を検査し、localhost・IP以外を
  `Host not permitted`(403)で拒否する。イメージのrackup(`images/<app>/k8s.ru`)が
  環境変数`PERMITTED_HOSTS`(Deploymentで`.ibid.lan`)を許可リストに足している。
  公開ホスト名を`.ibid.lan`以外にする場合は、この値にも足すこと。
- **ソースはd-usudaアカウント所有のプライベートリポジトリ**(silver198545はcollaborator)。
  他ユーザー所有のためfine-grained PATは使えず、Deploy Keyの登録にはadmin権限が要るため、
  metadatabase-v2と同じclassic PAT方式にしている。`BRC_CROSS_SEARCH_ACCESS_TOKEN`
  (silver198545で専用に新規発行した`repo`スコープのclassic PAT)をxsearch/resourceの
  両ワークフローで共用し、ブランチ名でfetchしてからSRC_REFをcheckoutする
  (SHA直接指定のfetchは403になるため。riken-diipsと同じ回避策)。
  GHCRパッケージは非公開のまま運用し、namespaceごとにpull用SealedSecret
  (`ghcr-brc-cross-search-xsearch`・`ghcr-brc-cross-search-resource`)を持つ
  (`ghcr_secret_needed_for`に`yes`で登録済み)。
- **導入時に必要な手動手順(dev)**:
  1. `repo`スコープのclassic PAT(専用に新規発行)を
     `gh secret set BRC_CROSS_SEARCH_ACCESS_TOKEN --repo silver198545/ibid-fleet-config`
     で登録し、両ワークフローを再実行して成功を確認する
     (`gh workflow run build-brc-cross-search-xsearch-image.yaml`・
     `gh workflow run build-brc-cross-search-resource-image.yaml`)
  2. `read:packages`スコープのclassic PAT(専用に新規発行。2アプリで共用してよい)で、
     アプリごとにGHCR pull用SealedSecretを作成する(本書「新しいアプリを追加する手順」の
     コマンド例を`<app>=brc-cross-search-xsearch`・`brc-cross-search-resource`で実行し、
     `envs/dev/secrets/<app>.yaml`としてコミット・マージする)。**PATの期限の日を控えておく**
  3. DNSは`*.dev`のワイルドカードで引けるため登録不要
  4. `scripts/update-app-image.sh check-dev brc-cross-search-xsearch`・
     `check-dev brc-cross-search-resource`で200を確認する
- **アプリの外で更新される公開ファイル**(2026-10-20〜)。旧サーバー(xsearch01 = 192.168.1.210)では
  `public/`配下のファイルを外から直接書き換えていたが、コンテナ内のファイルはPod再作成で消え、
  2レプリカでは食い違うため、NFS上のディレクトリ(静的PV `<app>-shared`、
  `pv-nfs-public.yaml`)に置いてDeploymentへ読み取り専用でマウントしている。
  マウント先はイメージの`public/`に無いパスにし、アプリの静的ファイル配信で既存と同じURLのまま返す
  (イメージ内の`public/animal`・`public/dict`は`/animal/`・`/dict/`でしか返らない古い版)。
  **devとproductionは同じディレクトリ(`brc-cross-search/shared/`)を参照する**
  (更新者のコピー先が1か所で済み、環境間で内容がずれないため。dev側は読み取り専用なので本番のファイルを壊さない。
  代わりに「新しい辞書をdevだけで先に試す」ことはできない)。

  | ファイル | URL | NFS(`192.168.1.1:/data/nfs/`配下) | 更新者 |
  |---|---|---|---|
  | resourceのsitemap | `/resource/animal/sitemap.xml` | `brc-cross-search/shared/resource/animal/` | productionのCronJob `brc-cross-search-resource-sitemap`(毎日JST 20:00) |
  | resourceの辞書(4ファイル) | `/resource/dict/dna/<辞書>.json` | `brc-cross-search/shared/resource/dict/dna/` | Virtuoso01の辞書生成ルーチン(usuda) |
  | xsearchの辞書(3ファイル) | `/xsearch/<辞書>.json` | `brc-cross-search/shared/xsearch/` | Virtuoso01の辞書生成ルーチン(usuda) |

  - **sitemap**は同じクラスタのsparqlist(SPARQLet `brcmouse_sitemap`)をServiceで直接呼んで
    書き込む。Googlebotの巡回(およそ21時)前に更新する(Redmine #1610)。出力はXMLではなく
    IDを1行に1つ並べたテキスト(旧サーバーと同じ内容)。取得失敗時は前回分を残して失敗終了し、
    26時間成功が無いと`BrcCrossSearchSitemapStale`で通知される。書き込み先がdevと共有のため、
    **CronJobはproductionでだけ動かし、devでは`suspend: true`で止めている**(devのsparqlistで
    試し中のSPARQLetの結果で本番のsitemapを上書きしないため。止めている間は監視の対象外)。
    手動実行(production。devで実行しても書き込み先は本番と同じになる):
    `kubectl -n brc-cross-search-resource create job --from=cronjob/brc-cross-search-resource-sitemap sitemap-manual-$(date +%s)`
  - **辞書**はVirtuoso01(NFSをマウント済み)上の`/home/usuda/routine/autocomplete`の生成物を、
    usudaの転送スクリプトが共有ディレクトリへ直接コピーする(旧サーバーへのssh/scpは不要になる)。
    xsearchの辞書は外部ページに埋め込まれた`dna-cross-search.js`が直接読むためURLを変えないこと。
    usudaの2本の転送スクリプト(xsearch用・dnabank用)は、ssh/scpの代わりに次のようにコピーする
    (`N`はVirtuoso01での`192.168.1.1:/data/nfs`のマウント先。既存ファイルの退避はxsearchが`old/`、
    dnabankが`<辞書>.old`。例はdnabank用):
    ```bash
    dest=$N/brc-cross-search/shared/resource/dict/dna   # xsearch用は $N/brc-cross-search/shared/xsearch
    for file in "${files[@]}"; do
      f=$(basename "$file")
      [ -f "$dest/$f" ] && cp -p "$dest/$f" "$dest/$f.old"
      cp "$file" "$dest/.$f.tmp" && mv -f "$dest/.$f.tmp" "$dest/$f"
    done
    ```
  - **導入の経緯**: 2026-10-20に環境別ディレクトリ(`brc-cross-search/dev/`・`production/`、
    PV `<app>-public`)で導入し(#320〜#322)、同日中に共有ディレクトリへ切り替えた。PVの参照先は
    作成後に変えられないため、切替はPV/PVCの名前ごと変えて行った(旧PV/PVCはバンドルから消えたため
    Helmが削除する。静的PVなのでNFS上のデータは消えず、旧ディレクトリは手動で消す(2026-10-23に削除済み)。
    旧PVCを使う完了済みJobのPodが残っているとPVCがTerminatingで止まるので、そのJobを消す)。
    ディレクトリは`install -d -m 0777`で作る(CronJob(uid 1000)とusudaの両方が書き込むため)。
  - **旧サーバーからの移行は完了済み**(2026-10-23)。外部nginx(`knowledge.brc.riken.jp`)をk8sへ
    切り替えた後、xsearch01のRundeckジョブ「BRC Cross Search(Resource) Sitemap UPDATE Script」を
    無効化し、旧サーバーへの辞書転送もやめた。sitemap・辞書の更新はk8s側(上の表)だけで行う。
