# Harvester Cloud Provider による LoadBalancer 化手順（MetalLB代替）

このクラスタ（Rancher 経由で Harvester 上にプロビジョニングされた RKE2 クラスタ `dev1`）には
**Harvester Cloud Provider**（`cloudprovider.harvesterhci.io`）が組み込まれています。
このため `Service type=LoadBalancer` を作成すると、MetalLB ではなく Harvester Cloud Provider が
先に反応し、Harvester 側の `IPPool` カスタムリソースから IP を払い出そうとします。

MetalLB と Harvester Cloud Provider を同時に使うと同じ Service を取り合って競合するため、
本リポジトリでは **MetalLB を廃止し、Harvester Cloud Provider の LoadBalancer 機能に一本化**します。

## 背景: 発生したエラー

WordPress の Service で以下のイベントが発生しました。

```
Error syncing load balancer: failed to ensure load balancer: update load balancer IP of
service wordpress/base-infra-wordpress failed, error: timeout waiting for IP address,
last error:ip is not allocated, mode: pool, message: no matched IPPool with requirement
&{Network:default/public Project: Namespace:harvester-public Cluster:dev1}
```

これは Harvester 側に、次の条件に一致する `IPPool` がまだ存在しないために発生します。

- `selector.network`: `default/public`
- `selector.scope[].namespace`: `harvester-public`
- `selector.scope[].guestCluster`: `dev1`

## 1. Harvester 管理クラスタに IPPool を作成する

**この手順は本リポジトリ（Fleet で管理するゲストクラスタ）ではなく、Harvester の
管理クラスタ側で実施します。** Harvester UI の「Advanced settings」→ ロードバランサ関連の
IP Pool 設定からも作成できますが、YAML で直接作成する場合は以下のようになります。

```bash
cat <<'EOF' | kubectl --context harvester apply -f -
apiVersion: loadbalancer.harvesterhci.io/v1beta1
kind: IPPool
metadata:
  name: dev1-public
spec:
  description: "dev1クラスタ向けLoadBalancer用IPプール"
  ranges:
    - rangeStart: 192.168.1.150
      rangeEnd: 192.168.1.200
      subnet: 192.168.1.0/24
      gateway: 192.168.1.1
  selector:
    network: default/public
    scope:
      - namespace: harvester-public
        guestCluster: dev1
EOF
```

> `--context harvester` の部分は、Harvester 管理クラスタにアクセスできる kubeconfig
> コンテキストに読み替えてください。`ranges` のIP範囲・サブネット・ゲートウェイは
> 実際のネットワーク構成に合わせて調整してください（従来 MetalLB の IPAddressPool に
> 設定していた `192.168.1.150-192.168.1.200` をそのまま踏襲しています）。

作成後、IPPool の状態を確認します。

```bash
kubectl --context harvester get ippool dev1-public -o yaml
```

## 2. Traefik を LoadBalancer 化する

ゲストクラスタ（`dev1`）側で、これまで通り Traefik の Service を `LoadBalancer` に変更します。

```bash
kubectl -n kube-system patch svc rke2-traefik --type merge -p '{"spec":{"type":"LoadBalancer"}}'
```

固定IP（例: `192.168.1.190`）を使いたい場合は、`kube-vip.io/loadbalancerIPs` アノテーションで
希望のIPを指定できます（上記 IPPool の範囲内であること）。

```bash
kubectl -n kube-system annotate svc rke2-traefik kube-vip.io/loadbalancerIPs=192.168.1.190
```

## 3. 外部IPが割り当てられたことを確認する

```bash
kubectl -n kube-system get svc rke2-traefik
```

期待値は `TYPE=LoadBalancer` かつ `EXTERNAL-IP` に IPPool の範囲内のアドレスが入っていることです。

## 補足

- WordPress（[wordpress/fleet.yaml](../wordpress/fleet.yaml)）は `service.type: LoadBalancer` を
  指定しているだけなので、この IPPool を作成すれば追加の変更なしに IP が割り当てられます。
- MetalLB は廃止したため、[catalog-repos/chart-repos.yaml](../catalog-repos/chart-repos.yaml) から
  MetalLB の ClusterRepo、`metallb/` の Fleet バンドルは削除済みです。
- Fleet でも Traefik の Service や HelmChartConfig を管理すると、所有権競合が発生することがあります。
  Traefik 設定の管理者は 1 つに揃えてください。
