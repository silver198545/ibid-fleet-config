# ibid-fleet-config

## 構成

- `catalog-repos/`: Rancher のカタログリポジトリ定義（MetalLB、Bitnami）
- `longhorn-crd/`: Rancher Charts から Longhorn CRD を導入する Fleet バンドル
- `longhorn/`: Rancher Charts から Longhorn 本体を導入する Fleet バンドル
- `metallb/`: MetalLB Chart を導入する Fleet バンドル
- `docs/manual-metallb-and-traefik.md`: MetalLB 手動導入と Traefik LB 化の手順書

## 想定フロー

1. Fleet で `catalog-repos/` を適用して、Chart リポジトリを追加します。
2. Fleet で `longhorn-crd/` を適用して、Longhorn CRD を導入します。
3. Fleet で `longhorn/` を適用して、Longhorn 本体を導入します。
4. Fleet で `metallb/` を適用して、MetalLB を導入します。
5. 必要に応じて [docs/manual-metallb-and-traefik.md](docs/manual-metallb-and-traefik.md) の手動手順を使います。
6. 後続の WordPress 導入では Bitnami リポジトリを利用します。
