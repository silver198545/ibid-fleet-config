# DR復元: 実践トラブルシューティング

[manual-multi-env.md](manual-multi-env.md)の「8. DR: クラスタ全損からの復元手順」を
実際に辿ると、手順書の想定通りには進まない箇所がある。ここでは2026-07-07にdev1で
実施した際に発生した詰まりどころと対処法を記録する。手順本体は上記ドキュメントに
残し、こちらは「詰まったときに読む」補足として分離している。作業端末に必要な
kubectl等のツール自体がまだ無い場合は先に[manual-tooling-setup.md](manual-tooling-setup.md)
を参照。

## 1. kubeconfig取得: 同名クラスタを再作成した場合の罠

**症状**: クラスタ削除→同名(例: `dev1`)で再作成→Rancher UIから新しいkubeconfigを
ダウンロードして`~/.kube/config`にマージしたのに、`kubectl --context dev1 get nodes`が
`the server could not find the requested resource`で失敗する。単体ファイル
(`kubectl --kubeconfig ~/.kube/dev1.yaml`)では正常に疎通できるのに、マージ後だけ壊れる。
(2026-08-03にdev1再作成時は`the server has asked for the client to provide
credentials`や`clusters.management.cattle.io "<旧クラスタID>" is forbidden: User
"system:unauthenticated"`という別の文言で出たこともある。エラー文言は違っても
原因は同じ「マージ時に旧エントリの認証情報が優先されて残る」ことなので、
単体ファイルでの疎通確認による切り分けは同様に有効。)

**原因**: `~/.kube/config`に、**削除した旧クラスタの`dev1`という名前のcontext/cluster**
が消されずに残っていた。新しいkubeconfigも同じ名前(`dev1`)を使うため、
`kubectl config view --flatten`でのマージ時に名前が衝突し、古い(もう存在しない
クラスタIDを指す)エントリが生き残ってしまう。

見分け方: 新旧のサーバーURLを比較する。
```bash
kubectl config view -o jsonpath='{.clusters[?(@.name=="dev1")].cluster.server}'
grep server ~/.kube/dev1.yaml
```
`/k8s/clusters/c-m-xxxxx`のクラスタIDが一致していなければこれが原因。

**対処**:
```bash
kubectl config delete-context dev1
kubectl config delete-cluster dev1
kubectl config get-users            # dev1という名前のuserが単独で残っていないか確認
kubectl config delete-user dev1     # 単独であれば削除(rancher等と共有していれば消さない)

MERGED="$(mktemp)"
KUBECONFIG=~/.kube/config:~/.kube/dev1.yaml kubectl config view --flatten > "$MERGED"
install -m 600 "$MERGED" ~/.kube/config
rm -f "$MERGED"
kubectl config get-contexts
```

なお、Rancherが発行するkubeconfigは、そのユーザーが持つ全クラスタのcontextで
同じ`AUTHINFO`名(`rancher`)を共有するのが正常な挙動(Rancher API経由のプロキシは
ユーザー単位のトークンで全クラスタにアクセスするため)。`AUTHINFO`が全部`rancher`に
揃っていること自体は問題ではない。問題になるのは**cluster/context名がクラスタの
再作成をまたいで使い回された場合**だけ。

## 2. LonghornボリュームのfromBackup復元: `volume=`パラメータの落とし穴

**症状**: バックアップから復元用`Volume`を作成しようとすると、admission webhookに
即座に拒否される。
```
Error from server (Invalid): ... admission webhook "mutator.longhorn.io" denied the request:
cannot get backup volume for backup target default and volume <指定した名前>: backupVolumes "" not found
```

**原因**: `fromBackup`のURLの`volume=`パラメータに、`backupvolumes.longhorn.io`の
**CRリソース名**(`pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx-<8文字のハッシュ>`という、
末尾にランダムなハッシュが付いた形式)をそのまま使ってしまうと失敗する。
`volume=`に指定すべきなのは、そのハッシュを除いた**実際のボリューム名(PV名と同じ)**。

正しい値は、対象の`BackupVolume`の`.status.labels.KubernetesStatus`(JSON文字列)に
埋め込まれた`pvName`フィールドで確認できる:
```bash
kubectl -n longhorn-system get backupvolumes.longhorn.io <CR名> \
  -o jsonpath='{.status.labels.KubernetesStatus}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["pvName"])'
```

例:
- `backupvolumes.longhorn.io`のCR名: `pvc-cec2b51e-a416-4e22-a8c9-70cf1cf9b861-5a8e2740`
- `fromBackup`に書くべき`volume=`の値: `pvc-cec2b51e-a416-4e22-a8c9-70cf1cf9b861` (ハッシュ抜き)

