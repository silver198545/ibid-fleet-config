# MetalLB 手動導入と Traefik LB 化手順

この手順では、まず MetalLB を手動で導入し、その後 Traefik を固定IP付きの LoadBalancer として公開します。

## 1. MetalLB を手動で導入する

```bash
kubectl create namespace metallb-system
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb.yaml
```

## 2. IPAddressPool と L2Advertisement を作成する

以下のマニフェストをそのまま適用します。

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.150-192.168.1.200
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
EOF
```

## 3. MetalLB の状態を確認する

```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspool
kubectl -n metallb-system get l2advertisement
```

## 4. Traefik Service を手動で LoadBalancer 化する

```bash
kubectl -n kube-system patch svc rke2-traefik --type merge -p '{"spec":{"type":"LoadBalancer","loadBalancerIP":"192.168.1.190"}}'
```

## 5. Traefik に外部IPが割り当てられたことを確認する

```bash
kubectl -n kube-system get svc rke2-traefik
```

期待値は `TYPE=LoadBalancer` かつ `EXTERNAL-IP=192.168.1.190` です。

## 補足

- Fleet でも Traefik の Service や HelmChartConfig を管理すると、所有権競合が発生することがあります。Traefik 設定の管理者は 1 つに揃えてください。
- [catalog-repos/chart-repos.yaml](catalog-repos/chart-repos.yaml) では Rancher に MetalLB と Bitnami のリポジトリを追加します。
- [longhorn/fleet.yaml](longhorn/fleet.yaml) では Rancher Charts から Longhorn を Fleet 経由で導入します。
