# ibid-fleet-config

## Contents

- `catalog-repos/`: Rancher catalog repositories (MetalLB, Bitnami)
- `longhorn/`: Fleet bundle to install Longhorn from Rancher charts
- `docs/manual-metallb-and-traefik.md`: Manual MetalLB install + Traefik LB steps

## Intended flow

1. Apply `catalog-repos/` with Fleet to add chart repositories.
2. Apply `longhorn/` with Fleet to install Longhorn.
3. Install MetalLB manually and configure LB with the procedure in `docs/manual-metallb-and-traefik.md`.
4. Use Bitnami repository for later WordPress installation.