`backup=`パラメータ(バックアップ名、`backup-xxxxxxxxxxxxxxxx`形式)はCR名をそのまま
使ってよく、これは間違えやすいポイントではない。

## 3. 事前にPVC⇔ボリュームの対応を控え忘れた場合の復旧方法

手順本体の1では「ボリューム名とPVC名・namespaceの対応を必ず控える」よう案内しているが、
**計画外の削除や、控え忘れた場合でも、`BackupVolume`のラベルから事後的に復元できる**。

```bash
for bv in $(kubectl -n longhorn-system get backupvolumes.longhorn.io -o name); do
  echo "== $bv =="
  kubectl -n longhorn-system get "$bv" -o jsonpath='{.status.size}{"\n"}{.status.labels.KubernetesStatus}{"\n"}'
  echo
done
```
`KubernetesStatus`に`namespace`・`pvcName`・`pvName`が全て残っているため、
サイズ(mariadb用8Gi/RWO、wp-content用10Gi/RWXなど)と合わせればどのバックアップが
どのサイトのどちらのデータか一意に特定できる。

## 4. wp-content用PVCの削除が`Terminating`のまま進まない

**症状**: `kubectl -n wordpress-<site> delete pvc wordpress-<site>`(wp-content用、
Deployment側)を実行しても`Terminating`のまま消えない。対応するmariadb用PVC
(StatefulSet側)は正常に消える。

**原因**: `kubernetes.io/pvc-protection`ファイナライザは、そのPVCを参照する**Podオブジェクトが
1つでも存在する限り**外れない。`Completed`状態のPodも対象になる。このチャートには
wp-contentを共有ボリュームとしてマウントする`wordpress-<site>-plugin-sync`という
使い捨てJobがあり、そのCompleted Podがwp-content PVCを参照したまま残っているとハングする。

**対処**: PVC削除前に、該当PVCを参照しているPodを確認し、Completedなものは削除してよい
(Jobが管理しているだけなので必要なら再作成される)。
```bash
kubectl -n wordpress-<site> get pod <plugin-syncのPod名> -o jsonpath='{.spec.volumes}'
kubectl -n wordpress-<site> delete pod <plugin-syncのPod名>
```

## 5. (確認事項)復元後のRecurringJob適用

手動で作り直した`Volume`/`PersistentVolumeClaim`には、`recurring-job-group.longhorn.io/*`
ラベルは何も付かない。しかしこのリポジトリの`snapshot-6h`/`backup-daily`は
`groups: ["default"]`で定義されており、Longhornの`default`グループは
「明示的なグループ指定のないボリューム全て」に自動適用される特別なグループなので、
**復元後のボリュームも追加設定なしで既存の定期バックアップ対象に戻る**。実際に
`kubectl -n longhorn-system get recurringjobs.longhorn.io`と対象ボリュームの状態で
確認済み(2026-07-07dev1復元時点)。

将来`default`以外のグループを使う運用に変えた場合は、この前提が崩れるため
手動復元時にラベルを明示的に付け直す手順を追加すること。

## 6. 2026-07-27/28: dev1・productionで同時多発した復元作業の教訓

[manual-multi-env.md](manual-multi-env.md)の「ノードプール入替の前提条件」1.が
警告する「detachedボリュームは入替で全損する」が、同日中にdev1(17サイト)と
production(web/dna)の両方で実際に発生した。事前チェックリストを踏まずに
ノードプールのディスク拡張を行うと環境を問わず再現するため、**ノードプール編集
(ディスクサイズ変更含む)の前には必ず同ドキュメントの前提条件1〜2を確認する**こと。
以下は今回の復元作業で新たに判明した、上記1〜5には無い詰まりどころ。

### 6a. 動的プロビジョニングのPVC/PVが残っている状態で`Volume`を削除・再作成すると、PV/PVCが自動削除されることがある

**症状**: faultedな`Volume`(CR)を削除して`fromBackup`付きで再作成した直後、
対応するPVC/PVが(手を触れていないのに)`Terminating`→消失する。特に
`persistentVolumeReclaimPolicy: Delete`のまま(動的プロビジョニングPVCの既定)
だと、PVが`Released`を経由してそのまま実体ごと削除されかねない
(=復元したばかりのデータを再度失う)。

**原因**: `driver.longhorn.io`のCSI外部プロビジョナーが、PVが参照する
`Volume`(CR)の消失を検知して所有PVの片付けを始めるとみられる(発生タイミングは
一定しないレースで、必ず起きるわけではない)。

**対処**: `Volume`を削除する前に、必ず以下の順序で進める。

