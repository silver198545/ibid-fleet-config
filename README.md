# ibid-fleet-config

## Contents

- `catalog-repos/`: Rancher catalog repositories (MetalLB, Bitnami)
- `longhorn-crd/`: Fleet bundle to install Longhorn CRDs from Rancher charts
- `longhorn/`: Fleet bundle to install Longhorn from Rancher charts
- `metallb/`: Fleet bundle to install MetalLB from MetalLB chart repo
- `docs/manual-metallb-and-traefik.md`: Manual MetalLB install + Traefik LB steps

## Intended flow

1. Apply `catalog-repos/` with Fleet to add chart repositories.
2. Apply `longhorn-crd/` with Fleet to install Longhorn CRDs.
3. Apply `longhorn/` with Fleet to install Longhorn.
4. Apply `metallb/` with Fleet to install MetalLB (same style as Longhorn).
5. If needed, use the manual fallback in `docs/manual-metallb-and-traefik.md`.
6. Use Bitnami repository for later WordPress installation.
