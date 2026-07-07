# DR復元: 実践トラブルシューティング

[manual-multi-env.md](manual-multi-env.md)の「8. DR: クラスタ全損からの復元手順」を
実際に辿ると、手順書の想定通りには進まない箇所がある。ここでは2026-07-07にdev1で
実施した際に発生した詰まりどころと対処法を記録する。手順本体は上記ドキュメントに
残し、こちらは「詰まったときに読む」補足として分離している。

## 1. kubeconfig取得: 同名クラスタを再作成した場合の罠

**症状**: クラスタ削除→同名(例: `dev1`)で再作成→Rancher UIから新しいkubeconfigを
ダウンロードして`~/.kube/config`にマージしたのに、`kubectl --context dev1 get nodes`が
`the server could not find the requested resource`で失敗する。単体ファイル
(`kubectl --kubeconfig ~/.kube/dev1.yaml`)では正常に疎通できるのに、マージ後だけ壊れる。

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

KUBECONFIG=~/.kube/config:~/.kube/dev1.yaml kubectl config view --flatten > /tmp/merged-kubeconfig
mv /tmp/merged-kubeconfig ~/.kube/config
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

**症状**: `kubectl delete pvc wordpress-<site>`(wp-content用、Deployment側)を実行しても
`Terminating`のまま消えない。対応するmariadb用PVC(StatefulSet側)は正常に消える。

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
