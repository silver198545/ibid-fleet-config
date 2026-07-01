# Manual MetalLB and Traefik LB setup

This procedure is for manually installing MetalLB first, then exposing Traefik with a fixed external IP.

## 1. Install MetalLB manually

```bash
kubectl create namespace metallb-system
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb.yaml
```

## 2. Create IPAddressPool and L2Advertisement

Apply inline manifests:

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

## 3. Verify MetalLB is healthy

```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspool
kubectl -n metallb-system get l2advertisement
```

## 4. Manually expose Traefik service as LoadBalancer

```bash
kubectl -n kube-system patch svc rke2-traefik --type merge -p '{"spec":{"type":"LoadBalancer","loadBalancerIP":"192.168.1.190"}}'
```

## 5. Verify Traefik external IP assignment

```bash
kubectl -n kube-system get svc rke2-traefik
```

Expected: `TYPE=LoadBalancer` and `EXTERNAL-IP=192.168.1.190`.

## Notes

- If Fleet also manages Traefik Service/HelmChartConfig, ownership conflicts can occur. Keep one owner for Traefik config.
- `catalog-repos/chart-repos.yaml` adds MetalLB and Bitnami repos to Rancher catalogs.
- `longhorn/fleet.yaml` installs Longhorn from Rancher charts with Fleet.
