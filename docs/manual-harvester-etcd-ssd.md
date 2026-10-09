# control-plane(etcd)VMディスクをSSD上に限定する手順

ゲストクラスタ(dev1/prod1)のcontrol-plane VMは、ルートディスクにetcdのデータを持っています。
このディスクのLonghornレプリカが**HDD上にあると、etcdの書き込みが遅くなります**。その結果
kube-apiserverが再起動を繰り返し、ノードがNotReadyへフラップします。この手順では、Harvester側の
Longhornで、control-plane VMのディスクレプリカをSSD(`defaultdisk`)上にだけ置くようにします。

すべてHarvester管理クラスタ上での作業で、Gitでは管理されません。**VMを止めずに実施できます。**

## 背景(2026-10-08 dev1で発生)

- Harvesterの各ホストには2種類のディスクがある。

  | Longhornディスク | デバイス | 種類 | 平均書き込みレイテンシ(実測) |
  |---|---|---|---|
  | `/var/lib/harvester/defaultdisk` | `sda6`(526GB) | SSD相当 | 0.05〜0.08 ms |
  | `/var/lib/harvester/extra-disks/<id>` | `sdb`(1.2TB、PERC H355配下) | HDD | 13〜56 ms(使用率最大97%) |

- Longhornのレプリカは3つで、同期書き込み。そのため、1つでもHDD上にあると全体がHDDの速度に引きずられる。
- 既定のStorageClassにはdiskSelectorが無い。そのためVMディスクのレプリカはHDDとSSDに混在して配置される。
- dev1では、レプリカ3つのうち2つがHDD上にあったmbjvtで、etcdの`slow fdatasync`が最大6.8秒になっていた。
  apiserverがetcdのhealthcheck失敗で249回再起動していた。全レプリカが`defaultdisk`上にあったmq45pでは、
  fdatasyncの警告はゼロだった。

## 症状と確認方法

ゲストクラスタ側で確認する:

```bash
# apiserverの再起動回数(終了コード137 = liveness probe失敗によるkill)
kubectl --context dev1 -n kube-system get pod \
  -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,CODE:.status.containerStatuses[0].lastState.terminated.exitCode \
  | grep -E '^(etcd|kube-apiserver)'

# etcdのディスク遅延警告
kubectl --context dev1 -n kube-system logs etcd-<node> --since=1h | grep -c 'slow fdatasync'
```

apiserverのPodイベントに`Liveness probe failed: ... [-]etcd failed`が出ていて、etcdに
`slow fdatasync`や`apply request took too long`が多ければ、この手順の対象です。

Harvester側でレプリカの配置を確認する:

```bash
# kubeconfigのharvester1のクラスタIDが古い場合は、--serverで現在のIDを指定する
# (現在のIDは kubectl --context local get clusters.management.cattle.io で確認)
H="kubectl --context harvester1 --server=https://192.168.1.149/k8s/clusters/c-rqrxh"

# control-plane VMのディスクPVC → Longhornボリューム
for vm in $($H -n harvester-public get vm -o name | grep -- '-pool1-'); do
  for c in $($H -n harvester-public get $vm -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}'); do
    echo "${vm#*/} $c $($H -n harvester-public get pvc $c -o jsonpath='{.spec.volumeName}')"
  done
done

# レプリカがどのディスクにあるか(extra-disks = HDD)
$H -n longhorn-system get replicas.longhorn.io -l longhornvolume=<pvc-...> \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,DISK:.spec.diskPath,STATE:.status.currentState
```

## 事前確認

- **etcdメンバーが全台揃っていること。** レプリカを作り直している間はディスクI/Oが一時的に悪化する。
  メンバーが欠けた状態で行うと、残りのノードが落ちてquorumを失うおそれがある。

  ```bash
  kubectl --context dev1 -n kube-system exec etcd-<node> -- etcdctl \
    --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
    --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
    --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key member list
  ```

