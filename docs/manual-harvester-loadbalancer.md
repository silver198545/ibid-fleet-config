# Harvester Cloud Provider による LoadBalancer 化手順（MetalLB代替）

このクラスタ（Rancher 経由で Harvester 上にプロビジョニングされた RKE2 クラスタ）には
**Harvester Cloud Provider**（`cloudprovider.harvesterhci.io`）が組み込まれています。
このため `Service type=LoadBalancer` を作成すると、MetalLB ではなく Harvester Cloud Provider が
先に反応し、Harvester 側の `IPPool` カスタムリソースから IP を払い出そうとします。

MetalLB と Harvester Cloud Provider を同時に使うと同じ Service を取り合って競合するため、
本リポジトリでは **MetalLB を廃止し、Harvester Cloud Provider の LoadBalancer 機能に一本化**します。

## 背景: 発生したエラー

Service の Events やゲストクラスタ側の `harvester-cloud-provider` Pod のログに、以下のような
エラーが出ます。

```
Error syncing load balancer: failed to ensure load balancer: update load balancer IP of
service <namespace>/<service-name> failed, error: timeout waiting for IP address,
last error:ip is not allocated, mode: pool, message: no matched IPPool with requirement
&{Network:default/public Project: Namespace:harvester-public Cluster:<cluster-name>}
```

これは Harvester 側に、次の条件に一致する `IPPool` がまだ存在しないために発生します。

- `selector.network`: `default/public`
- `selector.scope[].namespace`: `harvester-public`
- `selector.scope[].guestCluster`: `<cluster-name>`（**クラスタを再作成すると変わる**ので、
  必ず実際に出ているエラーメッセージの `Cluster:` の値を使うこと。例: `dev1`, `dev2` など）

> `harvester-cloud-provider` 自体が正常に動作していても（Node の初期化には成功するなど）、
> IPPool が無いと Service の LoadBalancer 化だけがこのエラーで失敗し続けます。
> `kubectl -n kube-system logs -l app.kubernetes.io/name=harvester-cloud-provider` で
> 同様のログが繰り返し出ていれば、まず IPPool の有無を疑ってください。

### 既知の落とし穴: ゲストクラスタ側のクラスタ名が正しく名乗れていない

IPPoolの`selector.scope[].guestCluster`を実際のクラスタ名(例: `dev1`)に設定しているのに、
エラーメッセージの`Cluster:`がそれと違う値(典型的には`kubernetes`)になっていて
一致しない、というケースがある。これはHarvester側ではなく**ゲストクラスタ側の
`harvester-cloud-provider`(Cloud Controller Manager)が、自分の所属クラスタ名を
正しく認識できていない**ことが原因。

確認方法(ゲストクラスタ側):

```bash
kubectl -n kube-system get helmchartconfig harvester-cloud-provider -o jsonpath='{.spec.valuesContent}'
```

正常なクラスタ(移行後に新規作成したstaging/production等)では
`{"global":{"cattle":{"clusterId":"c-m-xxxxxxxx","clusterName":"<クラスタ名>"}}}`
のように`clusterName`が入っているが、`clusterId`しか入っていない(`clusterName`が
欠落している)場合、CCMはクラスタ名をKubernetesの伝統的なデフォルト値
`kubernetes`のまま名乗ってしまう。dev1は移行前の単一クラスタ時代に作られた
名残でこの`clusterName`が入っていなかった実績がある。

修正(ゲストクラスタ側):

```bash
kubectl -n kube-system patch helmchartconfig harvester-cloud-provider --type merge -p \
  '{"spec":{"valuesContent":"{\"global\":{\"cattle\":{\"clusterId\":\"<既存のclusterIdをそのまま>\",\"clusterName\":\"<正しいクラスタ名>\"}}}"}}'

# HelmのreinstallジョブがChart values Secretを更新したのを確認してから、CCMを再起動して反映させる
kubectl -n kube-system rollout restart deploy/harvester-cloud-provider
```

> この`HelmChartConfig`はRKE2のAddon機構が管理しているため、Rancher側でクラスタの
> Cloud Provider設定が再同期されるタイミングで`clusterName`が消えて再発する可能性がある。
> 再発した場合は同じ手順で当て直す。恒久対策にするなら、本来はRancherのクラスタ設定
> (Cluster Management → 対象クラスタ → Cloud Provider関連の設定)側で`clusterName`を
> 明示できないか確認するのが望ましい。

### どのクラスタが「Harvester管理クラスタ」なのか迷ったら

Rancher + Harvester 構成では、Rancher のクラスタ一覧に紛らわしいクラスタが複数存在します。

