# マルチ環境(dev → production)セットアップ・移行手順

数十のWordPressサイトを dev → production の2つのRKE2クラスタで運用するための
セットアップ手順と、既存の単一クラスタ(dev1)からの移行手順。

当初はdev → staging → productionの3環境で構築したが、HWリソースの制約から
**2026-10-08にstagingを廃止**した(後片付けは下記「9. staging環境の廃止」)。
本文中のstagingへの言及のうち、過去の作業記録・実例はそのまま残している。

作業端末にkubectl等のCLIツールがまだ無い場合は先に
[manual-tooling-setup.md](manual-tooling-setup.md)を参照。

## 全体像

| 役割 | 使うもの |
|---|---|
| クラスタへの適用 | Rancher Fleet(環境別GitRepo × 2。[../fleet-bootstrap/](../fleet-bootstrap/)) |
| 環境の分離 | 単一mainブランチ + 環境別ディレクトリ([../envs/](../envs/))+ クラスタラベル `env=dev\|production`(サイト・アプリのバンドル内の環境差分の選択にも使う) |
| 昇格の制御 | GitHubのPR承認(mainブランチ保護 + [CODEOWNERS](../.github/CODEOWNERS))。昇格PRは [promote.yaml](../.github/workflows/promote.yaml) が生成 |
| 共通設定の配布 | ラッパーチャート [../charts/ibid-wordpress/](../charts/ibid-wordpress/)(GHCRへ公開、versionを環境ごとに昇格) |
| イメージの固定 | ラッパーチャートの [values.yaml](../charts/ibid-wordpress/values.yaml) でBitnami公式イメージをdigest固定 |

Gitで昇格するのは**構成のみ**(チャートバージョン、values、イメージ)。DBデータ・
wp-contentの実データは昇格せず、必要な場合は [manual-wordpress-restore.md](manual-wordpress-restore.md)
の手順で個別に移送する。Secretのパスワードは環境ごと・サイトごとに別々に生成する。

## 1. GitHub側の初期設定(1回だけ)

1. **mainのブランチ保護**(Settings → Branches → Add rule, パターン `main`):
   - Require a pull request before merging(承認1件以上)
   - Require review from Code Owners
   - Require status checks to pass: `validate`
   - `enforce_admins`(Do not allow bypassing the above settings)は**無効のまま**にする。
     現状collaboratorが `@silver198545` 一人のため、有効化すると
     GitHubが自分自身のPRへのApproveを許可しない仕様により、`main`へ何もマージできなくなる
     (2026-07-08に実際に検証して確認済み)。将来2人目以降のcollaboratorを迎えたら、
     その人のPRにはCODEOWNERS承認が正しく機能する。管理者アカウントは直接push/自己マージで
     バイパスできてしまう点は許容する(ソロ運用の実質的な安全網は`validate`のCIチェック)。
   - **注意**: GitHub Freeの個人アカウントではprivateリポジトリでブランチ保護/rulesetsが
     使えない(GitHub Pro等へのアップグレードが必須)。本リポジトリは2026-07-08に
     Private化した際にこのルールが無効化されたことに気づかず運用しており、
     PROMOTE_TOKEN確認時に発覚してpublicへ差し戻した経緯がある
     ([roadmap.md](roadmap.md)「リポジトリのprivate化」参照)。private化を検討する際は
     必ず先にPro化するか、ブランチ保護を諦めるかを判断すること。
2. [.github/CODEOWNERS](../.github/CODEOWNERS) の本番承認者を実際の体制に合わせて更新する。
3. **ActionsにPR作成を許可する**(Settings → Actions → General → Workflow permissions):
   「Allow GitHub Actions to create and approve pull requests」にチェック。
   無効のままだと promote.yaml がブランチをpushした後のPR作成で
   「GitHub Actions is not permitted to create or approve pull requests」で失敗する。
4. `PROMOTE_TOKEN` をリポジトリSecretsに登録する(fine-grained PAT、対象リポジトリのみ、
   Contents: Read and write / Pull requests: Read and write)。【済(2026-07-08)】
   promote.yaml がデフォルトの `github.token` でPRを作ると `validate` が自動起動しない
   (GitHub Actionsの再帰防止仕様)ため、validateを必須チェックにするなら実質必須。
   PATに有効期限があるため、期限切れ前の再発行が必要(fine-grained PATはブラウザでの
   手動作成が必須、再発行後は `gh secret set PROMOTE_TOKEN --repo silver198545/ibid-fleet-config`
   で更新)。
5. **GHCRパッケージのpublic化**(初回のチャート公開・イメージ公開後に1回だけ):
   GitHubの Packages → `charts/ibid-wordpress` と `wordpress` → Package settings →
   Change visibility → Public。クラスタが匿名でpullできるようにするため。

