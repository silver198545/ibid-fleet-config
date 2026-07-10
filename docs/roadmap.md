# 今後の開発方針(ロードマップ)

2026-07-05時点の到達点と、数十サイトの本番運用に向けて残る課題の整理。
優先度と「いつまでに決めるべきか」のトリガーを明記する。
完了した項目は消さず「済」に更新し、この文書を意思決定の記録として育てる。

## 到達点(完了済みの基盤)

- 3クラスタ(dev1 / staging1 / prod1)+ 単一mainブランチ・環境別ディレクトリのGitOps
- PR承認ゲート付きの昇格フロー(promoteワークフロー、本番はCODEOWNERS必須)
- 全サイト共通のラッパーチャート(GHCR公開、digest固定イメージ)
- プラグインのGit宣言同期(fleet.yamlの `plugins:` → wp-cli Job)
- Longhorn定期バックアップ(NFS、環境別、本番14世代)
- Sealed SecretsによるサイトSecretのGit管理化(封印鍵は3環境ともオフラインバックアップ済み)
- **DR実証済み**: クラスタ全損→完全復元([manual-multi-env.md](manual-multi-env.md) 8.参照)

---

## 🔴 優先度・高: スケール前に決めるべき設計判断

### 1. Ingress方式への転換(LoadBalancer IP枯渇対策) 【済(3環境、2026-07-10)】

- **現状**: 1サイト=1 LoadBalancer IPだった。IPPoolは dev 20個 / staging 10個(.61-.70、
  2026-07-08にHarvester UI VIPの.60を除外) / **本番11個(192.168.1.90-100)** しかなく、
  **本番は11サイト、stagingは10サイトで頭打ち**という制約があった。
- **方針**: 1つのLB IP + Ingressコントローラ(ホスト名ベースのルーティング)+ TLS終端の
  構成へ転換する。RKE2組み込みのTraefik(IngressClass名`traefik`)をそのまま使う
  (追加のIngressコントローラ導入は不要)。
- **実施内容(dev、2026-07-10)**:
  - Traefik(`rke2-traefik`)をRancher `Cluster` CRの`chartValues`経由でLoadBalancer化
    (`service.spec.type: LoadBalancer`、**キーパスが`service.type`ではなく
    `service.spec.type`である落とし穴あり**)。dev1は共有LB IP`192.168.1.39`(pool1)を取得。
    手順: [manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)
  - `charts/ibid-wordpress`をv0.3.0へ(Ingress移行時の値の書き方をコメントで用意、
    チャート既定値はLoadBalancerのまま=未移行サイトに影響なし)。
    bitnami/wordpressサブチャートが`ingress.*`をネイティブサポートしているため
    カスタムIngressテンプレートは不要だった。
  - dev既存2サイト(web, dna)を`service.type: ClusterIP` + `ingress.enabled: true`
    (`cert-manager.io/cluster-issuer: freeipa-acme`アノテーション付き)へ移行。
    IngressはTraefikのLB IPに正しく紐付いた(`kubectl get ingress`でADDRESS確認済み)。
  - 監視(blackbox probe)はService(namespace正規表現+port名`http`)による動的発見のため
    無変更で動作継続。
  - DNS Aレコード登録(`web.dev.ibid.lan`/`dna.dev.ibid.lan` → Traefik LB IP)完了。
  - Certificate発行完了(`web.dev.ibid.lan-tls`/`dna.dev.ibid.lan-tls`ともReady=True)。
    `https://web.dev.ibid.lan/` / `https://dna.dev.ibid.lan/` でHTTPS 200・
    FreeIPA CA発行証明書での応答を確認済み(2026-07-10)。
