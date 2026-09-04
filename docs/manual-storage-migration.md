# 既存サイトのストレージバックエンド移行(二重増幅対策)

[docs/roadmap.md](roadmap.md) 項目3で判明した問題への対応手順。ゲストクラスタ内のLonghorn
(`numberOfReplicas: 3`)は、そのボリュームが載っているVM仮想ディスク自体もHarvester側の
Longhornで3重化されているため、実データが**3×3=9倍**に物理増幅されている。

`charts/ibid-wordpress` v0.4.0以降、新規サイトは次の構成で作成される(いずれもゲストクラスタの
Longhornプールに直接依存しない、または増幅を9倍→3倍に抑える構成):

- **wp-content**(RWX、Webレプリカ間で共有): `longhorn-r1` StorageClass
  (既存`longhorn`と同一パラメータ、`numberOfReplicas`のみ1。耐障害性はHarvester側の
  3重化に委ねる。RWXが必要なため`harvester` StorageClassには載せられない)
- **MariaDB**(RWO、単一Pod): `harvester` StorageClass(Harvester CSI driver、
  `driver.harvesterhci.io`)。ゲストクラスタのLonghornを経由せずHarvesterの仮想ディスクに
  直接乗るため、ゲストノードのLonghornプールを消費しない

v0.4.0より前に作成された既存サイトは`longhorn`(replica=3)のまま起動しているため、
**PVC単位で手動移行が必要**。以降、対象サイト名を`<site>`、環境名を`<env>`と表記する。

## 前提条件

1. `charts/ibid-wordpress`がv0.4.0以降で公開済み。
2. 対象サイトの`envs/<env>/sites/<site>/fleet.yaml`の`helm.version`を新チャートバージョンに
   上げるPRを**先にマージしてFleetに反映させておく**。
   既存のStatefulSetの`volumeClaimTemplates`とPVCの`storageClassName`はいずれも
   Kubernetes側で不変のため、この時点のHelm upgradeはmariadb StatefulSetとwp-content PVCの
   2リソースについて失敗する(想定内。他のリソースは正常に適用される)。
   この「新設定は入っているが古いPVC/StatefulSetのせいで反映できていない」状態を
   確認してから次に進む(逆順で手動削除だけ先にやると、Fleetの継続的な再同期が
   古いチャートのままPVC/StatefulSetを作り直してしまい手順が壊れる)。
3. サイトのwp-content・DB両方について、直近のLonghorn定期バックアップが存在すること
   (`envs/<env>/infra/longhorn-jobs/`のRecurringJobで環境ごとに自動実行されている。
   古い場合は手動でSnapshot CR→Backup CRを作成してトリガーしておく。手動作成の
   Snapshotは自動クリーンアップで即座に消えることがあるため、既存の直近スナップショット
   一覧(`kubectl -n longhorn-system get snapshots.longhorn.io -l longhornvolume=<volume>`)
   から選んでBackup CRを作ると確実)。**手順2でPVCを削除する前に、対応するPVの
   `persistentVolumeReclaimPolicy`を必ず確認する**
   (`kubectl get pv -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'`、PVC経由で
   `.spec.volumeName`から辿る)。`Delete`の場合、PVC削除と**同時にボリューム自体も
   即座に完全削除される**(実際にproductionで発生: DR復元の経緯がなくreclaimPolicyが
   既定の`Delete`だったため、猶予なく削除された)。この場合バックアップが唯一の
   復旧手段になるため、**削除直前の直近バックアップの新しさ(何時間前か)を
   必ず確認し、必要なら手順2実行の直前に追加でバックアップを取ってから削除する**。
   `Retain`(過去にDR復元した経緯があるサイト)の場合は削除後も`detached`状態で
   残るため、この点の緊急性は低い。