## 2. クラスタの新規作成(再作成・DR時も同じ)

ゲストクラスタを作るときの唯一のチェックリスト。個々の設定の理由と詳細は各リンク先にある。
2026-10-08〜09にprod1/dev1をこの設定で作り直して安定している(etcd遅延・時刻ずれの再発なし)。

### 作る前に

- **Harvesterホストのメモリの空き**を確認する(Harvester UIのHosts)。制約はCPUではなくメモリで、
  オーバーコミットが効いているため「Reserved」の空きは当てにならない。「Used」を見る。
- 作業端末に必要なツールがあること([manual-tooling-setup.md](manual-tooling-setup.md))。
- Harvester側の準備が済んでいること(1回だけ。済み): `defaultdisk`への`ssd`タグ、
  StorageClass `harvester-longhorn-ssd`、SSD用VMイメージ`ubuntu-cloudimg-26.04-lts-ssd`
  (`harvester-public/image-fpm2h`)。手順は[manual-harvester-etcd-ssd.md](manual-harvester-etcd-ssd.md)の「恒久対策」1〜2。

### Rancher UIでのクラスタ作成

既存クラスタ(prod1)のプール設定を見ながら同じ値を入れるのが確実。

| 項目 | pool1(etcd + control-plane、3台) | pool2(worker) |
|---|---|---|
| VMイメージ | `ubuntu-cloudimg-26.04-lts-ssd`(SSD上に限定) | 通常のイメージ |
| User Data | `qemu-guest-agent`・`nfs-common`・chrony(`ntp.nict.jp`)入りのcloud-config。全文は[manual-node-ntp.md](manual-node-ntp.md)の「恒久対策」 | 同じもの |
| VM Scheduling | anti-affinity(Preferred、`harvesterhci.io/machineSetName` In `harvester-public-<クラスタ名>-pool1`、Topology Key `kubernetes.io/hostname`、Weight 100)。[manual-harvester-etcd-ssd.md](manual-harvester-etcd-ssd.md)の「3. Rancherのプール設定」 | なし |
| Network | 1枚目: `default/public`(v140)、2枚目: `default/management`(FreeIPA向け、v3333)。2枚目が無いとcert-manager(DNS-01)がFreeIPAに届かない。Network Data(`networkData`)も既存クラスタと同じ値を明示する | 同じもの |
| ディスク | 現在はdev1 30GB / prod1 40GB | 60GB |

- `nfs-common`は`nfs-external`(wp-content)とLonghorn RWXのマウントに必要。
- namespaceは`harvester-public`。

### 作成直後(Rancher local側)

1. **chartValuesを入れる**。Rancher UIでの編集で`{}`に消されることがあるので、作成直後と、以後UIで
   クラスタを編集するたびに確認する([manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)):
   - `harvester-cloud-provider`の`global.cattle.clusterName`(無いとLBが`kubernetes-*`名で作られ、IPが付かない)
   - `rke2-traefik`の`service.spec.type: LoadBalancer`(キーは`service.type`ではない)
2. Harvester**管理クラスタ**に、そのクラスタ用の`IPPool`を作る。レンジは環境ごとに分け、
   Harvester UIのVIPと重ねない(現在: pool1=dev1 `.30-.49`、pool3=prod1 `.90-.100`)。
3. ラベル `env=<環境名>` を付ける(Cluster Management → 対象クラスタ → Labels & Annotations)。
4. kubeconfigを`~/.kube/config`にマージする。同名で作り直した場合は、先に古いcontext/clusterを消す
   ([manual-dr-troubleshooting.md](manual-dr-troubleshooting.md)の1.)。
5. 対応するGitRepoを適用する(初回のみ。再作成なら既にある):
   ```bash
   kubectl --context rancher apply -f fleet-bootstrap/gitrepo-<env>.yaml
   ```
   Fleetが`envs/<env>/infra/`(Longhorn、sealed-secrets、cert-manager、監視、csi-driver-nfs等)を入れる。

### Fleetがinfraを入れた後

