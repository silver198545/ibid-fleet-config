# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is a **Fleet (Rancher GitOps) configuration repository** — not application code. It contains YAML
manifests that Rancher's Fleet controller applies to an RKE2 guest cluster provisioned on Harvester.
There is no build, lint, or test tooling; changes are "tested" by letting Fleet sync them to the cluster
and verifying resource state with `kubectl`.

## Repository structure

Each top-level directory is an independent Fleet bundle (a `fleet.yaml` targeting one Helm chart or one
set of raw manifests). Bundles are applied in dependency order, documented in [README.md](README.md):

1. `catalog-repos/` — registers the Bitnami `ClusterRepo` (`chart-repos.yaml`) so later bundles can pull
   charts from `https://charts.bitnami.com/bitnami`.
2. `longhorn-crd/` then `longhorn/` — installs Longhorn CRDs, then the Longhorn chart itself
   (from `https://charts.rancher.io`), providing the `longhorn` StorageClass including ReadWriteMany (RWX)
   support.
3. `wordpress/` — Bitnami WordPress chart, 2 web replicas sharing `wp-content` via a Longhorn RWX volume,
   with a standalone (non-HA) bundled MariaDB, exposed via `service.type: LoadBalancer`. **Not an active
   Fleet bundle** — it was deliberately removed from the `base-infra` GitRepo's `spec.paths` (see
   `docs/manual-wordpress-fleet-cutover.md`) because Continuous Delivery auto-applying changes to a
   namespace holding production-like data was considered too risky. `wordpress/fleet.yaml` is kept only
   as the single source of truth for `helm.chart`/`helm.version`/`helm.values`, read by
   `scripts/deploy-wordpress.sh` to run `helm upgrade --install` by hand. `wordpress-web/` is a second,
   independent WordPress site that follows the same pattern (own namespace/release/Secrets, own
   `fleet.yaml`) — see "Multiple WordPress sites" below.

`scripts/deploy-wordpress.sh` performs the manual WordPress deploy/upgrade described above — it is the
only supported way to apply changes to `wordpress/fleet.yaml` (or any `wordpress-<site>/fleet.yaml`);
editing that file and pushing to Git has no effect on its own.

`docs/` holds manual runbooks for steps Fleet cannot automate (see below) — always check these before
changing behavior they document, and update them when the corresponding `fleet.yaml` changes.

## Multiple WordPress sites

The cluster can host more than one independent WordPress site. Each site is its own directory
(`wordpress/` for the first site, `wordpress-<site>/` for additional ones, e.g. `wordpress-web/`) with
its own `fleet.yaml`, namespace, Helm release, and Secrets — sites do not share data or credentials.

Values common to all sites (`replicaCount`, `service.type`, `persistence.*`, `mariadb.*` defaults, etc.)
live in a single shared file, `wordpress-base-values.yaml` at the repo root, to avoid duplicating them in
every site's `fleet.yaml`. `scripts/deploy-wordpress.sh` passes `wordpress-base-values.yaml` to `helm -f`
before the site's own `fleet.yaml` values, so each `wordpress-<site>/fleet.yaml` should only contain
values that differ from the shared defaults (Secret names, and any site-specific quirks like
`wordpressTablePrefix`/`wordpressSkipInstall` on the first site — see its comments for why those exist).
If you change a value that should apply to every site, edit `wordpress-base-values.yaml`, not each site
individually.

- `scripts/deploy-wordpress.sh [site] [helm options...]` — first positional arg selects the site
  (`wordpress-<site>/fleet.yaml`); omitted or `wordpress` means the first site, preserving its legacy
  namespace/release name (`wordpress`/`base-infra-wordpress`) for backward compatibility.
- `scripts/new-wordpress-site.sh <site>` — scaffolds a new `wordpress-<site>/fleet.yaml` from a template.
- Full runbook for adding a site: `docs/manual-wordpress-multi-site.md`.
- The first site's `fleet.yaml` also sets `persistence.existingClaim` (via a `--set` in
  `deploy-wordpress.sh`, not in `fleet.yaml`) to bind to the PVC created back when it was Fleet-managed.
  This is specific to that one site's migration history — do not add it for new sites, since they have no
  pre-existing PVC and the chart needs to create one.