4. **Fleet bundleを一時停止する**(重要): 手順2の不変フィールドエラーで
   Helm upgradeが失敗している間も、Fleetは継続的にリトライし続け、その都度
   チャートの現在の値でDeployment/StatefulSetを再適用する。この再適用は
   `replicas`フィールドも含むため、**手動でのスケールダウンがFleetの再同期に
   打ち消されてPodが復活してしまう**(実際に発生した)。以下の手順(書き込み停止〜
   wp-content復元)を始める前に必ずバンドルを一時停止する:
   ```bash
   kubectl --context rancher patch bundle -n fleet-default \
     ibid-<env>-envs-<env>-sites-<site> --type=merge -p '{"spec":{"paused":true}}'
   ```
   (`--context rancher`はRancher local/管理クラスタ向けのkubeconfigコンテキスト)。
   手順4(Fleetの再同期)の直前に、同じコンテキストで一時停止を解除する:
   ```bash
   kubectl --context rancher patch bundle -n fleet-default \
     ibid-<env>-envs-<env>-sites-<site> --type=merge -p '{"spec":{"paused":false}}'
   ```

**1サイトずつ実施し、検証まで完了させてから次のサイトに進む**こと。

## 手順

```bash
SITE=web       # 実際のサイト名に置き換える
ENV=dev        # 実際の環境名に置き換える
NS="wordpress-$SITE"
```

### 1. 書き込み停止とDBの論理バックアップ

```bash
kubectl -n "$NS" scale deploy "wordpress-$SITE" --replicas=0

# mariadbはまだ起動した状態で、アプリDBのみをダンプする
# (--all-databases にすると、移行後にBitnamiイメージが新インスタンスで
#  ブートストラップするmysqlシステムテーブル/ユーザーを上書きしてしまうため避ける)
kubectl -n "$NS" exec "wordpress-$SITE-mariadb-0" -- \
  mariadb-dump -u root -p"<rootpassword>" bitnami_wordpress > "/tmp/${SITE}-dump.sql"

kubectl -n "$NS" scale statefulset "wordpress-$SITE-mariadb" --replicas=0
```

rootパスワードは`wordpress-<site>-mariadb-credentials` Secretから取得する
(`kubectl -n "$NS" get secret wordpress-$SITE-mariadb-credentials -o jsonpath='{.data.mariadb-root-password}' | base64 -d`)。

### 2. 旧PVC・StatefulSetの削除

wp-cliのplugin-sync Job(完了済みでも)がwp-content PVCを参照し続けていると、
PVC削除が`Terminating`のまま進まない(`pvc-protection`finalizerがPodの参照を
待つため、Podが`Completed`でも解放されない)。先に削除しておく
(Fleent再同期時に同名で再作成されるため実害はない):

```bash
kubectl -n "$NS" get jobs
kubectl -n "$NS" delete job -l app.kubernetes.io/component=plugin-sync   # 該当Jobがあれば
```

```bash
kubectl -n "$NS" get pods   # 消えたことを確認してから
kubectl -n "$NS" delete pvc "wordpress-$SITE" "data-wordpress-$SITE-mariadb-0"

# volumeClaimTemplatesはHelm upgradeでは変更できないため、
# StatefulSetオブジェクト自体を削除して次のHelm applyで新規作成させる
kubectl -n "$NS" delete statefulset "wordpress-$SITE-mariadb"
```

### 3. wp-content: バックアップから`longhorn-r1`へ復元

最新のLonghornバックアップから、`numberOfReplicas: 1`を指定した新規ボリュームを作成する
(`volume=`は実際のボリューム名。ハッシュ付きCRリソース名を指定すると
`backupVolumes "" not found`で拒否される。詳細は
[manual-dr-troubleshooting.md](manual-dr-troubleshooting.md)参照):

```yaml
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: migrate-<site>-content   # 任意の新ボリューム名
  namespace: longhorn-system
spec:
  size: "10737418240"
  numberOfReplicas: 1
  accessMode: rwx
  frontend: blockdev
  fromBackup: "nfs://192.168.1.1:/data/nfs/longhorn/<env>?backup=<バックアップ名>&volume=<旧ボリューム名>"
```

`status.state: detached`になったら、元のPVC名でPV/PVCを手動作成する
(Helmが自リソースと認識できるようアノテーション/ラベルを付ける):

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: migrate-<site>-content
spec:
  capacity: {storage: 10Gi}
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn-r1
  csi: {driver: driver.longhorn.io, fsType: ext4, volumeHandle: migrate-<site>-content}
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
  storageClassName: longhorn-r1
  volumeName: migrate-<site>-content
  resources: {requests: {storage: 10Gi}}
