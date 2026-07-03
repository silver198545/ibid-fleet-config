# envs/ — 環境別Fleetバンドル

dev → staging → production の3クラスタそれぞれに適用する内容を、環境ごとの
ディレクトリで管理する(単一mainブランチ+環境別ディレクトリ方式)。
Rancher側の3つのGitRepo([../fleet-bootstrap/](../fleet-bootstrap/)参照)が、
それぞれ自分の環境のディレクトリだけを監視し、`env=<環境名>` ラベルの付いた
クラスタへ適用する。

```
envs/
├── dev/
│   ├── infra/    # catalog-repos / longhorn-crd / longhorn (基盤バンドル)
│   └── sites/    # WordPressサイト(1サイト=1ディレクトリ、fleet.yaml)
├── staging/      # 同構成
└── production/   # 同構成
```

## 運用ルール

- **変更は必ずdevから入れ、staging→productionの順に昇格させる。**
  昇格は `.github/workflows/promote.yaml`(手動起動)が生成するPRのマージで行う。
  `envs/production/` 配下の変更はCODEOWNERSにより承認必須。
- 環境間の差分は `diff -r envs/staging envs/production` でいつでも確認できる。
  意図的な差分(devだけ新バージョン等)以外が出ていたら昇格漏れを疑うこと。
- サイトの追加は `scripts/new-wordpress-site.sh <env> <site>`(fleet.yaml生成)と
  `scripts/bootstrap-site-secrets.sh <site>`(対象クラスタへのSecret作成)で行う。
  手順の全体は [../docs/manual-wordpress.md](../docs/manual-wordpress.md) を参照。
- Gitでプロモーションするのは**構成のみ**(チャートバージョン、values、イメージ)。
  DBデータやwp-contentの実データは昇格しない
  ([../docs/manual-wordpress-restore.md](../docs/manual-wordpress-restore.md) の手順で個別に移送する)。

## infra/ について

dev1クラスタは従来リポジトリ直下のバンドル(`catalog-repos/`等)で運用してきたため、
`envs/dev/infra/` への移設は [../docs/manual-multi-env.md](../docs/manual-multi-env.md) の
手順に従って段階的に行う(旧バンドルの削除がLonghornのアンインストールを誘発しない
よう、`keepResources: true` の同期とリリース名の引き継ぎが必要)。
