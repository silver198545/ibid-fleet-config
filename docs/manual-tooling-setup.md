# 作業端末のツールセットアップ

このリポジトリの運用作業(Fleetの状態確認、break-glass操作、Sealed Secretsの封印、
DR復元など)をローカル端末から行うために必要なCLIツールと、インストール手順・
最低限必要なアクセス権限をまとめる。Rancher local(管理クラスタ)への踏み台
(`uchida@rancher`のようなホスト)にまとめて入れておく想定。以下はUbuntu/Debian系
での手順。他ディストリビューション/macOSの場合は各ツール公式のインストール手順に
読み替える。

## 必須ツール一覧

| ツール | 用途 | 使う場面 |
|---|---|---|
| `kubectl` | 各クラスタ(local/dev1/staging1/prod1)の操作 | 全般 |
| `helm` | リリース状態の確認、break-glassデプロイ | [manual-multi-env.md](manual-multi-env.md)、`scripts/deploy-wordpress.sh` |
| `kubeseal` | Secretの封印(SealedSecrets作成) | `scripts/seal-site-secrets.sh`、`scripts/seal-monitoring-secret.sh` |
| `git` | このリポジトリの操作、ブランチ/PR作成 | 全般 |
| `gh` (GitHub CLI) | PR作成、Actions確認 | 昇格PR確認、promoteワークフロー |
| `openssl` | パスワード生成 | `scripts/seal-site-secrets.sh`、`scripts/bootstrap-site-secrets.sh` |
| `python3` | JSON整形(kubectlの出力パース) | [manual-dr-troubleshooting.md](manual-dr-troubleshooting.md)、`scripts/deploy-wordpress.sh` |
| `lzop` / `tar` / `gzip` / `split` (coreutils) | バックアップの圧縮転送 | `scripts/restore-wordpress.sh` |

上記に加え、**Rancherのユーザーアカウント**(各クラスタへのkubeconfigダウンロード権限)と
**このGitHubリポジトリへの書き込み権限**(ブランチpush・PR作成。production配下は
CODEOWNERS承認も別途必要)が必要。

## インストール手順

### kubectl

クラスタ側(RKE2)のバージョンに近いクライアントを使うこと(現状 v1.35 系。
`kubectl version -o yaml`で相互のバージョン差が±1マイナーバージョン以内かを確認する)。

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
kubectl version --client
```

### helm

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh
rm get_helm.sh
helm version
```

### kubeseal

**コントローラと同じバージョンを使うこと**(現状v0.38.4。[manual-multi-env.md](manual-multi-env.md)
6.参照)。バージョンが食い違うと封印したSecretを異なる鍵形式で解釈しようとして失敗することがある。

```bash
KUBESEAL_VERSION='0.38.4'
curl -LO "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm kubeseal "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
kubeseal --version
```

導入済みコントローラのバージョンは以下で確認できる:
```bash
kubectl -n kube-system get deploy sealed-secrets -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### git / gh / openssl / python3 / lzop

Ubuntu/Debianなら大半はaptで揃う(`python3`/`openssl`はほぼプリインストール済みのことが多い)。

```bash
sudo apt update
sudo apt install -y git gh openssl python3 lzop tar gzip coreutils
```
`gh`が上記のaptリポジトリに無い場合は[公式手順](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)
に従ってGitHub公式aptリポジトリを追加する。

インストール後、GitHubへの認証を済ませておく:
```bash
gh auth login
```

## kubeconfigの準備

各クラスタのkubeconfigはRancher UI(Cluster Management → 対象クラスタ → Download KubeConfig)
から取得し、`~/.kube/config`にマージして`--context <クラスタ名>`で使い分ける運用にしている
(このリポジトリでは `local`→`rancher`、`dev1`、`staging1`、`prod1` のcontext名で統一)。

```bash
KUBECONFIG=~/.kube/config:~/Downloads/<ダウンロードしたファイル> kubectl config view --flatten > /tmp/merged-kubeconfig
mv /tmp/merged-kubeconfig ~/.kube/config
kubectl config get-contexts
```

**クラスタを削除して同名で作り直した場合は要注意**: 古いcontext/clusterが
`~/.kube/config`に残っていると新しいkubeconfigのマージで衝突し、古い(存在しない)
クラスタを指したまま気づきにくいエラーになる。対処は
[manual-dr-troubleshooting.md](manual-dr-troubleshooting.md)の1.を参照。

## 動作確認

一通り入れたら、以下が通ることを確認する。

```bash
kubectl config get-contexts
kubectl --context rancher -n fleet-default get gitrepo
helm version
kubeseal --version
gh auth status
```
