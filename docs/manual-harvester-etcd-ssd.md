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
diskSelectorが無いので、またHDD上にもレプリカが置かれる。

作り直した後は、このページの手順1〜4を対象ボリュームについてやり直す。恒久対策
(`ssd`のdiskSelectorを持つVMイメージ/StorageClassをHarvesterConfigで指定する)には、
HarvesterConfigの書き換えが必要になる。HarvesterConfigを書き換えるとノードプール全体の入れ替えが起きるので、
別途計画して行う([manual-dr-troubleshooting.md](manual-dr-troubleshooting.md)も参照)。

## 実施記録

| 日付 | クラスタ | 対象 | 備考 |
|---|---|---|---|
| 2026-10-08 | dev1 | pool1の3台(mbjvt/mq45p/v22vw) | HDD上のレプリカ4つ(mbjvt、v22vwで各2つ)を`defaultdisk`へ移した。mq45pは元から全て`defaultdisk`上 |
| 2026-10-08 | dev1 | 55x4v(v22vwを削除して作り直したノード) | 新しいディスクはレプリカ3つが全てHDD上に作られていた。3つとも移した |
| 2026-10-08 | prod1 | pool1の3台(2jbgr/s9rdr/wcsxv) | 07:09の再作成直後から、レプリカ9つのうち7つがHDD上にあった。s9rdrのfdatasyncは最大17.6秒で、apiserverが繰り返し再起動し、Rancher上でReady=Falseになっていた。7つとも移した後はReady=Trueに戻った |