- **解消済みの障害(2026-07-10発生・解消)**: Certificate発行が
  `order is in "errored" state: Failed to create Order: 404`で失敗する事象が発生。
  **原因はcert-manager側ではなく、ibidipa1で`dnf-automatic`が06:35 JSTに自動適用した
  パッケージ更新をきっかけに、pki-tomcatd上のCA/ACME webappのホットリデプロイが失敗し
  (`Unable to stop ACME engine: An invalid Lifecycle transition was attempted`)、
  Tomcat自体は稼働中のままCA/ACME機能だけが404を返し続ける状態になっていたこと**
  (ibidipa2でも同時刻`dnf-automatic`実行の形跡あり、同様の事象)。
  `systemctl restart pki-tomcatd@pki-tomcat.service`を両CAサーバーで実行し復旧、
  cert-manager側もCertificate/CertificateRequestを再作成して即時リトライさせ発行成功。
  **恒久対策の宿題**: ibidipa1/ibidipa2の`dnf-automatic`が無人適用モード
  (`apply_updates=yes`相当)になっており、CAサービスを無警告で停止させ得ることが判明した。
  `notify`のみに変更し、月次メンテナンス日(6.参照)にまとめて適用する運用への見直しを検討。
- **staging/productionへの展開(2026-07-10完了)**:
  - staging1のTraefikをLoadBalancer化(共有LB IP`192.168.1.63`、pool2)。
    promoteワークフロー(dev→staging、site=all)でweb/dna両サイトを昇格
    (これによりstagingが抱えていたチャートバージョン/プラグイン一覧の環境ドリフトも
    同時に解消。低優先度の宿題「webサイトのstaging/production昇格」も併せて解消)。
    Ingress・Certificate(FreeIPA CA発行)・HTTPS疎通(`web.staging.ibid.lan`/
    `dna.staging.ibid.lan`)を確認済み。
  - prod1のTraefikをLoadBalancer化(共有LB IP`192.168.1.91`、pool3)。
    promoteワークフロー(staging→production、site=web)でwebサイトを昇格。
    Ingress・Certificate・HTTPS疎通(`web.production.ibid.lan`)を確認済み。
    productionには`dna`サイトは元々存在しないため対象外(現状維持)。
  - promoteワークフローは環境間で`fleet.yaml`をファイルごとコピーするだけのため、
    Ingressの`hostname`値(`<site>.<env>.ibid.lan`)は昇格後に手動で環境名部分を
    修正する必要がある(自動では書き換わらない。今回はPRブランチに追いコミットで対応)。
  - 外部リバースプロキシ経由の公開(dev「web」サイトのみ、`wpdev2.brc.riken.jp`)は
    今回staging/productionには適用していない(社内限定運用のため)。同様の公開が
    必要になった場合は[manual-wordpress-restore.md](manual-wordpress-restore.md)
    6b.の手順を参照。
- **残作業**: ibidipa1/ibidipa2の`dnf-automatic`設定の見直し(FreeIPA管理者、上記の
  障害の恒久対策)。

### 2. TLS/ドメイン/公開経路の設計 【済(3環境、2026-07-10)】