- 対象ボリュームが全て`robustness=healthy`であること。rebuild中のボリュームが無いこと。
- 各ホストの`defaultdisk`に空き容量があること。レプリカ1つでVMディスクのサイズ分(32GB)が増える。

  ```bash
  $H -n longhorn-system get nodes.longhorn.io -o json | python3 -c '
  import json,sys
  for n in json.load(sys.stdin)["items"]:
    for k,d in n["spec"]["disks"].items():
      s=n["status"]["diskStatus"][k]
      print(n["metadata"]["name"],k,d["path"][-30:],d.get("tags"),
            "avail=%.0fG max=%.0fG sched=%.0fG"%(s["storageAvailable"]/1e9,s["storageMaximum"]/1e9,s["storageScheduled"]/1e9))'
  ```

## 手順

### 1. `defaultdisk`に`ssd`タグを付ける

ディスクIDは、上の「事前確認」の出力にある`default-disk-...`の部分。

```bash
$H -n longhorn-system patch nodes.longhorn.io <host> --type merge \
  -p '{"spec":{"disks":{"<default-disk-id>":{"tags":["ssd"]}}}}'
```

全ホスト(hrvest1〜4)で行う。diskSelectorを持たない既存ボリュームは、タグを無視して配置されるので影響を受けない。

### 2. control-planeボリュームに`diskSelector`を設定する

```bash
$H -n longhorn-system patch volumes.longhorn.io <pvc-...> --type merge \
  -p '{"spec":{"diskSelector":["ssd"]}}'
```

設定しても、既存のレプリカは自動では移動しない。これ以降に新しく作られるレプリカだけが、`ssd`タグ付きディスクに置かれる。

### 3. HDD上のレプリカを1つずつ削除して作り直す

```bash
$H -n longhorn-system delete replicas.longhorn.io <extra-disks上のレプリカ名>
$H -n longhorn-system get volumes.longhorn.io <pvc-...> -w   # degraded → healthy を待つ
```

- **一度に削除するレプリカは1つだけ。** `healthy`に戻ったことを確認してから次に進む。複数のボリュームを並行して進めない。
- 1つ作り直すのに10〜20分程度かかる(32GBのrebuild)。その間はHDDへの読み込みが増えるので、etcdが一時的にさらに遅くなる。
- Longhornの`replica-soft-anti-affinity=false`の設定により、新しいレプリカは既存のレプリカが無いホストの`defaultdisk`に作られる。
- backing image(VMイメージ)が無いディスクには、自動でコピーされる。

### 4. 確認

```bash
# 全レプリカが defaultdisk 上にあること
$H -n longhorn-system get replicas.longhorn.io -l longhornvolume=<pvc-...> \
  -o custom-columns=NODE:.spec.nodeID,DISK:.spec.diskPath,STATE:.status.currentState

# 数十分後、etcdの slow fdatasync が出ていないこと・apiserverの再起動回数が増えていないこと
kubectl --context dev1 -n kube-system logs etcd-<node> --since=30m | grep -c 'slow fdatasync'
```

## 切り戻し

ボリュームの`diskSelector`を外す。ディスクのタグは残しても害は無い。

```bash
$H -n longhorn-system patch volumes.longhorn.io <pvc-...> --type json \
  -p '[{"op":"remove","path":"/spec/diskSelector"}]'
```

## 注意: ノードプールを作り直すと元に戻る

ここで設定したのは**既存のボリュームだけ**。Rancherがcontrol-plane VMを作り直すと(ノード入れ替え、
ディスク拡張、Machineの削除→再作成など)、新しいVMのディスクは元のStorageClassで作られる。
diskSelectorが無いので、またHDD上にもレプリカが置かれる。2026-10-08にdev1でv22vwを作り直したときは、
新しいディスクのレプリカが3つともHDD上に作られた。

恒久対策を入れるまでは、作り直した後にこのページの手順2〜4を対象ボリュームについてやり直す。

## 恒久対策: クラスタ・ノードプール作成時の設定(prod1は2026-10-08に実施済み、dev1は未実施)

