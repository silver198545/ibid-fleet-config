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
   から選んでBackup CRを作ると確実)。
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
   (`--context rancher`はRancher local/管理クラスタ向けのkubeconfigコンテキスト。
   手順4(Fleetの再同期)の直前に`"paused":false`へ戻して再開する)

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

Rancher UI(Continuous Delivery → 対象バンドルのForce Update)または
`./scripts/deploy-wordpress.sh <env> <site>`で再適用させる。

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

手順2で削除した旧PVCの`persistentVolumeReclaimPolicy`が`Delete`だった場合、
旧Longhornボリュームは**PVC削除と同時に自動削除される**(手動での後片付けは不要。
その代わりロールバックはLonghornバックアップからの再リストアのみが手段になるため、
手順3実施前のバックアップの新しさが重要)。

過去にDR手順([manual-multi-env.md](manual-multi-env.md))で復元した経緯のあるサイト
(手動で`persistentVolumeReclaimPolicy: Retain`のPVを作成している)では、旧ボリュームは
PVC削除後も`detached`状態のまま**Longhorn上に残り続ける**。この場合は検証完了後、
容量回収のため明示的に削除する:

```bash
kubectl -n longhorn-system get volumes.longhorn.io   # 旧ボリューム名を確認
kubectl -n longhorn-system delete volumes.longhorn.io <旧wp-content用ボリューム> <旧DB用ボリューム>
```

削除後、`kubectl -n longhorn-system get nodes.longhorn.io`のノード使用率(%)が
下がることを確認する。
