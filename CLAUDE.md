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
3. `wordpress-<site>/` (e.g. `wordpress-web/`, optional — see "Multiple WordPress sites" below) — an
   override directory for one independent WordPress site, each a Bitnami WordPress chart with 2 web
   replicas sharing `wp-content` via a Longhorn RWX volume, a standalone (non-HA) bundled MariaDB, exposed
   via `service.type: LoadBalancer`. **Not an active Fleet bundle** — Continuous Delivery auto-applying
   changes to a namespace holding production-like data was considered too risky, so WordPress is deployed
   by hand instead. When a `wordpress-<site>/fleet.yaml` exists, it is the single source of truth for that
   site's `helm.chart`/`helm.version`/`helm.values` overrides, read by `scripts/deploy-wordpress.sh` to run
   `helm upgrade --install` by hand; when it doesn't exist, `scripts/deploy-wordpress.sh` generates
   equivalent default values itself (see below) and no directory is needed at all.

`scripts/deploy-wordpress.sh` performs the manual WordPress deploy/upgrade described above — it is the
only supported way to apply changes to any `wordpress-<site>/fleet.yaml`; editing that file and pushing
to Git has no effect on its own.

`docs/` holds manual runbooks for steps Fleet cannot automate (see below) — always check these before
changing behavior they document, and update them when the corresponding `fleet.yaml` changes.

## Multiple WordPress sites

The cluster can host more than one independent WordPress site, each with its own namespace, Helm release,
and Secrets — sites do not share data or credentials. A site's namespace/release/Secret names are always
derived mechanically from its name (`wordpress-<site>`), so a bare `scripts/deploy-wordpress.sh <site>` is
enough to stand up a standard site — no per-site directory needs to exist or be committed.

Values common to all sites (`replicaCount`, `service.type`, `persistence.*`, `mariadb.*` defaults, etc.)
live in a single shared file, `wordpress-base-values.yaml` at the repo root. A `wordpress-<site>/fleet.yaml`
is only worth creating (via `scripts/new-wordpress-site.sh <site>`) when a site's `helm.chart`/
`helm.version`/`helm.values` need to diverge from what's mechanically derivable — e.g. a chart version
pinned differently for one site, or a non-default `wordpressTablePrefix` for a site restored from another
environment's backup — since that's the only case where there's real information to keep in Git. If you
change a value that should apply to every site, edit `wordpress-base-values.yaml`, not a per-site file.

- `scripts/deploy-wordpress.sh <site> [helm options...]` — first positional arg (required) selects the
  site. Reads `wordpress-<site>/fleet.yaml` if present; otherwise synthesizes the same structure
  in a temp file using the site name and `DEFAULT_CHART_VERSION` inside the script, and never writes
  anything to the repo.
- `scripts/new-wordpress-site.sh <site>` — scaffolds a new `wordpress-<site>/fleet.yaml` from a template,
  for the divergent-config case above only.
- Full runbook for adding a site: `docs/manual-wordpress.md`.

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
  `helm.valuesFrom.secretKeyRef` (the `wordpress-<site>-mariadb-upgrade-values` secret). The latter exists
  specifically because Bitnami's mariadb subchart demands `auth.rootPassword`/`auth.password` on **Helm
  upgrade** even when `existingSecret` is set — see `docs/manual-wordpress.md` and the comments in each
  `wordpress-<site>/fleet.yaml`. If you rotate a site's mariadb passwords, this secret must be updated too
  or the next deploy fails with `PASSWORDS ERROR`.
- **Passwords are never reused across sites.** If a site's three credential Secrets don't exist yet,
  `scripts/deploy-wordpress.sh <site>` treats it as a first-time deploy and auto-generates a fresh random
  password per site (via `openssl rand`) rather than sharing one set of credentials across all sites — so
  a leak in one site's credentials can't be used against another.
- **Do not set `WORDPRESS_TABLE_PREFIX` via `extraEnvVars`.** The chart already generates that env var
  from `wordpressTablePrefix`; duplicating it causes an apply error
  (`duplicate entries for key [name="WORDPRESS_TABLE_PREFIX"]`). Use `wordpressTablePrefix` only.
- **`wp-config.php` persists on the volume and is not regenerated once created.** Changing
  `wordpressTablePrefix` (or other first-run-only settings) after initial install has no effect until the
  WordPress and MariaDB PVCs are deleted and recreated from scratch — see
  `docs/manual-wordpress-restore.md` for the safe procedure (snapshot first, scale down, delete PVCs,
  re-run `scripts/deploy-wordpress.sh <site>` to recreate them, mariadb before wordpress).
- **RWX volumes require `nfs-common` on every worker node** (Longhorn RWX is backed by an NFSv4 Share
  Manager). This isn't handled by this repo — it must be baked into the Harvester node-pool cloud-init or
  installed manually after provisioning (`docs/manual-wordpress.md`).
- Chart versions are pinned explicitly — either in a site's `fleet.yaml` (`helm.version`) if it has one,
  or via `DEFAULT_CHART_VERSION` in `scripts/deploy-wordpress.sh` otherwise. Bump deliberately, don't
  leave them floating.
- **WordPress upgrades require running `scripts/deploy-wordpress.sh <site>` by hand** — unlike
  `longhorn`/`longhorn-crd`/`catalog-repos`, Fleet does not auto-apply WordPress at all.

## Making changes

- Fleet bundle directories are self-contained: `defaultNamespace`/`targetNamespace` plus a `helm:` block
  (chart, repo, version, values) or raw manifests. When adding a new app, mirror the existing `longhorn`
  pattern (separate directory, own `fleet.yaml`, README entry describing where it fits in the apply
  order).
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