1. **sealed-secretsの鍵**: 再作成なら、バックアップした鍵をリストアする(6.)。新しい鍵のままにする場合は、
   その環境の全SealedSecretを封印し直す。どちらの場合も、新しい鍵をすぐバックアップする。
   2026-08-31のprod1再作成ではこれが漏れ、本番のSecretが全件復号できなかった(PR#180で再封印)。
2. **TraefikのLB IP**を、環境のワイルドカードレコード(`*.<env>.ibid.lan`)に設定する。作り直しで
   IPが変わったら`ipa dnsrecord-mod`で1件書き換える。消し忘れの`_acme-challenge.*`のTXTが残っていれば消す
   ([manual-cert-manager-freeipa-acme.md](manual-cert-manager-freeipa-acme.md)「サイトホスト名のDNS」)。
3. **作成後のチェック**([manual-harvester-etcd-ssd.md](manual-harvester-etcd-ssd.md)の「4. 作成後のチェック」):
   control-planeのレプリカが全て`defaultdisk`上 / 全ノードで`chronyc -n sources`に`^*` /
   etcdに`slow fdatasync`・`clock drift`が出ない / control-plane VMが別々のホスト /
   LoadBalancerにIPが付いている / SealedSecretが全件`SYNCED=True`。

新しい**環境**を増やす場合(例: stagingの再導入)は、上記に加えてGit側の作業が必要になる
(`envs/<env>/`、`fleet-bootstrap/gitrepo-<env>.yaml`、promoteワークフロー、サイトの`targetCustomizations`等)。
2026-10-08の廃止時に削除した内容は「9. staging環境の廃止」と、PR#177/#178を参照。

## 3. 既存クラスタ(dev1)の移行手順【完了済み・記録】

2026-07に実施済み。単一クラスタ時代のGitRepo `base-infra`から、環境別GitRepo
(`ibid-dev`)と`envs/dev/`へ移した記録。**再実施することはない**が、devのinfraの
`helm.releaseName`が`base-infra-*`のままである理由(3-4の2.)を説明するため残している。
この名前を変えると、Fleetが別名のリリースを作って既存のLonghorn等と衝突する。

**順序厳守。** 旧GitRepo(`base-infra`)のバンドルが消えるとFleetがLonghornごと
アンインストールしようとするのを、`keepResources: true` とリリース名の引き継ぎで防ぐ。

### 3-1. keepResources の同期を確認

`catalog-repos/`・`longhorn-crd/`・`longhorn/` の各fleet.yamlに `keepResources: true` を
追加したコミットがmainに入り、Rancher UI(Continuous Delivery → Bundles)で
3バンドルが再同期済み(Ready)であることを確認する。**これが済むまで次に進まない。**

### 3-2. devクラスタのラベル付けとGitRepo適用

1. dev1クラスタにラベル `env=dev` を付与する(手順2-3と同様)。
2. `kubectl --context <rancher-local> apply -f fleet-bootstrap/gitrepo-dev.yaml`
3. この時点で `envs/dev/` にはサイトが無いため何も適用されない(GitRepoがActiveになるだけ)。

### 3-3. 旧GitRepo(base-infra)の設定確認

Rancher UI(Continuous Delivery → Git Repos → base-infra)で `paths` を確認する。
リポジトリ全体をスキャンする設定(paths未指定)の場合、以後 `envs/` に追加される
バンドルを二重に適用してしまうため、pathsを `catalog-repos` / `longhorn-crd` /
`longhorn` の3つに限定しておく。

### 3-4. infraバンドルの移設

1. 移設PRを作成する:
   ```bash
   git checkout -b move-infra-to-envs
   mkdir -p envs/dev/infra
   git mv catalog-repos envs/dev/infra/catalog-repos
   git mv longhorn-crd envs/dev/infra/longhorn-crd
   git mv longhorn envs/dev/infra/longhorn
   ```
2. 移設した各fleet.yamlの `helm:` に **既存のリリース名を明示**する(これが無いと
   Fleetが別名の新リリースを作ろうとして既存リソースと衝突する)。既存リリース名は
   `helm ls -A | grep base-infra` で確認できる(GitRepo名 `base-infra` 由来):
   ```yaml
   # envs/dev/infra/longhorn/fleet.yaml に追記
   helm:
     releaseName: base-infra-longhorn   # 旧GitRepo時代のリリース名を引き継ぐ
   ```
   同様に `longhorn-crd` → `base-infra-longhorn-crd`、`catalog-repos` →
   `base-infra-catalog-repos`(rawマニフェストのバンドルもFleetはHelmリリースとして
   管理しているため必要)。
3. `envs/production/infra/` にも同内容をコピーする。ただし
   こちらは新規クラスタなので `releaseName` は素直な名前(`longhorn` 等)にする。
4. **PRをマージする前に**、Rancher UIで旧GitRepo `base-infra` を削除する。
   keepResourcesが同期済みなので、バンドルは消えてもLonghorn等の実リソースは残る。
   (マージが先だと新旧GitRepoが同じリリースを取り合う)
5. PRをマージし、`ibid-dev` GitRepoが `envs/dev/infra/` を適用するのを待つ。
6. 検証:
   ```bash
   helm ls -n longhorn-system    # base-infra-longhorn のREVISIONが+1、STATUSがdeployed
   kubectl -n longhorn-system get pods   # 再作成されていないこと(AGEが継続)
   ```

### 3-5. 既存WordPressサイト(wordpress-web)のFleet引き取り

サイトごとに実施する。まず1サイトで検証してから残りに展開すること。

1. `wordpress-<site>-mariadb-upgrade-values` Secretをラッパーチャート用の
   ネスト形式(`wordpress:` 配下)に作り直す(パスワード自体は変わらない):
   ```bash
   SITE=web
   kubectl -n "wordpress-$SITE" get secret "wordpress-$SITE-mariadb-upgrade-values" \
     -o jsonpath='{.data.values\.yaml}' | base64 -d > /tmp/old-values.yaml
   head -1 /tmp/old-values.yaml   # "mariadb:" で始まる旧形式であることを確認
   { echo "wordpress:"; sed 's/^/  /' /tmp/old-values.yaml; } > /tmp/new-values.yaml
   kubectl -n "wordpress-$SITE" create secret generic "wordpress-$SITE-mariadb-upgrade-values" \
     --from-file=values.yaml=/tmp/new-values.yaml --dry-run=client -o yaml | kubectl apply -f -
   rm /tmp/old-values.yaml /tmp/new-values.yaml
   ```
2. サイトのFleetバンドルを生成し、リリース名が既存と一致することを確認する:
   ```bash
   ./scripts/new-wordpress-site.sh dev "$SITE"
   helm ls -n "wordpress-$SITE"   # NAMEが wordpress-<site> であること
   ```
3. PRを作成してマージ → `ibid-dev` が適用する。
4. 検証:
   ```bash
   helm history "wordpress-$SITE" -n "wordpress-$SITE"  # リビジョンが+1
   kubectl -n "wordpress-$SITE" get pods -w
   ```
   イメージ参照がdigest固定表記に変わるため**ローリング再起動が1回発生する**
   (中身は稼働中と同一digestのイメージ。MariaDB Podの再起動中、数十秒程度
   DB接続が途切れる)。安全のため事前にLonghornスナップショットを取っておくとよい。
5. 以後 `scripts/deploy-wordpress.sh` は緊急用(break-glass)。通常の変更は
   fleet.yaml/チャートの編集とPRマージで行う。

## 4. 日常運用

- **サイト追加**: [manual-wordpress.md](manual-wordpress.md)。原則devに追加し、
  昇格で production へ展開する。
- **設定変更・バージョンアップ**: devの `envs/dev/sites/<site>/fleet.yaml` または
  `charts/ibid-wordpress/` を変更 → PR → マージ → devで動作確認 →
  (DBマイグレーションを伴う変更ならdev1で本番データリハーサル。
  [operations-flow.md](operations-flow.md)) →
  Actionsの `promote`(dev→production)を手動起動 → CODEOWNERS承認を経てマージ。
- **チャート更新**: `charts/ibid-wordpress/` を変更し `Chart.yaml` のversionを上げる →
  マージで `release-chart.yaml` がGHCRへ公開 → devサイトの `helm.version` を上げるPR →
  以後は通常の昇格フロー。
- **イメージ更新**(WordPressコア・MariaDB): [values.yaml](../charts/ibid-wordpress/values.yaml) の
  `image.digest`(Bitnami公式イメージ。`docker buildx imagetools inspect docker.io/bitnami/wordpress:latest`
  等で最新digestを確認)を差し替える → 以後は上記「チャート更新」と同じ。

### 定期メンテナンス日(月次、毎月1日を目安)

WordPressコア/プラグインのイメージはdigest固定(= セキュリティパッチも意図的に
止まる設計、[roadmap.md](roadmap.md) #6)なので、以下を**毎月1日を目安に**まとめて実施する
(前後にずれても良いが月を跨がないこと)。初回は2026-08-01。

1. **WordPressコアの確認**: Bitnami公式イメージの最新digestを確認し、必要なら
   チャートのdigestを更新(上記「イメージ更新」手順)。
2. **プラグインの確認**: 各サイトの `fleet.yaml` の `plugins:` 一覧を見直し、
   セキュリティリリースが出ているものを更新([manual-wordpress.md](manual-wordpress.md)参照)。
   `wp-file-manager`(過去に重大脆弱性の履歴あり)は特に、その時点で必要かどうかを
   毎回再検討する。
3. **Sealed Secrets鍵の再バックアップ**: ローテーションの有無に関わらず、
   6.のコマンドを全環境分実行しておく(冪等なので無駄にはならない)。
   コントローラは30日ごとに自動で鍵をローテーションするため、月次実施であれば
   取りこぼしがない。
4. 更新はdevから着手し、通常の昇格フロー(本節冒頭)でproductionへ展開する。

## 5. Longhornバックアップの運用

> **注意: WordPressサイトのデータはこのバックアップの対象外。**
> ゲストクラスタのLonghornの定期バックアップが守るのは、ゲストLonghorn上のボリューム
> (Prometheus、sparqlist等)だけ。WordPressのDBは`harvester` StorageClass
> (Harvester側のボリューム)、wp-contentは`nfs-external`(NFSサーバー`192.168.1.1`上の
> ディレクトリ)にあり、どちらもゲストLonghornを通らない。
> WordPressは、チャート0.6.0のサイトごとの日次バックアップCronJob(DBダンプ + wp-contentのtar、
> NFS `/data/nfs/backup/<env>/`、14日分)で守る
> ([manual-wordpress-restore.md](manual-wordpress-restore.md)「日次バックアップ」)。
> NFSサーバー上のデータ(バックアップを含む)の二次コピーは、組織のBaculaのバックアップで取られている
> (本リポジトリの管理外。[roadmap.md](roadmap.md)の項目5)。

- 定期ジョブとバックアップ先は `envs/<env>/infra/longhorn-jobs/` でGit管理
  (snapshot-6h: 6時間ごと保持4世代 / backup-daily: JST 2:00、保持はdev 7世代、
  production 14世代)。バックアップ先はNFS `192.168.1.1:/data/nfs/longhorn/<env>`。
- **クラスタごとに1回だけ手動patchが必要**(Longhornが自動作成する `default`
  BackupTarget CRの `spec.backupTargetURL` はlonghorn-managerがフィールド所有して
  おり、Fleetが異なる値を書こうとするとServer-Side Applyの競合で失敗する。
  同じ値を先に投入しておけば競合しない)。**Gitの変更をマージする前に実施すること**:
  ```bash
  kubectl --context <対象クラスタ> -n longhorn-system patch backuptarget default \
    --type merge -p '{"spec":{"backupTargetURL":"nfs://192.168.1.1:/data/nfs/longhorn/<env>"}}'
  ```
  実施後、`kubectl -n longhorn-system get backuptarget default` で
  `status.available: true` になることを確認する。
  マージが先行してしまった場合、Fleetのバンドルは競合エラーで再試行し続けるが、
  patchを投入すれば次回の再試行から自然回復する(エラー期間が気になる場合は
  対象GitRepoを一時 `paused: true` にしてから patch → 解除でもよい)。
- **バックアップ先URLを変更する場合も同順序**: 先に上記patchで新URLを投入してから
  Gitを変更する(逆順だとpatchを入れるまでFleetのバンドルが競合エラーで失敗し続ける)。
- 新規クラスタをゼロから構築する場合は `longhorn/fleet.yaml` の
  `defaultSettings.backupTarget` がインストール時に効くため、patchは不要。
- リストア: Longhorn UI(Backup画面)から対象バックアップを選んで
  新しいPVCとして復元できる。DR(クラスタ全損)時は新クラスタから同じ
  バックアップ先を読み込める。

## 6. Sealed Secretsの鍵管理

コントローラは `envs/<env>/infra/sealed-secrets/` でGit管理(kube-systemに導入)。
封印(暗号化)はローカルの `kubeseal` CLI(コントローラと同じv0.38.4)で行う。

**封印鍵(kube-systemのSecret)が失われると、Gitにコミット済みのその環境の
全SealedSecretが復号不能になる。** クラスタ再構築時はGitのSealedSecretを
復元するために鍵の restore が必須のため、以下のバックアップ運用を守ること。

- **鍵のバックアップ(クラスタごと・導入直後に1回+鍵ローテーション後)**:
  ```bash
  kubectl --context <対象クラスタ> -n kube-system get secret \
    -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
    > sealed-secrets-key-<env>-$(date +%Y%m%d).yaml
  ```
  出力ファイルは**秘密鍵そのもの**なので、Gitには絶対にコミットせず、
  オフラインの安全な場所(パスワードマネージャや暗号化ストレージ)に保管する。
- コントローラはデフォルトで**30日ごとに新しい鍵を追加**する(古い鍵も復号用に
  残る)。ローテーション後は上記コマンドで再バックアップする(ラベル指定なので
  全世代がまとめて出力される)。**個別にローテーション日を追跡する代わりに、
  4.の「定期メンテナンス日(毎月1日を目安)」に全環境分まとめて再バックアップする**運用とする。
- **リストア(クラスタ再構築時)**: コントローラ導入後、バックアップした鍵を
  `kubectl apply -f` で投入し、コントローラPodを再起動
  (`kubectl -n kube-system delete pod -l app.kubernetes.io/name=sealed-secrets`)
  すると、Git上の既存SealedSecretが復号されるようになる。

## 7. break-glass(緊急時の手動操作)

Fleet/GitHub/GHCRのいずれかが使えない、または即時の手動修復が必要な場合:

1. 対象環境のGitRepoを一時停止し、Fleetによる上書きを止める:
   ```bash
   kubectl --context <rancher-local> -n fleet-default patch gitrepo ibid-production \
     --type merge -p '{"spec":{"paused":true}}'
   ```
2. 手動で修復する。WordPressのデプロイ自体をやり直す場合は
   `scripts/deploy-wordpress.sh <env> <site>`(Fleetと同じfleet.yamlを読む。
   レジストリ障害時は `CHART_LOCAL=1` でリポジトリ内のチャートを使用)。
3. 復旧後、**手動で行った変更を必ずGitへ反映してから** pausedを解除する:
   ```bash
   kubectl --context <rancher-local> -n fleet-default patch gitrepo ibid-production \
     --type merge -p '{"spec":{"paused":false}}'
   ```

## 8. DR: クラスタ全損からの復元手順(2026-07-05にstagingで実証済み、2026-07-07にdev1でも実施)

**前提の3点セット**: ①Gitリポジトリ ②封印鍵バックアップ(6.参照) ③LonghornのNFSバックアップ。
この3つが揃っていれば、クラスタを丸ごと失っても以下の手順で完全復元できる。

**手順通りに進まない場合**: kubeconfigの再取得やLonghornバックアップからの復元で
実際に詰まりやすいポイントとその対処法を
[manual-dr-troubleshooting.md](manual-dr-troubleshooting.md)にまとめている。
特に手順3(kubeconfig取得)と手順7(fromBackupでのVolume復元)で問題が起きたら先に確認する。

### 平時の備え(これが無いと復元できない)

- 鍵バックアップを取得済みであること(6.参照)
- **バックアップが実際に存在することを定期確認**:
  `kubectl -n longhorn-system get backupvolumes`
  (DR演習ではRecurringJobの初回実行前でバックアップが0件だった。**クラスタ構築直後や
  サイト追加直後は、日次ジョブを待たずに手動で初回バックアップを取ること**)

### ノードプール入替(ノード追加・ディスク拡張等)の前提条件

クラスタ全損でなくても、ノードプールの設定変更はノードのローリング全入替を伴う。
2026-07-07の入替(ディスク37Gi→拡張)で実際に踏んだ罠:

**2026-07-27/28にも、この1.を踏まずにdev1(17サイト全滅)とproduction(web/dna)の
両方で同時に再現した。** 復元作業そのものの詰まりどころ(PVC自動削除のレース、
kubeletのマウントバックオフ、Fleetの所有権drift等)は
[manual-dr-troubleshooting.md](manual-dr-troubleshooting.md)の6.以降に追記した。

1. **detached状態のLonghornボリュームは入替で全損する**。attach中のボリュームは
   drainに合わせてレプリカが新ノードへ再配置されるが、**detachedのボリュームは
   再配置されず、旧ノードの削除とともにレプリカごと消える**
   (実例: 停止中だったstaging webサイトのwp-content/DBが全損し、NFS日次バックアップ
   から復元した。復元手順は下記「手順」7.と同じ)。
   入替前に `kubectl -n longhorn-system get volumes` で全ボリュームが
   `attached` であることを確認し、detachedがあればワークロードを起動するか
   手動バックアップを取ってから着手すること。
2. **attach中のボリュームでも、入替のペースがレプリカ再構築より速いと全損する**
   (実例: dev dnaのDBボリュームは、約10分間隔のノード削除に8Giの再構築が
   追いつかず、3レプリカとも旧ノードごと消失した)。
   **ノードが1台置き換わるごとに、全ボリュームが `attached/healthy`(degradedが
   解消済み)であることを確認してから次のノードに進む**のが確実。
   一括で流す場合は、入替前に全ボリュームの手動バックアップを取ること。
3. **LB Serviceが再作成されるため、cloud providerの`clusterName`恒久設定が前提**
   ([manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)の
   「クラスタ名が正しく名乗れていない」参照。未設定だとLBが`kubernetes-*`名で
   再作成されIP割当に失敗する)。
4. **復元直後のボリュームは、初回の日次バックアップが走るまでバックアップが
   1つも存在しない**(実例: dev DR検証で復元した翌日にdna DBが全損し、
   そのボリューム自体のバックアップはゼロだった。旧ボリューム名の古い
   バックアップから復元して事なきを得た)。**ボリュームを復元・新規作成したら、
   ワークロード起動後ただちに手動でSnapshot CR→Backup CRを作成すること**
   (SnapshotはボリュームがattachedでないとCRが黙って消える点に注意)。

### 手順

1. **(計画的な再構築の場合)直前バックアップを取得**: 全ボリュームに対して
   Snapshot CR→Backup CRを作成しCompletedを確認する。**ボリューム名(pvc-...)と
   PVC名・namespaceの対応を必ず控える**(復元時のfromBackup指定に必要)。
2. **クラスタ削除**(Rancher UI)。GitRepo・IPPool・NFS上のバックアップ・Git上の
   SealedSecretは残る。
3. **再構築**: 「2. クラスタの新規作成」のチェックリストどおりに作る(SSDイメージ、User Data、
   anti-affinity、2枚目のNIC、chartValues、`env`ラベル、kubeconfig)。クラスタ名を変えた場合は、
   Harvesterの該当IPPoolの`spec.selector.scope[].guestCluster`を新クラスタ名へ変更する。
   同名で再作成した場合は、`~/.kube/config`の古いcontext/clusterを先に消す
   ([manual-dr-troubleshooting.md](manual-dr-troubleshooting.md)の1.)。
4. **Fleetの自動復元を待つ**: ラベル付与だけでinfra一式(Longhorn/カタログ/
   sealed-secretsコントローラ/バックアップ設定)が自動導入される。
   新規インストールでは `defaultSettings.backupTarget` がpatch不要で有効(実証済み)。
   バックアップ先がavailableになるとNFS上の旧バックアップ一覧も自動で見える。
5. **サイトのnamespace作成は不要**: secretsバンドルの各`<site>.yaml`がNamespaceを含むため、
   Fleetが自動作成する(2026-07-11改修)。
6. **封印鍵をリストア**(6.参照)。SealedSecretがSynced=Trueになり、Secretが復元されて
   sitesバンドルのデプロイが進む(エラーバックオフで止まったままの場合は
   GitRepoの `spec.forceSyncGeneration` を+1して再同期)。
   この時点でサイトは**空のWordPress**として起動する(新しい空ボリューム)。
7. **データ復元**(サイトごと):

   > **この7.はゲストLonghorn上のボリュームを前提にした手順(2026-07時点の構成)。**
   > 現在のWordPressは、wp-contentが`nfs-external`、DBが`harvester`なので、この手順はそのまま使えない
   > (この手順が今も使えるのは、Prometheus・sparqlist等、ゲストLonghorn上のボリューム)。
   > - wp-content: NFS上の`/data/nfs/wordpress/<env>/<namespace>/<pvc>`は、クラスタを消しても残る
   >   (productionは`reclaimPolicy: Retain`)。新しいPVCは別のディレクトリになるので、中身を移す必要がある
   > - DB: `harvester`のボリュームはHarvester側にあり、ゲスト側のバックアップは無い
   >
   > 現構成での復元: 新しいクラスタでサイトが空のWordPressとして起動したら、NFS上の日次バックアップ
   > (`/data/nfs/backup/<env>/wordpress-<site>/`。namespace単位なので新クラスタからも同じ場所)から
   > `scripts/restore-wordpress.sh`で戻す([manual-wordpress-restore.md](manual-wordpress-restore.md)
   > 「日次バックアップ」)。この流れでのクラスタ全損からの復元は、まだ演習していない([roadmap.md](roadmap.md)項目5)。

   以下は旧構成(ゲストLonghorn)での手順:
   ```bash
   # スケールダウン(plugin-sync Jobが実行中ならJobごと削除してよい。Fleetが後で再適用する)
   kubectl -n wordpress-<site> scale deploy wordpress-<site> --replicas=0
   kubectl -n wordpress-<site> scale statefulset wordpress-<site>-mariadb --replicas=0
   # Podが消えたら、空のPVCを削除
   kubectl -n wordpress-<site> delete pvc wordpress-<site> data-wordpress-<site>-mariadb-0
   ```
   バックアップから復元ボリュームを作成(wp-content用は `accessMode: rwx`、
   DB用は `rwo`。sizeは元と同じバイト数)。**`volume=`にはバックアップボリュームの
   CRリソース名(末尾にランダムなハッシュが付く)ではなく、ハッシュを除いた実際の
   ボリューム名(PV名と同じ)を指定すること**(詳細は
   [manual-dr-troubleshooting.md](manual-dr-troubleshooting.md)の2.参照。
   間違えるとadmission webhookに`backupVolumes "" not found`で即座に拒否される):
   ```yaml
   apiVersion: longhorn.io/v1beta2
   kind: Volume
   metadata:
     name: restore-<site>-content   # 任意の新ボリューム名
     namespace: longhorn-system
   spec:
     size: "10737418240"
     numberOfReplicas: 3
     accessMode: rwx
     frontend: blockdev
     fromBackup: "nfs://192.168.1.1:/data/nfs/longhorn/<env>?backup=<バックアップ名>&volume=<旧ボリューム名>"
   ```
   `status.state: detached` になったら復元完了。元のPVC名でPV/PVCを作成して紐付ける
   (helmが自リソースと認識できるようアノテーションを付ける):
   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: restore-<site>-content
   spec:
     capacity: {storage: 10Gi}
     accessModes: ["ReadWriteMany"]
     persistentVolumeReclaimPolicy: Retain
     storageClassName: longhorn
     csi: {driver: driver.longhorn.io, fsType: ext4, volumeHandle: restore-<site>-content}
     claimRef: {namespace: wordpress-<site>, name: wordpress-<site>}
   ---
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: wordpress-<site>
     namespace: wordpress-<site>
     labels:
       app.kubernetes.io/instance: wordpress-<site>
       app.kubernetes.io/managed-by: Helm
       app.kubernetes.io/name: wordpress
     annotations:
       meta.helm.sh/release-name: wordpress-<site>
       meta.helm.sh/release-namespace: wordpress-<site>
   spec:
     accessModes: ["ReadWriteMany"]
     storageClassName: longhorn
     volumeName: restore-<site>-content
     resources: {requests: {storage: 10Gi}}
   ```
   (DB用PVC `data-wordpress-<site>-mariadb-0` も同様に作成する。
   accessModesは `ReadWriteOnce`)
   ```bash
   kubectl -n wordpress-<site> scale statefulset wordpress-<site>-mariadb --replicas=1
   kubectl -n wordpress-<site> scale deploy wordpress-<site> --replicas=2
   ```
8. **検証**: SealedSecret全件Synced / 復元Secretの値で実DBへログインできる /
   サイトHTTP 200 / コンテンツ(プラグイン・記事)が削除前と一致していること。
9. **後片付け**: GitRepoをforceSyncして手動削除したJob等を再適用させ、全バンドル
   Readyを確認する。手動で取った復元用バックアップは適宜整理する
   (RecurringJobの保持世代管理は自動作成分にしか効かない)。

## 9. staging環境の廃止(2026-10-08)

HWリソース(Harvesterホストのメモリ)の制約からstagingを廃止し、dev / production の
2環境にした。本番相当データでの確認は、dev1上の一時的なリハーサルサイトで代替する
([operations-flow.md](operations-flow.md)「本番データリハーサル」)。

Git側(`envs/staging/`、`fleet-bootstrap/gitrepo-staging.yaml`、promoteワークフロー・
スクリプトのstaging対応)は削除済み。staging1クラスタ自体は廃止時点で既にRancherから
削除されていた。Git管理外の後片付けは以下(実施したら[x]にする):

- [x] Rancher localのGitRepo `ibid-staging` を削除する(対象クラスタ0台で何も適用していない。2026-10-08実施):
  ```bash
  kubectl --context rancher -n fleet-default delete gitrepo ibid-staging
  ```
- [x] Harvester管理クラスタのIPPool `pool2`(staging用、`192.168.1.61-70`)を削除し、
  レンジを解放する(2026-10-09に削除済みであることを確認。残っているのはpool1(dev1)とpool3(prod1))
- [ ] FreeIPAのDNSから `*.staging.ibid.lan` のAレコードを削除する
- [ ] NFSのLonghornバックアップ先 `192.168.1.1:/data/nfs/longhorn/staging` を削除する
  (DRで戻す予定が無いことを確認してから)
- [ ] オフライン保管しているstagingのSealed Secrets鍵バックアップを破棄する
- [ ] Rundeckに取り込み済みの `app-image-update/staging` グループのジョブを削除し、
  `rundeck/jobs/update-app-image.yaml` を再取り込みする(`rd jobs load`は既存ジョブを消さない。
  rancherホストには`rd` CLIが無いため、Rundeck UIまたは`rd`のある端末で行う)
- [x] 作業端末の `~/.kube/config` から `staging1` コンテキストを削除する(2026-10-08実施。
  `kubectl config delete-context staging1` / `delete-cluster staging1`。ユーザー`rancher`は他と共用のため残す)
- [ ] Slackアラート等で `cluster=staging` を前提にした設定が残っていないか確認する

なお、Rancher localの `fleet-default` に残る `fleet-agent-staging1` バンドルはRancherが
クラスタごとに自動生成するエージェント用のもので、本リポジトリのGitRepoとは無関係。

## 補足: 将来の拡張

- ~~サイトSecretのSealedSecret移行~~ 完了済み: 全環境のサイトSecretは
  `envs/<env>/secrets/` のSealedSecretでGit管理されている
  (生成・移行は `scripts/seal-site-secrets.sh`)。
- **クラスタ定義のGitOps化(Phase 4)**: Rancher provisioning-v2 の Cluster オブジェクトを
  localクラスタ向けGitRepoで管理できるが、誤マージの影響半径が大きいため2クラスタ規模では
  急がない。