VMのルートディスクは、HarvesterConfigの`diskInfo`で指定したVMイメージ(現在は`harvester-public/image-dkwx4`)
から作られる。そのStorageClassの設定は、イメージの`spec.storageClassParameters`で決まる。
現在のイメージにはdiskSelectorが無いので、`ssd`を指定したイメージを別に用意し、control-planeプールで使う。

### 1. diskSelector付きのStorageClassを作る(Harvester側で1回だけ)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: harvester-longhorn-ssd
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "3"
  staleReplicaTimeout: "30"
  migratable: "true"
  diskSelector: "ssd"
```

前提として、各ホストの`defaultdisk`に`ssd`タグが付いていること(このページの手順1)。

### 2. そのStorageClassを使うVMイメージを作る(Harvester側で1回だけ)

Harvester UIで「Images → Create」を選び、現在のイメージと同じURL
(`https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img`)を指定する。
Storageの欄で`harvester-longhorn-ssd`を選ぶ。名前は例えば`ubuntu-cloudimg-26.04-lts-ssd`にする。
UIの代わりに、次のYAMLで作ってもよい(prod1で実際に使った方法。作られたイメージは`image-fpm2h`):

```bash
cat <<'EOF' | $H create -f -
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  generateName: image-
  namespace: harvester-public
  annotations:
    harvesterhci.io/storageClassName: harvester-longhorn-ssd
spec:
  displayName: ubuntu-cloudimg-26.04-lts-ssd
  sourceType: download
  url: https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img
  backend: backingimage
  storageClassParameters:
    diskSelector: ssd
    migratable: "true"
    numberOfReplicas: "3"
    staleReplicaTimeout: "30"
