# WordPressをFleet(Continuous Delivery)管理から手動運用に切り替える手順

これは、Fleetの GitRepo `base-infra`（`fleet-default` namespace、対象クラスタ `dev1`）が
自動デプロイしているWordPressを、Fleetの追跡対象から外して
[scripts/deploy-wordpress.sh](../scripts/deploy-wordpress.sh) による手動デプロイに切り替えるための
**一度きり**の手順です。

対象の `wordpress` namespaceには本番相当のDBとwp-contentが既に入っているため、
必ず本手順の順番（安全対策 → 保護 → Fleetから除外 → 引き継ぎ確認）を守ってください。

## 0. 前提確認

```bash
kubectl get gitrepo base-infra -n fleet-default -o jsonpath='{.spec.paths}{"\n"}'
```

`["longhorn-crd","longhorn","catalog-repos","wordpress"]` のように `wordpress` が含まれていることを確認します。

## 1. Longhornでスナップショットを取得する

`wordpress` namespaceの以下2つのPVCについて、Longhorn UIでスナップショットを1つずつ取得します
（[manual-wordpress-restore.md](manual-wordpress-restore.md) の手順1と同様、切り戻せるようにするための保険です）。

```bash
kubectl -n wordpress get pvc
# base-infra-wordpress                  (wp-content用, ReadWriteMany)
# data-base-infra-wordpress-mariadb-0   (mariadb用, ReadWriteOnce)
```

## 2. PVCをHelm/Fleetの誤削除から保護する

FleetはWordPressを実体としては本物のHelmリリースとして管理しています。`wordpress`をFleetの追跡対象から
外すと、Fleetの内部処理でリリースがuninstallされ、関連リソース（PVCを含む）が削除される可能性があります。
念のため、両PVCに `helm.sh/resource-policy: keep` を付けておきます
（Helmの標準的な仕組みで、このannotationが付いたリソースはuninstall/upgrade時の削除対象から除外されます）。

```bash
kubectl -n wordpress annotate pvc base-infra-wordpress helm.sh/resource-policy=keep --overwrite
kubectl -n wordpress annotate pvc data-base-infra-wordpress-mariadb-0 helm.sh/resource-policy=keep --overwrite
```

## 3. Fleetの追跡対象(`paths`)から`wordpress`を外す

**Rancher UIから行う場合(推奨):**

1. Rancher UIで対象クラスタ(`dev1`)の Continuous Delivery を開く。
2. GitRepo `base-infra` を編集し、`Paths` から `wordpress` を削除して保存する。

**kubectlから行う場合(参考):**

```bash
# 現在のインデックスを確認してから該当箇所を除去する
kubectl get gitrepo base-infra -n fleet-default -o jsonpath='{.spec.paths}{"\n"}'
kubectl patch gitrepo base-infra -n fleet-default --type=json \
  -p='[{"op":"remove","path":"/spec/paths/3"}]'
```

（`/spec/paths/3` は本ドキュメント作成時点でのインデックスです。事前に`paths`配列を確認し、
`wordpress`の実際の位置に置き換えてください。）

## 4. Fleet側の反映を確認する

```bash
# Bundle base-infra-wordpress が消えていること
kubectl get bundle base-infra-wordpress -n fleet-default

# wordpress namespaceのリソース状態を確認。
# Deployment/Service等が消えていても、PVCさえ残っていれば手順6で復旧できる。
kubectl -n wordpress get deploy,sts,svc,pvc
```

PVCが2つとも残っていることを必ず確認してください。もし消えてしまっていた場合は、
手順1で取得したLonghornスナップショットから復元してください
（[manual-wordpress-restore.md](manual-wordpress-restore.md) 参照）。

## 5. 既存のHelmリリース履歴が残っていることを確認する

```bash
helm history base-infra-wordpress -n wordpress
```

Fleetが作成したリビジョン履歴がそのまま表示されれば、CLIからの引き継ぎが可能な状態です。

## 6. 手動デプロイスクリプトで引き継ぐ

```bash
cd ibid-fleet-config
./scripts/deploy-wordpress.sh
```

実行後、`helm history base-infra-wordpress -n wordpress` でリビジョンが1つ増えていること
（Fleetからの引き継ぎが完了したこと）を確認します。

## 7. 動作確認

```bash
kubectl -n wordpress get pods
kubectl -n wordpress get svc
```

- 2つの`wordpress` Podが`Running`になっていること
- `LoadBalancer` Serviceの`EXTERNAL-IP`にブラウザでアクセスし、サイトが表示されること
- `wp-content`（メディア等）が以前のまま表示されること

## 以後の運用

WordPressの設定変更・バージョンアップは、[wordpress/fleet.yaml](../wordpress/fleet.yaml) の
`helm.values`（およびSecret作成手順は[manual-wordpress.md](manual-wordpress.md)のまま）を編集した上で、
Gitにコミット後（履歴管理のため）`scripts/deploy-wordpress.sh` を再実行してください。
Fleetの`paths`には戻さないため、Git pushしただけでは反映されません。
