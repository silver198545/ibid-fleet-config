# トラブルシューティング

まず全体を見る:

```bash
kubectl --context local -n fleet-default get gitrepo                              # 2つとも Ready、COMMIT が main の最新
kubectl --context local -n fleet-default get bundles | grep -v -E '1/1|2/2'       # 何も出なければ全バンドル正常
kubectl --context <dev1|prod1> get pods -A | grep -v -E 'Running|Completed'       # 動いていないPod
```

Rancher UI の Continuous Delivery でも同じものが見られる。

---

## サイトが 500 を返す

```bash
kubectl --context <ctx> -n wordpress-<site> logs deploy/wordpress-<site> --since=10m | grep -i 'php fatal'
```

- **プラグインの更新直後**: 数秒で直る(ファイルの入れ替え中)。1分以上続くときは、エラーに出ているプラグインを
  devの `fleet.yaml` で前の版に戻してPR → 本番へ昇格
- **DB接続エラー**(`Error establishing a database connection`): 下の「MariaDBが起動しない」へ

## 新しいサイト・アプリにつながらない(curl で 000、名前が引けない)

証明書の発行中(作ってから数分)は、一時的に名前が引けないことがある。DNSは触らずに待つ。

```bash
kubectl --context <ctx> -n <namespace> get certificate     # READY が True になるまで待つ
sudo resolvectl flush-caches                               # 作業端末のDNSキャッシュを消す
```

10分以上 True にならないとき: [manual-cert-manager-freeipa-acme.md](../manual-cert-manager-freeipa-acme.md)

## Fleetのバンドルがエラー(ErrApplied / NotReady)

```bash
kubectl --context local -n fleet-default get bundles | grep <名前>     # 右端にエラー内容が出る
```

| エラーの内容 | 対処 |
|---|---|
| `secrets "…" not found`(サイトを作った直後) | Secretの作成待ち。数分で直る |
| `PASSWORDS ERROR` | MariaDBのパスワードとSecretが合っていない。[manual-wordpress.md](../manual-wordpress.md)「1.」のパスワード変更の注意 |
| `field is immutable`(Job) | チャートのJob定義を変えたのに名前が変わっていない。`templates/plugin-sync-job.yaml` の `$jobRev` を上げてチャートを再公開 |
| GitRepo 自体がエラー(`authentication required` 等) | Fleetがリポジトリを読めない。下の「GitHubのトークンの期限切れ」 |

## WordPressのPodが再起動を繰り返す

```bash
kubectl --context <ctx> -n wordpress-<site> logs deploy/wordpress-<site> --previous | tail -20
```

- `Could not connect to the database`: 作ったばかりのサイトなら1〜2回は正常(DBの準備待ち)。続くならMariaDBを見る

## MariaDBが起動しない

```bash
kubectl --context <ctx> -n wordpress-<site> get pod wordpress-<site>-mariadb-0
kubectl --context <ctx> -n wordpress-<site> logs wordpress-<site>-mariadb-0 -c mariadb | tail -30
```

- 作ったばかり: 初回の初期化は最大10分かかる。待つ
- MariaDBのイメージを更新した後: アップグレードが済んだか確認する(イメージの版と同じならよい)
  ```bash
  kubectl --context <ctx> -n wordpress-<site> exec wordpress-<site>-mariadb-0 -c mariadb -- cat /bitnami/mariadb/data/mariadb_upgrade_info
  ```
- データが壊れた・戻したい: バックアップから戻す([manual-wordpress-restore.md](../manual-wordpress-restore.md)、`scripts/restore-wordpress.sh`)

## アプリが ImagePullBackOff

```bash
kubectl --context <ctx> -n <app> describe pod <pod> | grep -A3 -i 'failed'
```

- `failed to fetch oauth token` / `401` / `403`: GHCRのpull用PATの期限切れ。新しいPATで **dev・本番の両方** のSecretを作り直す
  ([app-new.md](app-new.md) 手順2-3 のコマンド。本番は `--context prod1`、出力先 `envs/production/secrets/<app>.yaml`)
- `not found`: そのタグのイメージが無い。Actions の `build-<app>-image` が成功しているか見る

## auto-update / promote / validate のワークフローが失敗した

GitHub の Actions で失敗した実行を開き、赤くなったステップのログを見る。

| ログの内容 | 対処 |
|---|---|
| `Bad credentials` / `401`、`Resource not accessible` | `PROMOTE_TOKEN`(PAT)の期限切れか権限不足。PATを作り直して Settings → Secrets → Actions で更新 |
| validate の `actionlint` / `shellcheck` | ワークフローの書き方の誤り。ログの行番号の箇所を直す |
| validate の必須項目・パスワード検出 | サイトの `fleet.yaml` の書き方。ログに出たファイルを直す |

## GitHubのトークンの期限切れ(要予定管理)

| トークン | 使い道 | 期限 | 切れると |
|---|---|---|---|
| Fleetの `auth-55znx`(Rancher local) | Fleetがリポジトリを読む | **2027-01-05** | dev・本番とも更新が止まる |
| `PROMOTE_TOKEN`(Actions Secrets) | 昇格PR・自動更新 | 発行時に控えた日 | promote / auto-update が失敗 |
| GHCRのpull用PAT(アプリごとのSealedSecret) | 非公開イメージの取得 | 発行時に控えた日 | Podの移動時に ImagePullBackOff |

`auth-55znx` の期限の確かめ方(トークンは表示されない):

```bash
tok="$(kubectl --context local -n fleet-default get secret auth-55znx -o jsonpath='{.data.password}' | base64 -d)"
curl -sI -H "Authorization: token $tok" https://api.github.com/repos/silver198545/ibid-fleet-config | grep -i expiration; unset tok
```

更新: 新しいPATを作り、Rancher UI の Continuous Delivery → Git Repos の認証情報、または `auth-55znx` の `password` を書き換える。

## PVC が Terminating のまま / PV が Released のまま残る

- PVCが消えない: [manual-dr-troubleshooting.md](../manual-dr-troubleshooting.md) 4.・6b.
- MariaDB(`harvester`)のPVが `Released` で残る: [roadmap.md](../roadmap.md) 項目8 の手順

## ノード・クラスタの障害

- ノードが NotReady、etcd の遅延、時刻ずれ: [manual-multi-env.md](../manual-multi-env.md)、[manual-node-ntp.md](../manual-node-ntp.md)
- クラスタを作り直す・復元する: [manual-multi-env.md](../manual-multi-env.md)「2.」「8.」、[manual-dr-troubleshooting.md](../manual-dr-troubleshooting.md)
- **ノードプールの入れ替え・ディスク拡張の前に、Longhornのボリュームが全部 attached か必ず確認する**(detached のボリュームが消えた事故あり)

## 緊急時(Gitを通さずに直したい)

原則しない。どうしても必要なときは [manual-multi-env.md](../manual-multi-env.md)「7. break-glass」に従う
(本番の GitRepo を一時停止してから `scripts/deploy-wordpress.sh`)。直した内容は必ず後でGitに反映する。
