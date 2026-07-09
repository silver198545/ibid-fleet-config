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

### 1. Ingress方式への転換(LoadBalancer IP枯渇対策)

- **現状**: 1サイト=1 LoadBalancer IP。IPPoolは dev 20個 / staging 10個(.61-.70、
  2026-07-08にHarvester UI VIPの.60を除外) / **本番11個(192.168.1.90-100)** しかなく、
  **本番は11サイト、stagingは10サイトで頭打ち**。
- **方針**: サイト数が10に近づく前に、1つのLB IP + Ingressコントローラ
  (ホスト名ベースのルーティング)+ TLS終端の構成へ転換する。
  ドメイン設計・DNS・証明書(下記2.)とセットで検討すること。
- **トリガー**: 本番サイト数が8を超える前に着手。

### 2. TLS/ドメイン/公開経路の設計 【進行中: dev環境で発行確認済み(2026-07-09)】

- **決定事項**: 社内限定サイトはFreeIPA(`ibid.lan`)のACMEから証明書を発行する。
  FreeIPA(v3333)→ゲストクラスタ(v140)は意図的なセグメント分離で到達不可のため、
  HTTP-01ではなく**DNS-01(cert-manager標準のRFC2136ソルバー、FreeIPAのDNSへTXTレコードを
  直接動的更新)**を採用。外部公開が必要なサイトは別ドメイン+外部NginxProxyManager経由とし、
  本リポジトリのcert-manager/FreeIPA ACME連携の対象外(NPM側で独自にLet's Encrypt等を使う)。
  ホスト名規約は`<site>.<env>.ibid.lan`。
- **前提作業**: 3クラスタ全台に第2NIC(FreeIPA向けVLAN、Harvester側)を追加してFreeIPAへの
  到達性を確保した。FreeIPA側ではTSIG鍵によるDNS動的更新の許可と、ACME機能自体の不完全な
  セットアップ(CAプロファイル未移行・テンプレート変数未置換・エージェントグループ未所属)
  を修復した。手順: [manual-cert-manager-freeipa-acme.md](manual-cert-manager-freeipa-acme.md)
- **現状**: devにcert-manager + ClusterIssuer(`freeipa-acme`)を導入し、
  `web.dev.ibid.lan`向け証明書の発行をsmoke testで確認済み。
- **残作業**: ibidipa2側にも同種のACME不具合(プロファイル変数未置換・エージェントグループ
  未所属)が無いか確認、cert-managerのstaging/production展開、各サイトのIngress化
  (Traefik LoadBalancer化とセットで進める、下記1.参照)。

### 3. ストレージ容量計画

- **現状**: 1サイト=18Gi(wp-content 10Gi + DB 8Gi)× レプリカ3 = 実効約54Gi/サイト。
  数十サイトではクラスタあたり数TB規模になる。
- **方針**: ノードのディスクサイズを確認し、Longhornの容量アラート(4.の監視と連動、
  **ノード使用率75%/90%のアラートは4.で実装済み**)を設定する。
  サイトのPVCサイズ既定値(チャートvalues)の見直しも選択肢。
- **トリガー**: サイト量産開始前に一度試算する。

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
- **webサイトのstaging/production昇格**: devだけv0.2.1+プラグイン一覧で先行しており
  環境ドリフト状態。promoteで収束させる。
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