## Key architectural facts to know before editing

- **LoadBalancer IPs come from the Harvester Cloud Provider, not MetalLB.** MetalLB was deliberately
  removed (see `docs/manual-harvester-loadbalancer.md`) because both controllers race to claim
  `type: LoadBalancer` Services. IP allocation depends on an `IPPool` (`loadbalancer.harvesterhci.io`)
  that must exist on the **Harvester management cluster** (not this guest cluster, not Rancher's `local`
  cluster) — that IPPool is outside this repo's scope.
- **WordPress bypasses Traefik entirely** — it uses its own `LoadBalancer` Service
  (`ingress.enabled: false` by default), so Traefik does not need to be LoadBalancer-typed unless another
  app requires Ingress.
- **Never put passwords in `fleet.yaml` / Git.** WordPress and MariaDB credentials are injected via
  pre-created Kubernetes Secrets referenced through `existingSecret` (WordPress/MariaDB auth) and
  `helm.valuesFrom.secretKeyRef` (the `wordpress-mariadb-upgrade-values` secret). The latter exists
  specifically because Bitnami's mariadb subchart demands `auth.rootPassword`/`auth.password` on **Helm
  upgrade** even when `existingSecret` is set — see `docs/manual-wordpress.md` and the comments in
  `wordpress/fleet.yaml`. If you rotate the mariadb passwords, this secret must be updated too or the
  next Fleet sync fails with `PASSWORDS ERROR`.
- **Do not set `WORDPRESS_TABLE_PREFIX` via `extraEnvVars`.** The chart already generates that env var
  from `wordpressTablePrefix`; duplicating it causes a Fleet apply error
  (`duplicate entries for key [name="WORDPRESS_TABLE_PREFIX"]`). Use `wordpressTablePrefix` only.
- **`wp-config.php` persists on the volume and is not regenerated once created.** Changing
  `wordpressTablePrefix` (or other first-run-only settings) after initial install has no effect until the
  WordPress and MariaDB PVCs are deleted and recreated from scratch — see
  `docs/manual-wordpress-restore.md` for the safe procedure (snapshot first, scale down, delete PVCs,
  scale back up mariadb before wordpress).
- **RWX volumes require `nfs-common` on every worker node** (Longhorn RWX is backed by an NFSv4 Share
  Manager). This isn't handled by this repo — it must be baked into the Harvester node-pool cloud-init or
  installed manually after provisioning (`docs/manual-wordpress.md`).
- Chart versions are pinned explicitly in each `fleet.yaml` (`helm.version`) — bump deliberately, don't
  leave them floating.
- **WordPress upgrades require running `scripts/deploy-wordpress.sh` by hand** after editing
  `wordpress/fleet.yaml` — unlike `longhorn`/`longhorn-crd`/`catalog-repos`, Fleet does not auto-apply
  this bundle (see above).

## Making changes

- Fleet bundle directories are self-contained: `defaultNamespace`/`targetNamespace` plus a `helm:` block
  (chart, repo, version, values) or raw manifests. When adding a new app, mirror the existing
  `longhorn`/`wordpress` pattern (separate directory, own `fleet.yaml`, README entry describing where it
  fits in the apply order).
- If a change requires a manual, non-Git-tracked step (creating a Secret, creating an IPPool on the
  Harvester management cluster, installing an OS package on nodes), document it under `docs/` and link it
  from `README.md`, following the existing runbook style.

## Commit convention

**All commit messages must be written in Japanese**, format `種類: 日本語での変更内容の説明`.

Types: `feat` (機能追加), `fix` (修正), `perf` (パフォーマンス), `refactor` (リファクタリング),
`docs` (ドキュメント), `style` (スタイル), `test` (テスト), `chore` (雑務)

Examples:
- `feat: ケージ移動システムに体重測定機能を追加`
- `fix: カメラステータス更新時の競合状態を解決`