- **決定事項**: 社内限定サイトはFreeIPA(`ibid.lan`)のACMEから証明書を発行する。
  FreeIPA(v3333)→ゲストクラスタ(v140)は意図的なセグメント分離で到達不可のため、
  HTTP-01ではなく**DNS-01(cert-manager標準のRFC2136ソルバー、FreeIPAのDNSへTXTレコードを
  直接動的更新)**を採用。外部公開が必要なサイトは別ドメイン+外部NginxProxyManager経由とし、
  本リポジトリのcert-manager/FreeIPA ACME連携の対象外(NPM側で独自にLet's Encrypt等を使う)。
  ホスト名規約は`<site>.<env>.ibid.lan`。
- **前提作業**: 3クラスタ全台に第2NIC(FreeIPA向けVLAN、Harvester側)を追加してFreeIPAへの
  到達性を確保した。FreeIPA側ではTSIG鍵によるDNS動的更新の許可と、ACME機能自体の不完全な
  セットアップ(CAプロファイル未移行・テンプレート変数未置換・エージェントグループ未所属)を
  ibidipa1/ibidipa2の両CAサーバーで修復した。手順:
  [manual-cert-manager-freeipa-acme.md](manual-cert-manager-freeipa-acme.md)
- **現状**: dev/staging/production全環境にcert-manager + ClusterIssuer(`freeipa-acme`)を
  導入済み。devで`web.dev.ibid.lan`向け証明書発行のsmoke testを実施し、ibidipa1/ibidipa2
  双方のACMEエンドポイント経由での発行成功を確認済み。production導入後の疎通確認
  (cert-manager Pod Running、ClusterIssuer Ready、TSIG鍵SealedSecret Synced)も完了(2026-07-10)。
  3環境ともIngress化・DNS登録・Certificate発行(FreeIPA CA発行)まで一通り完了(上記1.参照)。
- **残作業**: なし(サイト追加時は`<site>.<env>.ibid.lan`のIngress設定とDNS登録を
  同じ手順で行うだけでよい)。

### 3. ストレージ容量計画 【対応方針決定・既存サイト移行は作業中(2026-07-10)】

- **試算で発覚した問題**: 本番30サイト目標を見据えて試算したところ、致命的な制約が
  見つかった。ゲストノードVMのディスクは64GiBのrootディスク1枚のみで、Longhornの
  専用データディスクがない。さらに、そのVM仮想ディスク自体がHarvester側Longhornで
  3重化されている上に、ゲストクラスタ内のLonghorn(`numberOfReplicas: 3`)がさらに
  3重化している——つまり**実データが3×3=9倍に物理増幅**されていた。
  5ノード×クラスタの実効プールは約305GiBしかなく、現状(dev/staging: 2サイト+監視で
  55%消費、production: 1サイト+監視で47%消費)から**あと2サイト追加した時点で
  Longhornの90%アラートに到達**する計算だった。実データ使用率自体は
  PVC割り当ての5〜11%程度と低く、逼迫していたのは「予約容量」の方だった。
- **対応方針**: ハードウェア(Harvesterホストへの物理ディスク増設)を増やさず、
  二重増幅そのものを解消する方向で対応する。
  - **調査の結果、Harvester CSI driver(`driver.harvesterhci.io`)が3クラスタとも
    既に導入済み**で、`harvester` StorageClassが使えることが判明した
    (Rancherのharvesterノードドライバが標準で入れているもの)。ただし
    `fsGroupPolicy: ReadWriteOnceWithFSType`のためRWO専用。
  - **MariaDBのPVC(RWO)は`harvester` StorageClassへ移行**。ゲストクラスタの
    Longhornを経由せずHarvesterの仮想ディスクに直接乗るため、増幅が9倍→3倍になり、
    かつゲストノードのLonghornプールの消費がゼロになる。
  - **wp-content(RWX、Web複数レプリカ共有)は`harvester`に載せられないため**、
    新設した`longhorn-r1` StorageClass(既存`longhorn`と同パラメータ、
    `numberOfReplicas`のみ1)へ移行。増幅は9倍→3倍(耐障害性はHarvester側の
    3重化に委ねるトレードオフを許容)。
  - 実施内容: `envs/<env>/infra/longhorn-r1/`(新StorageClassバンドル、dev導入済み、
    staging/production未展開)、`charts/ibid-wordpress` v0.4.0(両PVCのstorageClass
    変更)。既存サイトの実データ移行手順は
    [manual-storage-migration.md](manual-storage-migration.md)参照。
- **dev実施結果(2026-07-10、web/dna完了)**: 移行前はdev1の5ノードとも
  Longhornの`Scheduled`使用率55〜62%だったが、両サイト移行+旧ボリューム削除後は
  **0〜49%(平均26%)まで低下**。移行後の1サイトあたりの footprint は
  `wp-content` 10GiB(`replica=1`のみ)、MariaDBはゲストLonghornプールを一切消費しない
  (0GiB)ため、旧来の54GiB/サイトから**実質10GiB/サイト**まで下がった。
  移行作業で判明した実務上の注意点(Fleetの継続的な再同期が手動scaleを打ち消す→
  事前にBundleをpausedにする必要がある等)はランブックに反映済み。
  30サイト到達の再試算: 30サイト×10GiB + 監視90GiB(サイト数に依存しない固定
  オーバーヘッドとしてproduction想定の値を合算) = 390GiB nominal。90%ラインで
  確保するには実効プール≥433GiB(≒87GiB/ノード)必要——現状の61GiB/ノードから
  **約26GiB/ノードの専用ディスク追加**で足りる計算(旧設計での380GiB/ノード要求
  からは大幅に圧縮された)。Harvester側の新規物理
  必要量も概算 585GiB程度(現状の空き約798GiBで収まる)。
- **staging実施結果(2026-07-10、web/dna完了)**: `longhorn-r1`バンドル展開・両サイト
  移行・旧ボリューム削除まで完了。移行後のLonghorn`Scheduled`使用率は16〜33%
  (5ノード平均約26%)で、devと同様の削減効果を確認。移行中、完了済みの
  plugin-sync Job(wp-cliでのプラグイン同期用)がwp-content PVCを参照し続けて
  削除がブロックされる事象が2サイトとも発生(Podは`Completed`でも
  `persistentvolumeclaim`の`pvc-protection`finalizerは解放されない)。
  Jobを削除すれば解消する(Fleetが再同期時に同名で再作成するため実害なし)。
- **残作業**: `longhorn-r1`バンドルのproduction展開、production(web)の実データ移行。
  全環境完了後、上記の再試算を実測値で確定させ、ノード専用ディスク追加の要否を
  最終判断する。
- 監視スタック(Prometheus PVC)は対象外(サイト数と連動して増える容量ではないため)。

## 🟠 優先度・中: 本番コンテンツが入る前に塞ぐ運用の穴

### 4. 監視・アラートの導入 【済(dev: 2026-07-06、staging/production: 2026-07-07)】

- **採用構成**: rancher-monitoring 109.0.3(+ blackbox-exporter)を
  `envs/<env>/infra/monitoring*` の5バンドルとしてGitOps導入。
  全サイトHTTP死活監視(Serviceの動的発見、サイト追加時の設定変更不要)、
  Longhornバックアップ成否・容量アラート(3.の容量アラートを兼ねる)、
  Slack通知(Webhook URLは環境別SealedSecret)。
  運用手順: [manual-monitoring.md](manual-monitoring.md)
- **残作業**: ~~staging / production への展開PR~~ 済(2026-07-07、手動PRで全環境展開。
  Webhook URLは全環境で共通=同一Slackチャンネル。通知タイトルの`[cluster]`で環境を識別。
  チャンネルを分けたくなったら環境ごとに再封印する — manual-monitoring.mdのローテーション手順)。
- 制約: probeはクラスタ内経由のため**LB IP経路の障害・IPPool枯渇は検知不可**。
  1.のIngress化・2.のDNS導入時に外形監視を再検討する。

### 5. バックアップの3-2-1化

- **現状**: 全環境のバックアップがNFSサーバー(192.168.1.1)1台に集中。
  **そこが壊れると全環境のバックアップが同時消失**する。
- **方針**: NFSの先のオフサイト/別メディアへの二次コピーを検討
  (S3互換への複製、別NASへのrsync等)。封印鍵バックアップの保管場所も冗長化する。
- **トリガー**: 本番コンテンツの重要度が上がる前。

### 6. WordPressコア/プラグインの定期更新サイクル 【済(運用ルール化: 2026-07-08)】

- **現状**: イメージはdigest固定=セキュリティパッチも意図的に止まっている。
  更新は「digest更新→チャートversion上げ→dev→staging→本番昇格」の手動フロー。
- **決定事項**: **毎月1日を目安に**(前後にずれても月を跨がなければ可)定期メンテナンス日とし、
  WPコア/プラグインの確認・更新(`wp-file-manager` の必要性再検討を含む)を
  7.の鍵再バックアップとまとめて実施する。手順は
  [manual-multi-env.md](manual-multi-env.md) 4章「定期メンテナンス日」に明記。
  初回は2026-08-01。

### 7. 封印鍵ローテーションへの追従 【済(運用ルール化: 2026-07-08)】

- **現状**: Sealed Secretsコントローラは30日ごとに新しい鍵を自動追加する。
  ローテーション後に再バックアップしないと、新鍵で封印されたSecretが復元不能になる。
- **決定事項**: 個別にローテーション日を追跡せず、**6.と同じ毎月1日を目安の
  定期メンテナンス日**に3環境分の鍵バックアップコマンドをまとめて実行する運用とした
  (コマンドは冪等なのでローテーションの有無を気にせず毎回実行してよい)。手順は
  [manual-multi-env.md](manual-multi-env.md) 6章参照。次回(初回)は2026-08-01。

## 🟡 優先度・低: 小さいが効く宿題

- **リポジトリのprivate化 → publicへ差し戻し** 【2026-07-08 に revert】: 一度Private化した
  (GitRepo認証をGitHub fine-grained PATで設定、`fleet-default`の`auth-55znx`を3環境で共有)。
  その後 PROMOTE_TOKEN 登録の確認作業で、**GitHub Freeの個人アカウントではprivateリポジトリで
  ブランチ保護/rulesetsが使えない**(GitHub Pro等へのアップグレードが必須)ことが判明し、
  `main`のブランチ保護ルール(PR必須・CODEOWNERS必須・validate必須チェック)が
  Private化と同時に消えていたことを発見。CODEOWNERS必須化という昇格ゲートの根幹の方が
  重要と判断し、リポジトリをpublicへ差し戻してブランチ保護を再作成した(GitHub API経由、
  設定内容は[manual-multi-env.md](manual-multi-env.md) 1.と同一)。
  GitRepoのPAT認証設定はRancher UI側に残したまま(実害なし、再private化時に流用可)。
  詳細は[fleet-bootstrap/README.md](../fleet-bootstrap/README.md)参照。GHCRパッケージは
  引き続きpublicのまま。
  **今後privateに戻したい場合は、先にGitHub Proへのアップグレード(個人アカウント、
  月額数ドル)を検討すること。**
- **PROMOTE_TOKENの登録** 【済(2026-07-08)】: fine-grained PAT(対象リポジトリのみ、
  Contents/Pull requests: Read and write)をリポジトリSecretsに登録し、昇格PRで
  validateが自動起動するようになった([manual-multi-env.md](manual-multi-env.md) 1.参照)。
  PATに有効期限があるため、期限切れ前の再発行が必要。
- **webサイトのstaging/production昇格** 【済(2026-07-10、Ingress化の昇格と同時に解消)】:
  devだけv0.2.1+プラグイン一覧で先行していたドリフトは、Traefik Ingress化のpromoteで
  併せて収束させた。
- **secretsバンドルのnamespace順序問題の恒久修正**: DR時に `kubectl create ns` が
  手動で必要(runbook 8.の手順5)。seal-site-secrets.shの生成物にNamespaceを含め、
  secretsバンドルに `takeOwnership: true` を付ける改修で自動化できる。
- **一括バージョンアップ用ツール**: サイトが増えると全fleet.yamlのチャートversionや
  プラグイン版数の一括更新が手作業になる。数十サイト到達前に簡単なスクリプト化を検討。
- **テスト痕跡の掃除**: dev1の `pre-fleet-adoption-*` スナップショット2件、
  stagingの `pre-dr-drill-*` バックアップ4件(日次バックアップの安定稼働確認後に削除可)。

## 将来検討(急がない)

- **クラスタ定義のGitOps化**(Rancher provisioning-v2)— 誤マージの影響半径が
  大きいため3クラスタ規模では見送り中。
- **DB層の冗長化**(mariadb-galera等)— 現在は単体MariaDB。可用性要件が上がったら。
- **昇格の自動化深化**(dev→stagingのPR自動生成、Kargo再評価)— 昇格頻度が
  上がって手動dispatchが煩雑になったら。
- **Bitnamiチャート依存からの脱却** — イメージは自前化済みだが、チャートは
  bitnami/wordpress依存が残る。提供形態が再度変わった場合は公式イメージ+
  汎用チャートへの移行を検討。
