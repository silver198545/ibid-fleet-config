# WordPress (Bitnami Chart) 導入手順

[wordpress/fleet.yaml](../wordpress/fleet.yaml) は Bitnami の `wordpress` Chart を使って、
LoadBalancer (MetalLB) 経由で公開する冗長構成の WordPress を導入します。

- Web層: `replicaCount: 2` で2レプリカ構成。`wp-content` は Longhorn の
  ReadWriteMany ボリュームで全レプリカ間で共有します。
- DB層: WordPress Chart にバンドルされた MariaDB を単体構成で使用します
  （冗長化はしていません）。
- 公開: `service.type: LoadBalancer` を指定し、MetalLB の IPAddressPool から
  自動でIPを割り当てます。

前提として、以下が Fleet で導入済みであることが必要です。

- [catalog-repos/fleet.yaml](../catalog-repos/fleet.yaml)（Bitnami リポジトリ登録）
- [longhorn/fleet.yaml](../longhorn/fleet.yaml)（`longhorn` StorageClass、RWX 対応）
- [metallb/fleet.yaml](../metallb/fleet.yaml) と IPAddressPool / L2Advertisement
  （[manual-metallb-and-traefik.md](manual-metallb-and-traefik.md) 参照）

## 1. 認証情報の Secret を事前に作成する

パスワードを Git 管理下に置かないため、Fleet が Chart を適用する前に
`wordpress` Namespace へ Secret を手動で作成します。

```bash
kubectl create namespace wordpress

# WordPress管理者パスワード
kubectl -n wordpress create secret generic wordpress-credentials \
  --from-literal=wordpress-password='<管理者用の強いパスワード>'

# MariaDB (root / bn_wordpress ユーザー) パスワード
kubectl -n wordpress create secret generic wordpress-mariadb-credentials \
  --from-literal=mariadb-root-password='<root用の強いパスワード>' \
  --from-literal=mariadb-password='<bn_wordpress用の強いパスワード>'
```

## 2. Fleet で wordpress/ を適用する

Fleet の GitRepo にこのリポジトリの `wordpress/` ディレクトリを対象パスとして
追加します（Rancher UI の Continuous Delivery、または既存の GitRepo 定義に
パスを追記）。

## 3. 割り当てられた外部IPを確認する

```bash
kubectl -n wordpress get svc wordpress
```

`TYPE=LoadBalancer` かつ `EXTERNAL-IP` に MetalLB の IPAddressPool 範囲内の
アドレスが割り当てられていることを確認します。

## 4. Pod とストレージの状態を確認する

```bash
kubectl -n wordpress get pods
kubectl -n wordpress get pvc
```

- `wordpress` の PVC が `ReadWriteMany` で `Bound` になっていること
- 2つの `wordpress` Pod がいずれも `Running` になっていること
- Longhorn の Share Manager Pod が `longhorn-system` Namespace に起動していること
  （RWX ボリュームのため）

```bash
kubectl -n longhorn-system get pods -l app=longhorn-share-manager
```

## 補足

- MariaDB は単体構成のため、DB Pod自体は冗長化されていません。DB層まで冗長化したい
  場合は `bitnami/mariadb-galera` 等への切り替えを別途検討してください。
- Longhorn の ReadWriteMany ボリュームは内部的に NFS (Share Manager) を経由するため、
  通常の ReadWriteOnce ボリュームよりレイテンシが増える点に留意してください。
- WordPress の Chart バージョンは [wordpress/fleet.yaml](../wordpress/fleet.yaml) で
  明示的に固定しています。アップグレード時はバージョンを更新してください。
- 現状は次の項目を明示的に設定せず、Chart のデフォルト値のまま導入しています。
  必要になった際は `wordpress/fleet.yaml` の `helm.values` に追記してください。
  - `wordpressScheme` / `ingress.*`: 現在は LB の IP に `http` で直接アクセスする構成。
    ドメイン名でのアクセスや TLS 化をする場合は `ingress.enabled: true` と
    `ingress.hostname`、`wordpressScheme: https` を設定し、DNS でそのホスト名を
    LB の IP（または Traefik 経由）に向ける必要があります。
  - `wordpressBlogName` / `wordpressFirstName` / `wordpressLastName`:
    サイトタイトルや管理者氏名。未設定の場合は導入後に `wp-admin` の管理画面から
    変更できます。
  - `smtpHost` / `smtpPort` / `smtpProtocol` などの SMTP 設定:
    未設定だとパスワードリセット等の通知メールが送信されません。必要になったら
    SMTP サーバー情報を追加してください（認証情報は Secret 化を推奨します）。
