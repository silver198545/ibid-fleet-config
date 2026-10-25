# IBID基盤の仕組み

WordPressサイトと自作アプリを動かしているIBID基盤が、どう組み立てられていて、変更やデータがどう流れるかを、
1章1テーマの図で説明する。手順は書かない(各章の最後に、詳しい手順書へのリンクがある)。
図はGitHub上でそのまま表示される(Mermaid)。図の中の `{site}`・`{app}` はサイト名・アプリ名。2026-10-20時点の構成。

1. [全体構成](#1-全体構成)
2. [3つの環境とバンドル](#2-3つの環境とバンドル)
3. [GitOps: Gitが正、Fleetが適用する](#3-gitops-gitが正fleetが適用する)
4. [変更の流れ: dev → 本番](#4-変更の流れ-dev--本番)
5. [WordPressサイトの中身](#5-wordpressサイトの中身)
6. [WordPressのデータとバックアップ](#6-wordpressのデータとバックアップ)
7. [自作アプリのイメージ](#7-自作アプリのイメージ)
8. [秘密情報(Sealed Secrets)](#8-秘密情報sealed-secrets)
9. [監視とアラート](#9-監視とアラート)
10. [人と権限](#10-人と権限)

## 1. 全体構成

```mermaid
flowchart LR
  subgraph Internet["利用者"]
    V["サイトの閲覧者"]
    OP["管理者・オペレータ"]
  end
  NGINX["RIKEN側の nginx<br>公開ドメイン<br>{site}.brc.riken.jp / wpdev1.brc.riken.jp"]

  subgraph GH["GitHub"]
    REPO["ibid-fleet-config<br>(main = 正)"]
    ACT["GitHub Actions<br>validate / promote / build / auto-update"]
    GHCR["GHCR<br>チャート・アプリのイメージ"]
  end

  subgraph LAN["IBID のネットワーク"]
    RUNDECK["Rundeck<br>(ジョブの実行)"]
    subgraph RANCHERHOST["rancher ホスト (192.168.1.149)"]
      RANCHER["Rancher + Fleet<br>rancher.brc.riken.jp"]
      CLONE["各人のクローン<br>~/ibid-fleet-config"]
    end
    subgraph HV["Harvester (hrvest1〜4)"]
      DEV["dev1 クラスタ<br>(RKE2)"]
      STG["staging1 クラスタ<br>(RKE2、確認中のものだけ)"]
      PROD["prod1 クラスタ<br>(RKE2)"]
    end
    NFS["NFS サーバー 192.168.1.1<br>wp-content・バックアップ"]
    IPA["FreeIPA<br>ログイン・DNS・証明書(ACME)"]
  end

  V --> NGINX --> PROD
  NGINX -.-> DEV
  OP --> RUNDECK -->|SSH| CLONE
  CLONE -->|PR・ワークフロー起動| REPO
  REPO --> ACT --> GHCR
  REPO -->|監視| RANCHER
  RANCHER -->|適用| DEV
  RANCHER -->|適用| STG
  RANCHER -->|適用| PROD
  DEV --- NFS
  STG --- NFS
  PROD --- NFS
  GHCR -->|pull| DEV
  GHCR -->|pull| STG
  GHCR -->|pull| PROD
  IPA -.-> RANCHER
  IPA -.-> RUNDECK
```

- 開発(dev1)・確認(staging1)・本番(prod1)の3つのKubernetesクラスタが、Harvester(4台の物理ホスト)のVMの上で動く
- Rancherが3つのクラスタを管理し、その中のFleetがGitHubのリポジトリを見て、クラスタに設定を適用する
- 公開ドメインへのアクセスは、RIKEN側のnginxから各クラスタの入口(Traefik)に届く
- 人の作業は、Rundeckのジョブ(またはrancherホストでのスクリプト)からPRを作る形で行う。クラスタを直接変更しない
- ログインはFreeIPAのアカウント(Rancher・Rundeck・サーバー)

詳しく: [manual-multi-env.md](manual-multi-env.md)、[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)

## 2. 3つの環境とバンドル

```mermaid
flowchart TB
  subgraph Git["リポジトリ envs/"]
    D["envs/dev/sites/abc/fleet.yaml"]
    S["envs/staging/sites/abc/fleet.yaml<br>(確認中だけ)"]
    P["envs/production/sites/abc/fleet.yaml"]
  end
  D -. "昇格 = 丸ごとコピー" .-> S
  S -. "昇格 = 丸ごとコピー" .-> P
  D -->|"Fleet が適用(env=dev)"| DEV["dev1<br>abc.dev.ibid.lan<br>レプリカ1"]
  S -->|"Fleet が適用(env=staging)"| STG["staging1<br>abc.staging.ibid.lan<br>レプリカ1・本番データのコピー"]
  P -->|"Fleet が適用(env=production)"| PROD["prod1<br>abc.production.ibid.lan<br>レプリカ2"]
```

| | dev1(`env=dev`) | staging1(`env=staging`) | prod1(`env=production`) |
|---|---|---|---|
| 役割 | 更新の互換性テスト | 本番へ出す前の、本番データでの確認 | staging で確かめた変更の反映だけ |
| WordPressサイト | 34(17サイト × 日本語版・英語版) | 確認中のものだけ(同時に4つまで) | 34(同じ) |
| 自作アプリ | 7 | 確認中のものだけ | 6 |
| 入口(Traefik)のIP | `192.168.1.33` | `192.168.1.50` | `192.168.1.99` |
| ホスト名 | `*.dev.ibid.lan` | `*.staging.ibid.lan` | `*.production.ibid.lan` |

- サイト・アプリの設定ファイル(バンドル)は、**dev と本番で同じ内容**にする。環境で変わる値
  (ホスト名、レプリカ数、公開ドメイン)は、ファイルの中でクラスタの `env` ラベルを見て選ぶ
- だから昇格は「dev → staging → 本番 とディレクトリを丸ごとコピーする」だけで済み、PR の差分は昇格させたい変更
  (チャートの版・プラグインの版・イメージのタグ)だけになる
- 本番へは必ず staging を通す。staging には確認中のサイト・アプリだけを置き、本番データを入れて確かめ、
  本番へ昇格したら消す(staging は2026-10-08に一度廃止し、2026-10-25に staging1 で再導入)

詳しく: [operations-flow.md](operations-flow.md)「環境差分の書き方」

## 3. GitOps: Gitが正、Fleetが適用する

```mermaid
flowchart LR
  MAIN["GitHub main ブランチ"] --> GRD["GitRepo ibid-dev<br>envs/dev だけを見る"]
  MAIN --> GRS["GitRepo ibid-staging<br>envs/staging だけを見る"]
  MAIN --> GRP["GitRepo ibid-production<br>envs/production だけを見る"]
  GRD --> BD["バンドル<br>infra / sites / apps / secrets"] --> DEV["dev1"]
  GRS --> BS["バンドル<br>infra / sites / apps / secrets"] --> STG["staging1"]
  GRP --> BP["バンドル<br>infra / sites / apps / secrets"] --> PROD["prod1"]
```

- `main` にマージされた内容だけがクラスタに届く。Fleet は数十秒ごとに `main` を見て、差があれば適用する
- 1つのディレクトリ(`envs/<env>/sites/<site>` など)が1つの「バンドル」になる
- サイトとアプリのバンドルは `keepResources: true`。Git からファイルを消しても、クラスタ上のデータ(PVC)は消えない
  (サイトの削除は手作業)
- クラスタで手で変えた設定は、Fleet が Git の内容に戻す。直したいときは Git を直す

詳しく: [envs/README.md](../envs/README.md)、[fleet-bootstrap/README.md](../fleet-bootstrap/README.md)

## 4. 変更の流れ: dev → staging → 本番

```mermaid
sequenceDiagram
  autonumber
  actor W as 作業者(Rundeck / スクリプト)
  participant GH as GitHub
  participant F as Fleet
  participant D as dev1
  participant S as staging1
  actor A as 承認者(管理者)
  participant P as prod1

  W->>GH: dev への変更の PR
  GH->>GH: validate(CI)が通れば自動マージ
  GH-->>F: main が更新
  F->>D: dev に適用
  W->>D: dev で確認
  W->>GH: staging へ置く PR(自動マージ)→ 本番データを入れる
  F->>S: staging に適用
  W->>GH: promote ワークフローで dev → staging の PR(自動マージ)
  F->>S: 昇格予定の変更を適用
  W->>S: staging で本番データに対して確認
  W->>GH: promote ワークフローで staging → 本番の PR を作る(作成者 ibid-ops-bot)
  A->>P: マージ直前に本番のバックアップ
  A->>GH: Approve → マージ
  GH-->>F: main が更新
  F->>P: 本番に適用
  W->>P: 本番の確認(Rundeck のジョブが自動で行う)
  W->>GH: staging から消す PR(自動マージ)
```

- **dev・staging への変更は自動でマージされる**(CI が通れば)。WordPress 本体・プラグインの新しい版は、毎週月曜 9:00 に
  `auto-update` ワークフローが dev へ入れる
- **本番への変更は、必ず人(Code Owner)が承認してマージする**。スクリプトやジョブは本番の PR をマージしない
- Git で本番に出るのは**構成だけ**(チャートの版、設定値、イメージのタグ)。記事などのコンテンツは本番から dev への一方向

詳しく: [operations-flow.md](operations-flow.md)、[runbook/wordpress-update.md](runbook/wordpress-update.md)、[runbook/app-update.md](runbook/app-update.md)

## 5. WordPressサイトの中身

```mermaid
flowchart LR
  NG["nginx<br>{site}.brc.riken.jp/ja・/en"] --> TR["Traefik<br>{site}.production.ibid.lan"]
  TR -->|/ja| WJ["WordPress Pod ×2<br>wordpress-{site}"]
  TR -->|/en| WE["WordPress Pod ×2<br>wordpress-{site}-en"]
  WJ --> DBJ["MariaDB<br>(Harvester のボリューム)"]
  WJ --> WCJ["wp-content<br>(NFS)"]
  WE --> DBE["MariaDB"]
  WE --> WCE["wp-content"]
  CERT["cert-manager<br>FreeIPA ACME"] -.証明書.-> TR
```

- 1つのドメインの `/ja` と `/en` は、別々の WordPress(`<site>` と `<site>-en`)。それぞれに専用の MariaDB と wp-content がある
- 全サイトの共通設定は、ラッパーチャート `charts/ibid-wordpress`(Bitnami の WordPress チャートを内包)にまとめてある。
  サイトごとの `fleet.yaml` には、チャートの版・プラグイン一覧・サイト固有の値だけを書く
- WordPress 本体・MariaDB のイメージはダイジェストで固定。プラグインは `fleet.yaml` の一覧どおりに、
  プラグイン同期の Job が入れる(一覧から消しても自動では削除しない)
- 本番は Pod が2つで、別々のノードに置く

詳しく: [manual-wordpress.md](manual-wordpress.md)、[manual-wordpress-restore.md](manual-wordpress-restore.md)「6b.」

## 6. WordPressのデータとバックアップ

```mermaid
flowchart LR
  subgraph PRODS["本番サイト"]
    PDB["MariaDB"]
    PWC["wp-content"]
  end
  CJ["バックアップの CronJob<br>毎日 3:00(JST)、14日分"]
  PDB --> CJ
  PWC --> CJ
  CJ --> BK["NFS backup/production/<br>wordpress-{site}/"]
  BK --> BAC["Bacula<br>(組織のバックアップ。二次コピー)"]
  BK -->|"1-dev-refresh"| DEVS["dev の同名サイト<br>(上書き)"]
  BK -->|"2-staging"| RH["staging の同名サイト<br>(確認中だけ)"]
  BK -.->|"障害時に戻す"| PRODS
```

| データ | 置き場所 | バックアップ |
|---|---|---|
| wp-content(メディア・テーマ・プラグイン) | NFS `192.168.1.1:/data/nfs/wordpress/<env>/` | サイトの CronJob(日次) |
| DB(記事・設定・ユーザー) | MariaDB(Harvester のボリューム) | 同上(DB ダンプ) |

- 本番を変える前(本番昇格のマージの直前)にも、同じ仕組みで「今すぐ」1つ取る
- Git の revert ではDBは戻らない(プラグイン更新などでDBの形が変わるため)。戻すときはこのバックアップから
- 本番のコンテンツを持ってくるのは、`1-dev-refresh`(dev の同名サイトを上書き)と、
  `2-staging`(staging に置いたサイト。本番へ昇格したら消す)の2通り

詳しく: [manual-wordpress-restore.md](manual-wordpress-restore.md)「日次バックアップ」、[operations-flow.md](operations-flow.md)「stagingでの確認」

## 7. 自作アプリのイメージ

```mermaid
flowchart LR
  UP["アプリのリポジトリ<br>(別リポジトリ)"] -->|"最新のコミット"| SET["images/{app}/SRC_REF・TAG<br>を更新する PR"]
  SET --> BUILD["build-{app}-image<br>(GitHub Actions)"]
  BUILD --> GHCR["GHCR<br>ghcr.io/silver198545/{app}:{tag}"]
  GHCR --> DEVM["envs/dev/apps/{app}<br>のタグを更新する PR"]
  DEVM --> DEV["dev1"]
  DEVM -->|"promote(自動マージ)"| STGM["envs/staging/apps/{app}"]
  STGM --> STG["staging1(常駐)"]
  STGM -->|"promote(承認が必要)"| PRODM["envs/production/apps/{app}"]
  PRODM --> PROD["prod1"]
```

- アプリのソースは別リポジトリにあり、このリポジトリは「どのコミットをどのタグでビルドするか」だけを持つ
- Rundeck の `<app>/1-dev-update` が、最新のコミットの取り込み → ビルド → dev への反映 → 確認まで行う。
  `<app>/2-staging-update` が staging へ反映して確認し(自動マージ)、`<app>/3-production-update` が本番の PR を作り、
  承認・マージ後に確認する。自作アプリは staging に常駐させる(WordPress と違い軽く、Secret の封印に人手が要るため)
- staging・本番だけ違う値(ホスト名・レプリカ数など)は、dev のディレクトリ内の `overlays/<env>/` に書く

詳しく: [manual-apps.md](manual-apps.md)、[runbook/rundeck-app-operator.md](runbook/rundeck-app-operator.md)

## 8. 秘密情報(Sealed Secrets)

```mermaid
flowchart LR
  PW["パスワード・トークン<br>(作業者の手元だけ)"] --> KS["kubeseal<br>クラスタの公開鍵で暗号化"]
  KS --> SS["SealedSecret<br>(暗号文。Git に置ける)"]
  SS --> GIT["envs/{env}/secrets/"]
  GIT -->|Fleet| CTRL["Sealed Secrets コントローラ<br>(そのクラスタの秘密鍵)"]
  CTRL --> SEC["Secret<br>(クラスタの中だけ)"]
```

- パスワードを平文で Git に置かない。Git にあるのは暗号文だけで、そのクラスタのコントローラしか復号できない
- 鍵はクラスタごとに別なので、**dev の暗号文を本番にコピーしても使えない**。パスワードもサイトごと・環境ごとに別に作る
- クラスタを作り直すときは、鍵を戻すか作り直して再封印する(漏れると本番の全サイトが起動しない。2026-10-08に一度起きた)

詳しく: [manual-multi-env.md](manual-multi-env.md)「封印鍵」、[manual-wordpress.md](manual-wordpress.md)

## 9. 監視とアラート

```mermaid
flowchart LR
  BB["blackbox-exporter<br>各サイトに HTTP で死活確認"] --> PROM["Prometheus"]
  K8S["クラスタ・Longhorn・<br>バックアップの状態"] --> PROM
  PROM --> AM["Alertmanager"]
  AM --> SLACK["Slack"]
  PROM --> GRAF["Grafana<br>(Rancher の画面から)"]
```

- 各環境に rancher-monitoring(Prometheus・Alertmanager・Grafana)を入れてある
- サイトが応答しない、バックアップが古い、ディスクが足りない、などを Slack に通知する
- アラートの設定も Git で管理する(Rancher の画面で変えても戻る)

詳しく: [manual-monitoring.md](manual-monitoring.md)

## 10. 人と権限

```mermaid
flowchart TB
  subgraph People["FreeIPA のグループ"]
    ADM["管理者"]
    APPOP["publicdb_developer<br>(自作アプリのオペレータ)"]
    WPOP["wpadmins<br>(WordPress のオペレータ)"]
  end
  subgraph RD["Rundeck のプロジェクト"]
    RA["Rancher-AppControll"]
    RW["WordPressControl"]
  end
  subgraph RC["Rancher のプロジェクト(dev1 は操作可 / prod1 は見るだけ)"]
    PA["APPs<br>(アプリの namespace)"]
    PW["Wordpress<br>(サイトの namespace)"]
  end
  APPOP --> RA --> PA
  WPOP --> RW --> PW
  ADM --> RA
  ADM --> RW
  APPOP -->|"本番 PR を作る"| APR["管理者の承認"]
  WPOP -->|"本番 PR を作る"| APR
```

| | 管理者 | オペレータ |
|---|---|---|
| Rundeck | 両方のプロジェクト | 担当のプロジェクトのジョブの実行だけ |
| dev1 | すべて | 担当のプロジェクトの namespace を操作できる |
| prod1 | すべて | 担当のプロジェクトを見るだけ |
| GitHub | 本番 PR の承認(Code Owner) | PR を作れる(dev は自動マージ、本番は承認待ち) |

- ジョブは**実行した人自身のアカウント**で動く(サーバーのユーザー、GitHub、Rancher)。誰が何をしたかが、
  GitHub とクラスタの両方に本人として残る
- 本番の PR は、作成者がオペレータか `ibid-ops-bot`(promote ワークフロー)なので、Code Owner の承認がないとマージできない
- 本番のバックアップを今すぐ取る、本番で操作する、といった作業は管理者が行う

詳しく: [manual-rundeck.md](manual-rundeck.md)「実行アカウント」、オペレータ向けの
[runbook/rundeck-app-operator.md](runbook/rundeck-app-operator.md)・[runbook/rundeck-wordpress-operator.md](runbook/rundeck-wordpress-operator.md)