```bash
# 1. 対象PVのreclaimPolicyをRetainに変更(バックアップ復元中の誤爆防止)
kubectl -n <namespace> patch pv <pv名> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
# 2. Deploymentをスケールダウン
kubectl -n wordpress-<site> scale deploy wordpress-<site> --replicas=0
# 3. PVC→PVの順に明示的に削除(Volume削除より先に、こちらから片付ける)
kubectl -n wordpress-<site> delete pvc wordpress-<site> --timeout=30s
kubectl delete pv <pv名> --timeout=30s
# 4. ここでVolume(CR)を削除→fromBackupで再作成→restoreRequired=false/state=detachedを待つ
#    (PV/PVCが存在しない状態で復元するため、上記のレースが起こり得ない)
# 5. 復元完了後、PV/PVCを新規作成(reclaimPolicy: Retainで作る。手順7参照)
```

既にPVC/PVがレースで消えてしまった場合でも、`Volume`(CR)自体の実データは
無事な可能性が高い(CSIの`DeleteVolume`呼び出しがLonghorn側に届く前に
finalizer解除だけ先行するケースがある)。**慌てて`Volume`を再作成し直す前に、
まず対象`Volume`(CR)の`status.actualSize`が0でないか確認する。**

### 6b. PVC削除が`Terminating`のまま進まない(4.の追加パターン): 旧ノード宛の`VolumeAttachment`残骸

4.が挙げる`plugin-sync`Podの他に、**ノードプール入替で消滅した旧ノード宛の
`VolumeAttachment`が残っていると、`external-attacher`のfinalizerが外れずPVが
`Terminating`のまま進まない**。

```bash
kubectl get volumeattachments -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
for i in d["items"]:
    print(i["metadata"]["name"], i["spec"]["source"].get("persistentVolumeName"), i["spec"]["nodeName"], i["status"])
' | grep <対象ボリューム名>
```

`attached: true`のまま何十分も残っている(かつ実際にはどのPodにも使われていない)
ものは、そのまま削除してよい。

```bash
kubectl delete volumeattachment <該当VolumeAttachment名>
```

### 6c. 復元後、特定ノードでだけPodが`Init:0/1`のまま進まなくなる(kubeletのマウント再試行バックオフ)

**症状**: `Volume`は`attached/healthy`、Longhornの`share-manager`もRunning、
CSIコントローラの`ControllerPublishVolume`も成功しているのに、その後
kubelet側の`NodeStageVolume`呼び出しが(CSIノードプラグインのログに)一切現れず、
Podが`Init:0/1`のまま数分〜十数分固まる。同じ`(ノード, ボリューム)`組で
過去数分以内に複数回マウント失敗している場合に再現しやすい。

**原因(推定)**: kubeletのvolume managerが、直近の失敗を踏まえて再試行に
指数バックオフをかけている。バックオフはノード単位でローカルに保持されるため、
**同じボリュームでも別のノードに載せ直すと即座に成功する**ことで裏付けられる。

**対処**: 該当Podを削除してスケジューラに再配置させる。同じ(問題のある)ノードに
再度乗ってしまうこともあるため、数回繰り返すか、確実に避けたい場合は
Deploymentへ一時的な`nodeAffinity`(未試行のノードを`In`で指定)を追加して
Podを削除→起動を確認後、**必ずaffinityを削除して元のFleet管理定義に戻す**
(Fleetの差分検知に引っかかり続けるため放置しない)。

```bash
kubectl -n wordpress-<site> patch deploy wordpress-<site> --type=json -p '[
  {"op":"add","path":"/spec/template/spec/affinity","value":
    {"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[
      {"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"In","values":["<未試行ノード1>","<未試行ノード2>"]}]}
    ]}}}}]'
# Pod削除→Running確認後
kubectl -n wordpress-<site> patch deploy wordpress-<site> --type=json -p '[{"op":"remove","path":"/spec/template/spec/affinity"}]'
```

### 6d. 手動で作り直したPV/PVCは、Fleetから「not owned by us」でModified扱いになる

**症状**: 6a〜6cの手順でPV/PVCを手動再作成した後、Rancher UIまたは
`kubectl get bundles -n fleet-default`でバンドルが`Modified`になり、
`persistentvolumeclaim.v1 wordpress-<site>/wordpress-<site> is not owned by us`
と表示される。

**原因**: HelmのSDKは、リソースが自分のReleaseの所有物かどうかを
`meta.helm.sh/release-name`・`meta.helm.sh/release-namespace`アノテーションと
`app.kubernetes.io/managed-by: Helm`ラベルで判定する。手動で作ったPVCにはこれが
付かないため「所有していない外部リソース」とみなされる。