- ゲストクラスタ（例: `dev1`, `dev2`）: WordPress や Traefik が動く RKE2 クラスタ
- `local`: **Rancher 自体が動いている管理クラスタ**（Harvester ではない）。
  `harvesterconfigs` / `harvestermachines` などの CRD はあるが、
  `loadbalancer.harvesterhci.io` の IPPool はここには存在しない。
- 実際の Harvester クラスタ: 上記のどちらでもない、別名でインポートされたクラスタ。
  `kubectl api-resources | grep -i harvester` を実行して
  `loadbalancer.harvesterhci.io` 系のリソース（`ippools`, `loadbalancers` 等）が
  出てくるクラスタが本物の Harvester 管理クラスタです。

## 1. Harvester 管理クラスタに IPPool を作成する

**この手順は本リポジトリ（Fleet で管理するゲストクラスタ）ではなく、Harvester の
管理クラスタ側で実施します。**

複数のゲストクラスタ・複数の Namespace の Service から共通で使えるように、
`selector.scope` をワイルドカード（`*`）にした「グローバルプール」として作成するのが
シンプルで確実です（`namespace` や `guestCluster` を個別に指定する方式は、
クラスタを再作成すると値がズレて再度マッチしなくなるため非推奨）。

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: loadbalancer.harvesterhci.io/v1beta1
kind: IPPool
metadata:
  name: pool1
  labels:
    loadbalancer.harvesterhci.io/global-ip-pool: 'true'
spec:
  ranges:
    - rangeStart: 192.168.1.150
      rangeEnd: 192.168.1.200
      subnet: 192.168.1.0/24
      gateway: 192.168.1.1
  selector:
    network: default/public
    priority: 1
    scope:
      - project: '*'
        namespace: '*'
        guestCluster: '*'
EOF
```

> このコマンドは Harvester 管理クラスタの Kubectl Shell で実行してください（ゲストクラスタや
> Rancher の `local` クラスタではありません）。`ranges` のIP範囲・サブネット・ゲートウェイは
> 実際のネットワーク構成に合わせて調整してください（従来 MetalLB の IPAddressPool に
> 設定していた `192.168.1.150-192.168.1.200` をそのまま踏襲しています）。
>
> Harvester の UI には「Global Pool」という明示的なチェックボックスはありません。
> `spec.selector.scope` の各項目をすべて `*`（または未指定）にすると、
> `loadbalancer.harvesterhci.io/global-ip-pool: 'true'` ラベルが付き、
> 全クラスタ・全 Namespace から利用可能なグローバルプールとして扱われます。

作成後、IPPool の状態を確認します。

```bash
kubectl get ippools.loadbalancer.harvesterhci.io pool1 -o yaml
```

IPPool を作成すれば、`service.type: LoadBalancer` を指定している Service（例えば
[wordpress/fleet.yaml](../wordpress/fleet.yaml)）は追加の変更なしに外部IPが割り当てられます。

## 2. 外部IPが割り当てられたことを確認する

```bash
kubectl -n <namespace> get svc
```

期待値は `TYPE=LoadBalancer` かつ `EXTERNAL-IP` に IPPool の範囲内のアドレスが入っていることです。

## Traefik を LoadBalancer 化する必要はあるか

**WordPress は自分専用の `LoadBalancer` Service を直接持つ構成（`ingress.enabled: false`）のため、
Traefik を経由しません。** WordPress を公開するためだけであれば、Traefik を LoadBalancer 化する
必要はありません。

過去の手順（旧 `manual-metallb-and-traefik.md`）では Traefik も MetalLB で LoadBalancer 化していましたが、
これは WordPress とは無関係な、別の目的（Rancher UI や他の Ingress ベースのアプリを Traefik 経由で
公開する等）で設定されていたものです。そうした用途が無ければ、以下で元の `ClusterIP` に戻せます。

```bash
# Traefik を元の ClusterIP に戻す
kubectl -n kube-system patch svc rke2-traefik --type merge -p '{"spec":{"type":"ClusterIP"}}'

# kube-vip.io/loadbalancerIPs アノテーションを付けていた場合は削除
kubectl -n kube-system annotate svc rke2-traefik kube-vip.io/loadbalancerIPs-
```

将来的に WordPress をドメイン名 + TLS でアクセスできるようにする場合は、
`wordpress/fleet.yaml` の `ingress.enabled: true` に切り替えて Traefik 経由の Ingress に
することも選択肢になります（[manual-wordpress.md](manual-wordpress.md) の補足を参照）。
その場合は改めて Traefik を LoadBalancer 化してください。

## 補足

- MetalLB は廃止したため、[catalog-repos/chart-repos.yaml](../catalog-repos/chart-repos.yaml) から
  MetalLB の ClusterRepo、`metallb/` の Fleet バンドルは削除済みです。
- Fleet でも Traefik の Service や HelmChartConfig を管理すると、所有権競合が発生することがあります。
  Traefik 設定の管理者は 1 つに揃えてください。
