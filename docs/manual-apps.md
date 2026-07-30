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

[sparqlist](https://github.com/dbcls/sparqlist)(Express製、DBなし)は保存した
SPARQLet(`repository/`配下のMarkdown設定ファイル)の永続化が必要な点が上記2つと異なる。
PVC(`envs/<env>/apps/sparqlist/pvc.yaml`)を持つ以外は同じ`apps/`パターンに乗せている
(詳細は下記「sparqlist 固有のメモ」参照)。

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

**`scripts/update-app-image.sh`の`promote-staging`/`promote-production`は初回昇格専用**
(`envs/<to>/apps/<app>`を新規作成しホスト名書き換え・SealedSecret作り直しまで行う)。
2回目以降、既に昇格済みの環境へイメージバージョンだけを反映したい場合は
`deploy-staging`/`deploy-production`(`deploy-dev`と同じくイメージタグの書き換えのみ)を使う。
特にproductionは`cleanup-staging`に相当する削除ステップが無く`envs/production/apps/<app>`が
昇格後も残り続けるため、2回目以降の更新は必ず`deploy-production`を使うこと
(`promote-production`をもう一度実行すると「既に存在します」エラーになる)。

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

ここまでの変更(コピーしたマニフェスト + 作り直したSealedSecret)をコミットし、
`gh` CLIでPRを作成する(`promote.yaml`が自動化しているコミット/PR作成を
`apps/`用に手動でなぞる形。ブランチ名・コミットメッセージ・PR本文は自由だが、
以下は実例):

```bash
git checkout -b promote/<app>-<from>-to-<to>
git add "envs/<to>/apps/<app>" "envs/<to>/secrets/<app>.yaml"
git commit -m "feat: <app>を<to>環境へ昇格"
git push -u origin promote/<app>-<from>-to-<to>

gh pr create --title "feat: <app>を<to>環境へ昇格" --body "$(cat <<'EOF'
## 昇格内容

`envs/<from>/apps/<app>` → `envs/<to>/apps/<app>` (手動昇格。`promote.yaml`は`sites/`のみ対象のため`apps/`はこのPRで手動対応)

- ホスト名を `<app>.<from>.ibid.lan` → `<app>.<to>.ibid.lan` に変更(`ingress.yaml`)
- GHCR pull用SealedSecretを `<昇格先のkubectlコンテキスト>` 向けに作り直し(`envs/<to>/secrets/<app>.yaml`)

## 前提(マージ前に完了済み)

- [x] FreeIPAへ `<app>.<to>.ibid.lan` のDNS Aレコード登録
- [x] <from>で<app>が正常稼働していることを確認済み

## マージ後の確認

- [ ] `kubectl --context <昇格先のkubectlコンテキスト> -n <app> get pods,ingress`
- [ ] `curl -k https://<app>.<to>.ibid.lan/` で疎通確認
EOF
)"
```

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
   (WordPressと異なりDBが無いので、本番データのリストアは基本不要。
   Deploymentが上がりIngress経由で表示できれば十分)。
   ただし**PVCで永続データを持つアプリ(sparqlistの`repository/`等)は、
   WordPressと同様に本番データを結合テストに使うこともできる**
   (手順は「sparqlist 固有のメモ」の「stagingでの本番データ結合テスト」参照)
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
  brc-advanced-search/riken-diipsと異なる唯一の点。`envs/<env>/apps/sparqlist/pvc.yaml`で
  WordPressのwp-contentと同じLonghorn RWX(`longhorn-r1`)のPVCを持ち、
  `deployment.yaml`で`/app/repository`(`REPOSITORY_PATH`のデフォルト値`./repository`が
  WORKDIR `/app`からの相対パスで解決される)にマウントしている。非rootコンテナからの
  書き込みを許可するため、Pod `securityContext.fsGroup`を設定している(bitnamiチャートの
  `podSecurityContext.fsGroup`と同じ考え方。ベースイメージのUID/GIDを調べる必要がない)。
- **管理API(SPARQLetの作成・編集)は`ADMIN_PASSWORD`環境変数で保護される**
  (空にすると管理機能自体が無効化される仕様)。パスワードをGit管理下に置かないため、
  `scripts/seal-sparqlist-secret.sh <env>`でSealedSecretとして
  `envs/<env>/secrets/sparqlist.yaml`に封印する(brc-advanced-search/riken-diipsの
  同名ファイルはGHCR pull用Secretだが、sparqlistでは用途が異なる。`update-app-image.sh`の
  `promote-staging`/`promote-production`もこの違いを認識し、GHCR pull用の代わりに
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
- **既存運用からの`repository/`データの投入(移行)**: DBが無いためWordPressのような
  DBダンプ復元は不要で、`repository/`ディレクトリのファイルをPVCへコピーするだけでよい。
  対象環境(通常は本番データを実際に使う環境。まずdevでファイル一式が壊れていないか
  確認してからでもよい)のPodに対して行う:
  ```bash
  # ローカルで既存運用のrepository/配下だけを固める
  tar czf sparqlist-repository.tar.gz -C <既存運用のsparqlistディレクトリ> repository

  kubectl --context <対象envのコンテキスト> -n sparqlist get pods -l app=sparqlist

  # 起動時にイメージへ焼き込まれているサンプルSPARQLet(adjacent_prefectures.md等)を
  # 退避してから展開する
  kubectl --context <対象envのコンテキスト> -n sparqlist exec <sparqlist-pod> -- \
    mv /app/repository /app/repository.orig
  kubectl --context <対象envのコンテキスト> -n sparqlist cp sparqlist-repository.tar.gz \
    <sparqlist-pod>:/tmp/sparqlist-repository.tar.gz
  kubectl --context <対象envのコンテキスト> -n sparqlist exec <sparqlist-pod> -- \
    tar xzf /tmp/sparqlist-repository.tar.gz -C /app -m --no-same-permissions
  kubectl --context <対象envのコンテキスト> -n sparqlist exec <sparqlist-pod> -- \
    rm /tmp/sparqlist-repository.tar.gz
  ```
  `repository`はReadWriteManyの共有ボリュームなので、1つのPodに反映すれば他のreplicaにも
  即座に反映される。動作確認後、退避した`repository.orig`は削除してよい
  (`kubectl ... exec <sparqlist-pod> -- rm -rf /app/repository.orig`)。
  `kubectl exec`/`cp`はコンテナ内プロセス(`USER node`)権限で実行されるため、
  fsGroupにより書き込み自体は通るが、念のため反映後に一覧APIやWeb UIで
  想定件数のSPARQLetが見えることを確認すること。
  **実際に踏んだ問題**: `mv /app/repository /app/repository.orig`は
  `Permission denied`で失敗する(`/app`自体がroot所有で、非rootの`node`ユーザーには
  親ディレクトリへの書き込み権限が無くrenameできないため。無害なので無視してよい)。
  また`-m --no-same-permissions`を付けずに`tar xzf`を実行すると、既存の(マウント
  ポイントである)`repository/`自体のmtime/mode復元に失敗し終了コードが非0になる
  (ファイル本体の展開自体は成功する)。上記コマンドのようにこの2オプションを
  付けることでその失敗ごと回避できる。展開後にファイル数
  (`ls /app/repository | wc -l`)が想定件数(元tarballのファイル数+既存の
  `lost+found`)と一致していれば問題ない。
- **既存イメージ更新サイクルでのstaging結合テスト(本番データ利用)**:
  WordPressの運用([operations-flow.md](operations-flow.md)参照)と同じく、
  イメージ更新のstaging結合テストに本番の`repository/`データを使いたい場合は、
  ローカルにアップロードしたtarballではなく**稼働中のproduction Podから直接**
  取得してstagingへ流し込める(DBが無いためmysqldump相当の準備は不要、
  ファイルコピーのみで完結する)。`scripts/update-app-image.sh`の
  `sync-staging-data`サブコマンドでこの一連の操作を実行できる
  (`persistent_data_dir_for`に登録済みのアプリのみ対応。現状sparqlist限定):
  ```bash
  scripts/update-app-image.sh sync-staging-data sparqlist
  ```
  中身は次のコマンド相当(手動で行いたい場合や、他のPVC付きアプリを
  `persistent_data_dir_for`にまだ登録していない場合はこちらを使う):
  ```bash
  PROD_POD=$(kubectl --context prod1 -n sparqlist get pods -l app=sparqlist -o jsonpath='{.items[0].metadata.name}')
  STG_POD=$(kubectl --context staging1 -n sparqlist get pods -l app=sparqlist -o jsonpath='{.items[0].metadata.name}')

  # productionの/app/repositoryを固めてローカルへ取得
  kubectl --context prod1 -n sparqlist exec "$PROD_POD" -- \
    tar czf /tmp/sparqlist-repository.tar.gz -C /app repository
  kubectl --context prod1 -n sparqlist cp "$PROD_POD":/tmp/sparqlist-repository.tar.gz \
    ./sparqlist-repository-prod.tar.gz
  kubectl --context prod1 -n sparqlist exec "$PROD_POD" -- rm /tmp/sparqlist-repository.tar.gz

  # stagingへ展開(既存データへの上書きになる点は「repository/データの投入」と同じ)
  kubectl --context staging1 -n sparqlist cp ./sparqlist-repository-prod.tar.gz \
    "$STG_POD":/tmp/sparqlist-repository.tar.gz
  # -m --no-same-permissions を付けないと、マウントポイントであるrepository自体の
  # 属性復元にtarが失敗し終了コードが非0になる(「実際に踏んだ問題」参照。
  # ファイル本体の展開自体はこのオプション無しでも成功する)。
  kubectl --context staging1 -n sparqlist exec "$STG_POD" -- \
    tar xzf /tmp/sparqlist-repository.tar.gz -C /app -m --no-same-permissions
  kubectl --context staging1 -n sparqlist exec "$STG_POD" -- rm /tmp/sparqlist-repository.tar.gz
  ```
  結合テスト終了後は通常どおり`cleanup-staging`でstaging自体を削除するため、
  本番データをstagingに残置する心配はない(WordPressの「サイトをstagingから削除する」
  相当の後始末が、apps/では`cleanup-staging`一発で完結する)。
  **production反映前のバックアップ**については、`repository`PVC
  (`envs/<env>/apps/sparqlist/pvc.yaml`)はLonghornの`envs/<env>/infra/longhorn-jobs/`
  (`groups: [default]`)の対象に自動的に含まれるため、WordPressのような手動バックアップ
  取得は不要(6時間毎スナップショット・日次バックアップが既にかかっている)。