**対処**: 既存サイトの(壊れていない)PVCの`metadata`を参考に、同じ値で
アノテーション・ラベルを付け直す(`release-name`/`release-namespace`は
fleet.yamlの`helm.releaseName`とnamespaceに一致させる)。

```bash
kubectl -n wordpress-<site> annotate pvc wordpress-<site> \
  meta.helm.sh/release-name=wordpress-<site> \
  meta.helm.sh/release-namespace=wordpress-<site> --overwrite
kubectl -n wordpress-<site> label pvc wordpress-<site> \
  app.kubernetes.io/managed-by=Helm \
  app.kubernetes.io/instance=wordpress-<site> \
  app.kubernetes.io/name=wordpress \
  app.kubernetes.io/version=7.0.0 \
  helm.sh/chart=wordpress-32.1.10 --overwrite
```

付け直した後も**Fleetのバンドルステータスはすぐには追随しない**(古い
Modified判定をキャッシュしたまま)。GitRepoの`forceSyncGeneration`を+1して
強制再同期させると即座に反映される。

```bash
CUR=$(kubectl --context rancher get gitrepo <ibid-dev|ibid-staging|ibid-production> -n fleet-default -o jsonpath='{.spec.forceSyncGeneration}')
kubectl --context rancher patch gitrepo <同上> -n fleet-default --type=merge \
  -p "{\"spec\":{\"forceSyncGeneration\":$((CUR+1))}}"
```

## 7. 特定ノードでだけ詰まるボリュームの根本原因調査と、その復旧で新たなノード再起動が引き起こした二次被害(2026-07-28)

6c.の「特定ノードでだけ`Init:0/1`のまま固まる」事象について、CSIノードプラグインの
ログを深掘りしたところ、原因は「kubeletの一般的な再試行バックオフ」ではなく、
**当該ノードで過去にそのボリュームのマウントが失敗した際の内部状態が、kubelet
プロセス内に居座り続けている**ことだと判明した。同じ(ノード, ボリューム)の
組み合わせでのみ100%再現し、同じノード上の別ボリュームは正常にマウントできる
(=ノード全体の障害ではない)。**この種の問題は該当ノードのkubelet再起動(=VM再起動)
でしか解消しない**ことを確認済み。

### 7a. ノード再起動前に、そのノードが「単一レプリカボリュームの唯一の生存先」になっていないか確認する

上記の根本原因調査のためノードを1台ずつ(`cordon`→`drain`→Harvester UIでVM再起動→
`uncordon`)実施したところ、**`drain`が完了していたにもかかわらず、そのノードに
単一レプリカ(`numberOfReplicas: 1`)が乗っていた別の2ボリュームが再起動と同時に
`faulted`になった**(このリポジトリの`wp-content`ボリュームは全サイトreplicas=1
がデフォルト)。

**原因**: Longhornの`instance-manager`Pod(実際のレプリカ/エンジンプロセスが
動いている場所)はPodDisruptionBudgetで保護されており、`kubectl drain`では
退避されない(`Cannot evict pod as it would violate the pod's disruption budget`
というエラーで残り続けるが、これ自体は正常。詳細は6a本文参照)。
そのため`drain`はあくまで**ワークロード(Deployment管理下のPod)の退避**にしか
効果がなく、**そのノードにしかいない単一レプリカの実データはVM再起動と一緒に
消える**。[manual-multi-env.md](manual-multi-env.md)の「ノードプール入替の
前提条件」1.が警告する内容と本質的に同じ罠が、ノードプール入替だけでなく
**単発のノード再起動でも同様に発生する**ということ。

**対処(ノード再起動前に必ず確認)**:
```bash
# 再起動対象ノードに乗っている全レプリカと、そのボリュームのnumberOfReplicasを確認
kubectl -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=VOLUME:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState \
  | grep <対象ノード名>

# 上記で出てきた各ボリュームについて、レプリカ数を確認
kubectl -n longhorn-system get volumes.longhorn.io <ボリューム名> \
  -o jsonpath='{.spec.numberOfReplicas}{"\n"}'
```
`numberOfReplicas: 1`のボリュームが対象ノードに乗っている場合、再起動前に
Longhorn UIで一時的にレプリカ数を2以上に増やして他ノードにも複製が
できてから再起動する(再起動後に1へ戻す)か、少なくとも**再起動前に
最新バックアップが存在することを確認**しておく。今回は幸い直前日のバックアップが
あったため、6.以降と同じ手順(PVC/PV削除→Volume削除・バックアップから
再作成→PV/PVC再作成)で無停止に近い形で復旧できた。
