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
- 本リポジトリは一時Private化していたが、2026-07-08にpublicへ戻した(理由は
  [../docs/roadmap.md](../docs/roadmap.md)の「リポジトリのprivate化」項目参照。
  GitHub Freeの個人アカウントではprivateリポジトリでブランチ保護/rulesetsが
  使えず、CODEOWNERS必須化などの昇格ゲートが無効化されてしまうため)。
  そのため各GitRepoの認証情報(`auth-55znx` Secret、`clientSecretName`参照)は
  現時点では不要だが、Rancher UI側の設定はそのまま残してある(害はなく、将来
  再びprivate化する場合にすぐ使える)。撤去する場合はRancher UI
  (Continuous Delivery → Git Repos → Edit → Authentication)で3環境それぞれ
  「なし」に変更し、`fleet-default` namespaceの `auth-55znx` Secretを削除する。
  残す場合、PATには有効期限があるため期限切れ前にGitHub側で再発行し、Rancher UIの
  同じ画面からSecretの中身を更新すること。

  kubectlで直接作成・更新する場合(UIを使わない場合)は以下。PATをコマンドライン引数に
  直接書くとシェル履歴等に残るため、`read -s` で対話入力して変数経由で渡すこと:

  ```bash
  read -s -p "GitHub PAT: " GH_PAT && echo
  kubectl --context <rancher-local> create secret generic auth-55znx \
    --namespace fleet-default \
    --type kubernetes.io/basic-auth \
    --from-literal=username=<GitHubユーザー名> \
    --from-literal=password="$GH_PAT" \
    --dry-run=client -o yaml | kubectl --context <rancher-local> apply -f -
  unset GH_PAT
  ```