```

### 4. Fleetの再同期

前提条件の手順4で一時停止したバンドルを解除してから
(`{"spec":{"paused":false}}`)、Rancher UI(Continuous Delivery → 対象バンドルの
Force Update)または`./scripts/deploy-wordpress.sh <env> <site>`で再適用させる。

- mariadb StatefulSetは新規作成されるため、`storageClassName: harvester`の
  `data-wordpress-<site>-mariadb-0`が自動的にプロビジョニングされる(空のDB)。
- wp-content PVCは既存の値(手順3で作成済み)と一致するため、Helmはそのまま採用する。

### 5. DBの論理リストアと復旧

```bash
# mariadb Podが Ready になるまで待つ
kubectl -n "$NS" wait --for=condition=ready pod "wordpress-$SITE-mariadb-0" --timeout=180s

kubectl -n "$NS" exec -i "wordpress-$SITE-mariadb-0" -- \
  mariadb -u root -p"<rootpassword>" bitnami_wordpress < "/tmp/${SITE}-dump.sql"

kubectl -n "$NS" scale deploy "wordpress-$SITE" --replicas=2
```

## 検証

- `kubectl get pv,pvc -n wordpress-<site>` で`storageClassName`が`longhorn-r1`/`harvester`、
  `Bound`になっていること
- Longhorn UIでwp-contentボリュームが`numberOfReplicas=1`・healthy、mariadbボリュームが
  ゲストLonghornの一覧から消えていること
- `https://<site>.<env>.ibid.lan/` がHTTP 200、wp-adminにログインできる
- 移行前と比べて投稿・プラグイン一覧・メディアが一致していること
- `kubectl -n wordpress-<site> exec <wordpress-pod> -- grep table_prefix /bitnami/wordpress/wp-config.php`
  でテーブル接頭辞(`tp_`)が変わっていないこと
- 対象バンドルがFleet上で`Ready`(`Modified`/エラー状態でない)
- `kubectl -n longhorn-system get nodes.longhorn.io`で該当ノードの使用率が下がっていること

## ロールバック

手順1のDBダンプと、移行前に取得したLonghornバックアップ(手順3の`fromBackup`元)を
削除するまでは、いつでも[manual-wordpress-restore.md](manual-wordpress-restore.md)の
通常のリストア手順で元に戻せる。

## 移行後の後片付け(旧ボリュームの削除)

手順2で削除した旧PVCが紐づいていたPVの`persistentVolumeReclaimPolicy`が`Delete`
だった場合、旧Longhornボリュームは**PVC削除と同時に自動削除される**(手動での
後片付けは不要。その代わりロールバックはLonghornバックアップからの再リストアのみが
手段になるため、手順3実施前のバックアップの新しさが重要)。

過去にDR手順([manual-multi-env.md](manual-multi-env.md))で復元した経緯のあるサイト
(手動で作成したPVの`persistentVolumeReclaimPolicy`が`Retain`になっている)では、旧ボリュームは
PVC削除後も`detached`状態のまま**Longhorn上に残り続ける**。この場合は検証完了後、
容量回収のため明示的に削除する:

```bash
kubectl -n longhorn-system get volumes.longhorn.io   # 旧ボリューム名を確認
kubectl -n longhorn-system delete volumes.longhorn.io <旧wp-content用ボリューム> <旧DB用ボリューム>
```

削除後、`kubectl -n longhorn-system get nodes.longhorn.io`のノード使用率(%)が
下がることを確認する。

## wp-contentのLonghorn RWX(NFS-Ganesha)起因のRemote I/O error対策(nfs-external移行)