EOF
```

作成後、ダウンロードが100%になり、`storageClassParameters`に`diskSelector`が入っていることを確認する。
イメージ用に自動で作られるStorageClass(`lh-...`)にも引き継がれる:

```bash
$H -n harvester-public get virtualmachineimages -o json | python3 -c '
import json,sys
for i in json.load(sys.stdin)["items"]:print(i["metadata"]["name"],i["spec"].get("displayName"),i["spec"].get("storageClassParameters"))'
```

### 3. Rancherのプール設定

| プール | イメージ | User Data | その他 |
|---|---|---|---|
| pool1(control-plane/etcd) | `ubuntu-cloudimg-26.04-lts-ssd` | NTPの設定入り([manual-node-ntp.md](manual-node-ntp.md)) | VMのanti-affinity(3台を別々のホストに置く) |
| pool2(worker) | 現在のまま(SSDの容量と相談) | NTPの設定入り | — |

- 必ずSSDにするのはpool1だけで足りる。workerのルートディスクは主にコンテナイメージ用で、
  etcdほど書き込みの遅さに敏感ではない。SSD(`defaultdisk`)は各ホスト526GBしかないので、
  workerも載せる場合は容量を計算してから決める。
- anti-affinityは、Rancherのプール設定の「VM Scheduling」で設定する。prod1では2026-10-08時点で、
  control-plane 3台のうち2台(s9rdr、2jbgr)が同じホスト(hrvest4)に載っていた。
  この状態でホストが落ちるとetcdがquorumを失う。設定値は次のとおり:

  | 項目 | 値 |
  |---|---|
  | Type / Priority | Anti-Affinity / Preferred |
  | 名前空間 | This VM's namespace |
  | Rule(Add Ruleで追加) | `harvesterhci.io/machineSetName` In `harvester-public-<クラスタ名>-pool1` |
  | Topology Key | `kubernetes.io/hostname`(空欄に見えるのは入力例。必ず手で入力する) |
  | Weight | 100 |

  Requiredにしないのは、入れ替えの途中で一時的にVMが4台になったときに、ホストのメモリが足りずに
  起動できなくなるのを避けるため。

### 4. 作成後のチェック

1. control-planeのディスクのレプリカが全て`defaultdisk`上にある(「症状と確認方法」のコマンド)
2. 全ノードで`chronyc -n sources`に`^*`が出ている
3. etcdのログに`slow fdatasync`も`clock drift`も出ていない
4. SealedSecretが全件`SYNCED=True`になっている。クラスタを再作成した場合は、
   sealed-secretsの鍵を復元するか([manual-multi-env.md](manual-multi-env.md)の6章)、全件を封印し直す
5. control-plane VMが別々のホストに置かれている(下の「既存クラスタに入れる場合の注意」を参照)
6. LoadBalancerにIPが付いている(chartValuesの`clusterName`が残っている)

### 既存クラスタ(dev1/prod1)に入れる場合の注意

HarvesterConfig(イメージ、User Data、anti-affinity)を書き換えると、**そのプールのVMが全て順番に作り直される**。

- 作業前に、ゲストクラスタ側のLonghornボリュームが全てattachedであることを確認する
  (2026-07-27/28に、ノードプールの入れ替えでdetachedなボリュームが失われた)。
- HarvesterConfigの`networkData`(FreeIPA用の2枚目のNIC)の指定を消さない。編集の前後で、
  harvester-cloud-providerのclusterNameのchartValuesを確認する。
- 3つの変更は1回の編集にまとめて、作り直しを1回で済ませる。
- UIでの編集でchartValuesが`{}`に消されることがある。保存した直後に
  [manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)のpatchで`clusterName`を入れ直す。
- プールの入れ替えではetcdがそのまま残るので、sealed-secretsの鍵は変わらない(クラスタの再作成とは違う)。
- **入れ替えの途中はanti-affinityが効かない。** 古いVMにも同じ`machineSetName`ラベルが付いていて、
  古いVMと新しいVMが全ホストに散らばるため、Preferredでは避けられるホストが無い。prod1では入れ替え後に
  control-plane 2台が同じホストに載った。入れ替えが終わったらホストの配置を確認し、偏っていれば
  Harvester UIの「Migrate」でcontrol-planeの載っていないホストへlive migrationする
  (VMは止まらず、ディスクの配置も変わらない):

  ```bash
  $H -n harvester-public get vmi -o custom-columns=NAME:.metadata.name,HOST:.status.nodeName | grep -- '-pool1-'
  ```

- **レプリカ1つ(`longhorn-r1`)のゲスト側ボリュームがあると、workerのdrainが止まる。** ゲスト側Longhornの
  `node-drain-policy`が`block-if-contains-last-replica`なので、最後のレプリカが載ったノードの
  instance-managerのPDBがevictionを拒否し、Machineが`Deleting`(`DrainingNode`)のまま進まない。
  一時的にレプリカを2つに増やすと、他のノードにコピーができた後でdrainが進む。Machineが消えたら1つに戻す:

  ```bash
  kubectl --context <cluster> -n longhorn-system patch volumes.longhorn.io <pvc-...> --type merge \
    -p '{"spec":{"numberOfReplicas":2}}'
  ```

## 実施記録

| 日付 | クラスタ | 対象 | 備考 |
|---|---|---|---|
| 2026-10-08 | dev1 | pool1の3台(mbjvt/mq45p/v22vw) | HDD上のレプリカ4つ(mbjvt、v22vwで各2つ)を`defaultdisk`へ移した。mq45pは元から全て`defaultdisk`上 |
| 2026-10-08 | dev1 | 55x4v(v22vwを削除して作り直したノード) | 新しいディスクはレプリカ3つが全てHDD上に作られていた。3つとも移した |
| 2026-10-08 | prod1 | pool1の3台(2jbgr/s9rdr/wcsxv) | 07:09の再作成直後から、レプリカ9つのうち7つがHDD上にあった。s9rdrのfdatasyncは最大17.6秒で、apiserverが繰り返し再起動し、Rancher上でReady=Falseになっていた。7つとも移した後はReady=Trueに戻った |
| 2026-10-08 | prod1 | 恒久対策(全8台を入れ替え) | pool1を`image-fpm2h`(ssd)に変更し、User DataにNTP、pool1にanti-affinityを設定した。入れ替え後、control-plane 3台とも全レプリカがSSD上。入れ替え中に偏ったため、1台をhrvest2へlive migrationした。`sparqlist-repository`(`longhorn-r1`)のせいでworkerのdrainが止まったため、一時的にレプリカを2つにした |
