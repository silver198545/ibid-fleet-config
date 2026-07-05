# マルチ環境(dev → staging → production)セットアップ・移行手順

数十のWordPressサイトを dev → staging → production の3つのRKE2クラスタで運用するための
セットアップ手順と、既存の単一クラスタ(dev1)からの移行手順。

## 全体像

| 役割 | 使うもの |
|---|---|
| クラスタへの適用 | Rancher Fleet(環境別GitRepo × 3。[../fleet-bootstrap/](../fleet-bootstrap/)) |
| 環境の分離 | 単一mainブランチ + 環境別ディレクトリ([../envs/](../envs/))+ クラスタラベル `env=dev\|staging\|production` |
| 昇格の制御 | GitHubのPR承認(mainブランチ保護 + [CODEOWNERS](../.github/CODEOWNERS))。昇格PRは [promote.yaml](../.github/workflows/promote.yaml) が生成 |
| 共通設定の配布 | ラッパーチャート [../charts/ibid-wordpress/](../charts/ibid-wordpress/)(GHCRへ公開、versionを環境ごとに昇格) |
| イメージの固定 | [../images/wordpress/](../images/wordpress/)(digest固定のカスタムイメージをGHCRへ公開) |

Gitで昇格するのは**構成のみ**(チャートバージョン、values、イメージ)。DBデータ・
wp-contentの実データは昇格せず、必要な場合は [manual-wordpress-restore.md](manual-wordpress-restore.md)
の手順で個別に移送する。Secretのパスワードは環境ごと・サイトごとに別々に生成する。

## 1. GitHub側の初期設定(1回だけ)

1. **mainのブランチ保護**(Settings → Branches → Add rule, パターン `main`):
   - Require a pull request before merging(承認1件以上)
   - Require review from Code Owners
   - Require status checks to pass: `validate`
2. [.github/CODEOWNERS](../.github/CODEOWNERS) の本番承認者を実際の体制に合わせて更新する。
3. **ActionsにPR作成を許可する**(Settings → Actions → General → Workflow permissions):
   「Allow GitHub Actions to create and approve pull requests」にチェック。
   無効のままだと promote.yaml がブランチをpushした後のPR作成で
   「GitHub Actions is not permitted to create or approve pull requests」で失敗する。
4. (任意)`PROMOTE_TOKEN` をリポジトリSecretsに登録する(repo権限のPAT)。
   promote.yaml がデフォルトの `github.token` でPRを作ると `validate` が自動起動しない
   (GitHub Actionsの再帰防止仕様)ため、validateを必須チェックにするなら実質必須。
5. **GHCRパッケージのpublic化**(初回のチャート公開・イメージ公開後に1回だけ):
   GitHubの Packages → `charts/ibid-wordpress` と `wordpress` → Package settings →
   Change visibility → Public。クラスタが匿名でpullできるようにするため。

## 2. クラスタの追加(staging / production それぞれ)

1. Rancher UIからHarvester上にRKE2クラスタを作成する。マシンプールのcloud-initに
   `nfs-common` を含めること(Longhorn RWXの前提。[manual-wordpress.md](manual-wordpress.md)参照)。
2. Harvester**管理クラスタ**に、そのクラスタ用の `IPPool` を作成する
   ([manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)参照)。
   IPレンジは環境ごとに別レンジを割り当てる。
3. Rancherの Cluster Management → 対象クラスタ → Labels & Annotations で
   ラベル `env=staging`(または `env=production`)を付与する。
4. Rancher localクラスタへ対応するGitRepoを適用する:
   ```bash
   kubectl --context <rancher-local> apply -f fleet-bootstrap/gitrepo-staging.yaml
   ```
5. `envs/<env>/infra/` が空のうちは何も適用されない。手順4(移行)完了後は、
   dev の `envs/dev/infra/` を昇格PRでコピーして Longhorn 等を導入する。

## 3. 既存クラスタ(dev1)の移行手順

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
3. `envs/staging/infra/`・`envs/production/infra/` にも同内容をコピーする。ただし
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
  昇格で staging / production へ展開する。
- **設定変更・バージョンアップ**: devの `envs/dev/sites/<site>/fleet.yaml` または
  `charts/ibid-wordpress/` を変更 → PR → マージ → devで動作確認 →
  Actionsの `promote` を手動起動(dev→staging) → stagingで確認 →
  `promote`(staging→production) → CODEOWNERS承認を経てマージ。
- **チャート更新**: `charts/ibid-wordpress/` を変更し `Chart.yaml` のversionを上げる →
  マージで `release-chart.yaml` がGHCRへ公開 → devサイトの `helm.version` を上げるPR →
  以後は通常の昇格フロー。
- **イメージ更新**: [../images/wordpress/Dockerfile](../images/wordpress/Dockerfile) の
  digestと `TAG` を更新 → マージで `build-image.yaml` が公開 → チャートの `image.*` を
  切り替えてチャートversionを上げる → 昇格フロー。

## 5. Longhornバックアップの運用

- 定期ジョブとバックアップ先は `envs/<env>/infra/longhorn-jobs/` でGit管理
  (snapshot-6h: 6時間ごと保持4世代 / backup-daily: JST 2:00、保持はdev・staging 7世代、
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
  全世代がまとめて出力される)。
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

## 補足: 将来の拡張

- **サイトSecretのSealedSecret移行(Phase 2の後半)**: コントローラ導入(6.参照)に
  続けて、bootstrap-site-secrets.shをSealedSecret生成モードへ改修し、既存サイトの
  Secretを環境ごとにGit管理へ移行する。
- **クラスタ定義のGitOps化(Phase 4)**: Rancher provisioning-v2 の Cluster オブジェクトを
  localクラスタ向けGitRepoで管理できるが、誤マージの影響半径が大きいため3クラスタ規模では
  急がない。
