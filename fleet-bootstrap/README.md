# fleet-bootstrap/ — 環境別GitRepo定義(手動適用)

Rancherの **localクラスタ**(Continuous Deliveryの管理側)の `fleet-default`
namespaceへ手動で適用するGitRepo定義。**このディレクトリ自体はFleetの適用対象外**
([.fleetignore](../.fleetignore)で除外)で、あくまで「Rancher側に何を作ったか」を
Gitに記録しておくためのコピー。

適用はRancher UI(Continuous Delivery → Git Repos)または localクラスタ向けの
kubeconfigで行う:

```bash
kubectl --context <rancher-local> apply -f fleet-bootstrap/gitrepo-dev.yaml
```

前提:

- 対象クラスタにRancher上で `env=dev|staging|production` のラベルが付与済みであること
- staging / production のGitRepoは、対応するクラスタを構築しラベル付けしてから適用すること
  (先に適用しても対象0台で待機するだけだが、紛らわしいので推奨しない)
- 旧GitRepo(`base-infra`)からの切り替え手順は
  [../docs/manual-multi-env.md](../docs/manual-multi-env.md) を参照
