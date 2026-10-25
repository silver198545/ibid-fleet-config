# envs/ — 環境別Fleetバンドル

dev → staging → production の3クラスタそれぞれに適用する内容を、環境ごとの
ディレクトリで管理する(単一mainブランチ+環境別ディレクトリ方式)。
Rancher側の3つのGitRepo([../fleet-bootstrap/](../fleet-bootstrap/)参照)が、
それぞれ自分の環境のディレクトリだけを監視し、`env=<環境名>` ラベルの付いた
クラスタへ適用する。

```
envs/
├── dev/
│   ├── infra/    # 基盤バンドル(下記)
│   ├── sites/    # WordPressサイト(1サイト=1ディレクトリ、fleet.yaml)
│   ├── apps/     # WordPress以外の自作アプリ(1アプリ=1ディレクトリ、fleet.yaml)
│   └── secrets/  # サイト・アプリのSealedSecret(環境ごとの鍵で封印。環境間コピー不可)
├── staging/      # 同構成。sites/・apps/ は検証中のものだけを一時的に置く(2026-10-25に再導入)
└── production/   # 同構成
```

`infra/`の中身: `catalog-repos`(Bitnami ClusterRepo)、`longhorn-crd`・`longhorn`・
`longhorn-jobs`(定期スナップショット/バックアップ)・`longhorn-r1`(レプリカ1のStorageClass)、
`csi-driver-nfs`・`csi-driver-nfs-storageclass`(`nfs-external`)、`sealed-secrets`、
`cert-manager`・`cert-manager-issuer`、`monitoring*`(5バンドル。
[../docs/manual-monitoring.md](../docs/manual-monitoring.md))。
devのinfraの`helm.releaseName`が`base-infra-*`なのは、単一クラスタ時代のリリースを
引き継いでいるため。変更しないこと([../docs/manual-multi-env.md](../docs/manual-multi-env.md)の3.)。
stagingのinfraは軽量版で、Longhorn(`longhorn*`)を置かない。stagingのStorageClassは
`reclaimPolicy: Delete`(検証が終わったらNFS上のデータも消す)。

## 運用ルール

- **変更は必ずdevから入れ、staging → productionへ昇格させる**(本番への昇格元はstaging)。昇格の経路は種類ごとに決まっている:

  | 対象 | 昇格の方法 |
  |---|---|
  | `sites/` | `scripts/wordpress-pipeline.sh`(staging-start/upgrade → promote-production → staging-cleanup。Rundeckからも可)。中身は`promote`ワークフローが作るPR |
  | `apps/` | `scripts/update-app-image.sh deploy-staging` → `deploy-production`(Rundeckからも可)。中身は`promote`ワークフローが作るPR。アプリはstagingに常駐 |
  | `infra/` | 手動のPR(SealedSecretは環境ごとに封印し直す。stagingは軽量版) |

  `envs/production/` 配下の変更はCODEOWNERSにより承認必須。
- `sites/`・`apps/` のバンドルは**全環境で同一内容**にし、環境ごとに変わる値は
  fleet.yamlの`targetCustomizations`(とクラスタラベルのテンプレート展開)で書き分ける
  ([../docs/operations-flow.md](../docs/operations-flow.md)「環境差分の書き方」)。
  `diff -r envs/dev/sites envs/production/sites`(`apps`も同様)で出るのは昇格待ちの変更
  (`helm.version`、`plugins`、イメージタグ)だけのはず。それ以外が出たら、環境固有の値の
  直書きか昇格漏れを疑う(devにしか無いサイト・アプリは本番未展開のもの)。
- サイトの追加は [../docs/manual-wordpress.md](../docs/manual-wordpress.md)、
  アプリの追加は [../docs/manual-apps.md](../docs/manual-apps.md)。
- Gitで昇格するのは**構成のみ**。DBデータやwp-contentは昇格しない
  ([../docs/manual-wordpress-restore.md](../docs/manual-wordpress-restore.md) の手順で個別に移送する)。