dev1で長期間未解決だった、大量ファイル操作時にwp-contentが断続的に`Remote I/O error`を
返す問題([[dev1-nfs-restore-20260804]]参照)は、Longhorn RWX(share-manager/NFS-Ganesha)側の
問題と特定した。対策として`csi-driver-nfs`(kubernetes-csi公式、PR#146,#147)を導入し、
既存の外部NFSサーバー(`192.168.1.1`、Longhornバックアップ先と同一ホスト)へ直接マウントする
`nfs-external` StorageClassに切り替える。2026-09-03にabcサイトで実地検証・パイロット移行に
成功済み(PR#148)。

**前提**: 対象環境に`envs/<env>/infra/csi-driver-nfs`・`csi-driver-nfs-storageclass`が
導入済みであること(現状dev限定)。

### 手順

1. 対象サイトの`envs/<env>/sites/<site>/fleet.yaml`に以下を追加してPR:
   ```yaml
   wordpress:
     persistence:
       storageClass: nfs-external
   ```
2. マージ前に、対象サイトのFleet bundleを一時停止し、Webレプリカを0にスケールダウンする
   (書き込み停止。mariadbはStatefulSet起動のままでよい):
   ```bash
   kubectl --context rancher patch bundle -n fleet-default ibid-<env>-envs-<env>-sites-<site> \
     --type=merge -p '{"spec":{"paused":true}}'
   kubectl -n wordpress-<site> scale deploy wordpress-<site> --replicas=0
   ```
3. PRマージ後、plugin-syncのJobが残っていれば先に削除(残っているとPVC削除が
   `Terminating`のまま止まる)、旧wp-content PVCを削除する:
   ```bash
   kubectl -n wordpress-<site> delete job -l app.kubernetes.io/component=plugin-sync
   kubectl -n wordpress-<site> delete pvc wordpress-<site>
   ```
   (reclaimPolicyが`Delete`の場合、旧Longhornボリュームも同時消滅する。事前に
   直近のLonghornバックアップの鮮度を必ず確認しておくこと)
4. **PVCとPodが完全に消えたことを確認してからbundleのpauseを解除する。**
   削除完了前にunpauseすると、Fleetが古いPVCへ競合状態でPodを再アタッチしてしまうことがある
   (実際に2026-09-03のabc移行で発生)。
   ```bash
   kubectl -n wordpress-<site> get pvc,pod   # 両方消えていることを確認
   kubectl --context rancher patch bundle -n fleet-default ibid-<env>-envs-<env>-sites-<site> \
     --type=merge -p '{"spec":{"paused":false}}'
   # 反映されない場合はforceSyncGenerationを+1
   ```
   **罠: bundleの`spec.paused`は`patch`で`true`にした後でも、PVC削除待ちの間に
   (原因未特定だが)`false`/未設定に戻ることがある**(2026-09-04の残り14サイト移行で複数回発生)。
   Fleetのドリフト補正が、pause状態そのものとは別に、既存Deploymentのreplicas数を
   常時マニフェストの値に戻し続けるためと見られる。手動でscale-downしても数秒〜分で
   Podが復活しPVCの`Terminating`が進まなくなるので、PVC削除の直前に必ず
   `spec.paused`を再確認し、消えるまで「scale-down→plugin-sync Job削除」を
   ループさせてから`delete pvc`を実行すること。新PVCが意図せず作られてしまった場合
   (削除後すぐに`nfs-external`の新PVCが立っていることがある)、それをさらに
   誤って消してしまわないよう、削除対象は常に**削除前に確認した旧`volumeName`**で
   判定すること。
5. 新PVC(`nfs-external`)が`Bound`になり、Podが起動したら、データを復元する:
   - バックアップが手元にある場合: `scripts/restore-wordpress.sh <site> <backupdir>`で
     wp-content+DBを一括リストア([docs/manual-wordpress-restore.md](manual-wordpress-restore.md)参照)
   - バックアップが無い(現行データをそのまま引き継ぎたい)場合:
     **ライブの`tar`/`cp`によるwp-contentコピーは、Remote I/O errorが起きているサイト
     ほど信頼できない**(2026-09-04の複数サイトで実際に発生・確認済み)。代わりに
     直近のLonghornバックアップから一時ボリュームを作って抽出する
     (DBはmariadb Podが別PVC=RWXバグの影響を受けないため、`mariadb-dump`でライブ取得すれば
     直近バックアップより新しい状態を使える):
     ```bash
     # 1. wp-content用PVCのボリューム名とその最新backupを確認
     kubectl -n longhorn-system get backupvolumes.longhorn.io | grep <旧volume名>
     # 2. fromBackupで一時Volumeを作成(backup=はCR名そのまま、volume=はハッシュ抜きの旧volume名)
     #    (前提条件のYAML例と同じ形式。numberOfReplicas: 1, frontend: blockdev)
     # 3. state=detached/restoreRequired=falseを待ってから、静的PV/PVC+busyboxヘルパーPodを作成
     #    (storageClassNameは任意の一時名でよい。RWXでもよいがsingle readerなので実害なし)
     # 4. tar -cf でwp-content一式を抽出(Remote I/O errorが散発するため、
     #    exit code 0になるまで数回リトライする。1〜2回で通ることが多い)
     kubectl exec <helper> -- tar -cf /tmp/content.tar -C /mnt/content/wordpress .
     # 5. ローカルへ kubectl cp → lzop圧縮 → restore-wordpress.sh の入力形式(tar.lzo/dump.lzo)に
     # 6. 一時Volume/PV/PVC/Podを削除してから、手順5の restore-wordpress.sh を通常どおり実行
     ```
6. URL置換(`wp search-replace`)・`wp rewrite flush --hard`を実行する。
7. **罠: 新規生成された`wp-config.php`の`WP_HOME`/`WP_SITEURL`定数が
   `http://<hostname>//`(スキームがhttp、末尾スラッシュ重複)になっていることがある**
   (ラッパーチャートのTraefik ingress設定からの生成ロジックに起因、本移行固有ではない)。
   DBのオプションをsearch-replaceで直しても、この定数の方が優先されるため反映されない。
   `wp-config.php`を直接sedで書き換える:
   ```bash
   kubectl -n wordpress-<site> exec -c wordpress <pod> -- bash -c \
     "sed -i \"s|WP_HOME', 'http://<hostname>//'|WP_HOME', 'https://<hostname>'|; \
              s|WP_SITEURL', 'http://<hostname>//'|WP_SITEURL', 'https://<hostname>'|\" \
     /bitnami/wordpress/wp-config.php"
   ```
8. 動作確認(HTTP 200、`wp plugin list`、`find`の複数回実行でエラーが再現しないこと)後、
   退避された`wp-content.orig`を削除する。
9. **罠: `plugins:`を宣言しているサイトでは、Fleetのplugin-sync Jobが
   `restore-wordpress.sh`のDB復元(手順5の一時DB削除→再作成→インポート)と競合し、
   DB再作成前に処理されたプラグインの有効化がサイレントに失われることがある**
   (2026-09-04のwebサイトで発生: `Table 'bitnami_wordpress.tp_options' doesn't exist`が
   多発し、当該プラグインだけ`wp plugin list`から消えていた)。`wp plugin list`が
   fleet.yamlの`plugins:`一覧と一致しない場合、plugin-sync Jobを削除して
   (`kubectl delete job wordpress-<site>-plugin-sync-<hash>`)forceSyncGenerationを+1すれば
   再実行され、今度はDBが揃っているため全件揃う。

### 検証結果

- **abc(2026-09-03、パイロット)**: 移行前は稼働中にRemote I/O errorが発生していた状態から、
  移行後は本物のバックアップ(269MB/16027ファイル)の展開・DBリストア・`wp plugin list`・
  `find`の3回連続実行、いずれもエラー0件で安定動作を確認した。
- **残り14サイト、dev全サイト完了(2026-09-04)**: cell/dna/epd/hdm/iddd/info/jcm/jmc/
  kougaku/mcd/mus/pms/tet/webへ展開。このうちdna/hdm/info/mus/webは移行作業開始前から
  Podが繰り返しCrashLoop/Not Ready(129〜200回再起動)だった状態で、移行後はいずれも
  HTTP 200・`find`3回連続エラー0件まで復旧した。dev環境は全15サイトがnfs-externalへ
  移行済み。次はstaging/productionへの展開判断。
