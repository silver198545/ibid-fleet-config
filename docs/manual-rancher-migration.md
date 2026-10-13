# Rancher管理サーバのDocker版 → K3s + Helm版への移行とアップグレード

Rancher管理サーバ(`rancher.ibid.lan` / `192.168.1.149`)は、2026-10-13までは`docker run rancher/rancher`の
単一コンテナで動いていた。Docker版は公式には開発・テスト用の扱いで、アップグレードは
「コンテナを止めてボリュームを引き継ぐ」以外の手段がなく、切り戻しはtarの書き戻しだけになる。
本書は、**同じホスト上で単一ノードのK3sに移し、RancherをHelmで管理する**ための手順をまとめる。

**2026-10-13に移行済み。** 今はこのホストのK3s(v1.35.4+k3s1)上で、Helmリリース`rancher`
(v2.14.2、同日に2.14.1から更新)として動いている。実施の記録は[11. 実施記録](#11-実施記録2026-10-13)。
今後のアップグレードは[8.](#8-フェーズ3-アップグレード例-2141--2142)、日常の運用は[9.](#9-移行後の運用)を見る。

移行後の操作は、このホスト上で次のコマンドを使う(K3sの管理者kubeconfigを`~/.kube`へコピーしない)。

```bash
K="sudo k3s kubectl"
H="sudo helm --kubeconfig /etc/rancher/k3s/k3s.yaml"
```

各下流クラスタへの`kubectl --context local|dev1|prod1|harvester1`は、移行前と同じくRancher経由で使える。

## 1. 方針

| 決めたこと | 理由 |
|---|---|
| 移行先は**同じホスト**上の単一ノードK3s | server-urlがこのホストのIP(`https://192.168.1.149`)なので、IPを変えなければ下流のagentは何もしなくてよい。RKE2ではなくK3sにするのはメモリの余裕が無いから(Docker版も中身は埋め込みK3sなので、使用量はほぼ変わらない) |
| **今のCA(`dynamiclistener-ca`)を引き継ぐ** | 下流agentは`agent-tls-mode: strict`でこのCAを固定で信頼している。Helm版をデフォルトで入れるとCAが新しくなり、dev1/prod1/harvester1の全agentが接続できなくなる |
| **移行はv2.14.1のまま**行い、アップグレードは移行が終わってから | 失敗したときの原因を切り分けるため。切り戻しも楽になる |
| server-urlはIPのまま変えない | ホスト名に変えると全クラスタのagent登録をやり直すことになる。必要なら別の作業として扱う |
| Dockerコンテナは削除せず停止しておくだけにする | そのまま切り戻し手段になる(→ [7. 切り戻し](#7-切り戻し)) |

### 移行前の状態(2026-10-13時点)

| 項目 | 値 |
|---|---|
| Rancher | v2.14.1(Docker、このホストで1コンテナ) |
| 埋め込みK3s | v1.35.4+k3s1 |
| server-url | `https://192.168.1.149` |
| CA | `tls-rancher` Secret(cattle-system)。`O=dynamiclistener-org, CN=dynamiclistener-ca@1781590233`、期限2036-06-13、SHA256 `22:46:E2:0A:…:77:71:88`(`cacerts` settingと一致) |
| サーバ証明書のSAN | `192.168.1.149`、`rancher.brc.riken.jp`、`localhost`、`rancher.cattle-system`など(dynamiclistenerが自動で更新している) |
| agent-tls-mode | strict(デフォルト) |
| 管理しているクラスタ | local、dev1(`c-m-62994569`)、prod1(`c-m-sm8lnxt7`)、harvester1(`c-rqrxh`) |
| Harvester | v1.8.2(サポートマトリクス上の対応Rancherは2.14.1 / 2.14.2) |
| 公開経路 | ユーザーは外部プロキシ(`rancher.brc.riken.jp`、プロキシ側の証明書)経由でアクセスする。**下流のagentとkubeconfigは`192.168.1.149`に直接つなぐ** |
| ホスト | Ubuntu 24.04、16コア、メモリ15GiB、ディスク空き約18GB |

## 2. 事前準備(移行日の前に済ませる)

1. **バージョンの組み合わせを確認する。**
   [Rancher 2.14.1のサポートマトリクス](https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/)で、
   localクラスタとして使うK3sのバージョンがサポート対象かを確認する。今の埋め込みK3sと同じ
   `v1.35.4+k3s1`を第一候補にする。
2. **今のコンテナの起動オプションを記録する。** 切り戻しで同じ形で起動し直すため、必ず残す。
   ```bash
   docker ps --filter ancestor=rancher/rancher:v2.14.1
   RANCHER_CONTAINER=<上で確認したコンテナ名>
   docker inspect "$RANCHER_CONTAINER" > ~/rancher-migration/docker-inspect.json
   docker inspect -f '{{json .Mounts}} {{json .HostConfig.PortBindings}} {{json .Config.Env}}' "$RANCHER_CONTAINER"
   ```
   ボリューム(`/var/lib/rancher`がnamed volumeかbind mountか)、ポート(80/443)、`--privileged`、
   独自の環境変数(`CATTLE_*`、`AUDIT_*`)を確認する。独自の環境変数があれば、Helmのvaluesに
   置き換える必要がある。
3. **ディスクの空きを確認する。** `/var/lib/rancher`のtar、rancher-backupのファイル、K3s本体と
   イメージで数GB〜10GB程度を使う。空きが18GBしかないので、先に量っておく。
   ```bash
   docker system df -v | grep -A3 -i volume
   ```
4. **Rancherを通らないkubeconfigを用意しておく(推奨)。** 今の`dev1`/`prod1`/`harvester1`の
   contextはすべて`https://192.168.1.149/k8s/clusters/...`経由なので、作業中はRancherと一緒に
   使えなくなる。agentの再接続を確認したり、障害時に対応したりできるよう、各クラスタの
   control-planeノードから`/etc/rancher/rke2/rke2.yaml`を取得し、`server:`をノードのIPに書き換えて
   別名で保存しておく。2026-10-13に、`kubectl debug node`で取得して`~/.kube/<クラスタ>-direct.yaml`
   (権限600)に保存した。`rancher/shell`は非rootで動くので、`--custom`で`runAsUser: 0`を指定する
   必要がある。管理者権限の認証情報なので、Claude Codeには実行させず、運用者が自分で実行した。
   ```bash
   echo '{"securityContext":{"runAsUser":0,"runAsNonRoot":false}}' > root.json
   kubectl --context dev1 -n default debug node/<control-planeノード> --image=rancher/shell:v0.7.0 \
     --profile=sysadmin --custom=root.json -- sleep 300
   kubectl --context dev1 -n default exec <node-debugger-…> -- cat /host/etc/rancher/rke2/rke2.yaml \
     | sed 's#https://127.0.0.1:6443#https://<ノードIP>:6443#' > ~/.kube/dev1-direct.yaml
   kubectl --context dev1 -n default delete pod <node-debugger-…>
   ```
   Harvesterも同じ方法で、control-planeノード(例: hrvest2 `192.168.1.55`)から取得できる。
5. **作業時間帯を決めて周知する。** Rancher UIとFleetの同期は30〜60分ほど止まる。下流クラスタ上の
   ワークロード(WordPressやアプリ)は止まらない。作業中はPRのマージ(特に`envs/production/`)を
   止める。マージしても、移行後にFleetが追いつけば反映はされる。
6. **作業用ディレクトリを作る。** CAの秘密鍵を置くので、権限を絞る。
   ```bash
   install -d -m 700 ~/rancher-migration
   ```

## 3. フェーズ1: 今のDocker版にrancher-backupを入れる 【済(2026-10-13)】

移行とは別に先行して導入した。以下は実施した手順。

| 項目 | 値 |
|---|---|
| chart | `rancher-backup` / `rancher-backup-crd` 109.0.9+up10.0.10(`rancher-charts`のrelease-v2.14で最新、Rancher 2.14対応) |
| Helmリリース | local の `cattle-resources-system` に `rancher-backup-crd`、`rancher-backup` |
| 保存先 | 静的PV `rancher-backup-pv`(hostPath `/var/lib/rancher/rancher-backups`、10Gi、Retain) |
| 定期バックアップ | `Backup/daily`: `rancher-resource-set-full`、毎日03:00 JST(`0 18 * * *`、cronはUTC)、14世代保持 |
| 1回分のサイズ | 約17MB(2026-10-13時点) |
| 二次コピー | Bacula(本リポジトリの管理外)。ホスト側のRancherのボリュームごと取得している |

Docker版のlocalクラスタにはStorageClassが無いため、**コンテナ内のhostPathを使う静的PV**を
保存先にした。localクラスタのノードはRancherのコンテナそのものなので、このhostPathはコンテナ内の
パスになる。`/var/lib/rancher`配下なので、データはRancherのボリュームに残る。

```bash
kubectl --context local apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: rancher-backup-pv
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /var/lib/rancher/rancher-backups
    type: DirectoryOrCreate
EOF

# chartの版は、rancher-charts(ClusterRepo)のindexで catalog.cattle.io/rancher-version が今のRancherに合うものを選ぶ
helm pull rancher-backup-crd --repo https://charts.rancher.io --version 109.0.9+up10.0.10
helm pull rancher-backup     --repo https://charts.rancher.io --version 109.0.9+up10.0.10
helm --kube-context local install rancher-backup-crd rancher-backup-crd-109.0.9+up10.0.10.tgz \
  -n cattle-resources-system --create-namespace --wait
helm --kube-context local install rancher-backup rancher-backup-109.0.9+up10.0.10.tgz \
  -n cattle-resources-system --wait --timeout 10m \
  --set persistence.enabled=true --set persistence.storageClass=- \
  --set persistence.volumeName=rancher-backup-pv --set persistence.size=10Gi
```

**hostPathのディレクトリの権限を直す必要がある。** `DirectoryOrCreate`で作られたディレクトリは
root所有になる。operatorはUID 1000(非root)で動くので、初回のバックアップは
`permission denied`で失敗した(hostPathには`fsGroup`が効かない)。rootの一時Podで所有者を変える。

```bash
IMG=$(kubectl --context local get setting shell-image -o jsonpath='{.default}')   # rancher/shell
kubectl --context local -n cattle-resources-system run fix-backup-perms --rm -i --restart=Never --image="$IMG" \
  --overrides='{"spec":{"containers":[{"name":"fix","image":"'"$IMG"'","command":["sh","-c","chown 1000:1000 /data && chmod 0750 /data && ls -ld /data"],"securityContext":{"runAsUser":0,"runAsNonRoot":false},"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","hostPath":{"path":"/var/lib/rancher/rancher-backups"}}]}}'
```

1回きりのバックアップと、定期バックアップを作る。

```bash
kubectl --context local apply -f - <<'EOF'
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: initial-backup
spec:
  resourceSetName: rancher-resource-set-full
---
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: daily
spec:
  resourceSetName: rancher-resource-set-full
  schedule: "0 18 * * *"    # UTC。03:00 JST
  retentionCount: 14
EOF
kubectl --context local get backups.resources.cattle.io     # STATUSがCompleted、LATEST-BACKUPにファイル名
```

`Backup/daily`は作成した直後にも1回バックアップを取る。

### バックアップファイルの取り出し

operatorのイメージには`tar`が無いので、`kubectl cp`は使えない。`exec`の`cat`で取り出す
(`sh`と`cat`はある)。

```bash
kubectl --context local -n cattle-resources-system exec deploy/rancher-backup -- ls -l /var/lib/backups
kubectl --context local -n cattle-resources-system exec deploy/rancher-backup -- cat /var/lib/backups/<ファイル名> > <ファイル名>
```

Dockerホストからは`docker cp "$RANCHER_CONTAINER":/var/lib/rancher/rancher-backups/<ファイル名> .`でも取り出せる。

`rancher-resource-set-full`の中身(2026-10-13に確認):settings(172件)、Secret(104件、
CAの`cattle-system/tls-rancher`を含む)、Fleetのバンドル、クラスタやマシンの定義、RBAC、
UIPlugin(`cattle-ui-plugin-system`)など、約1,500件。

> Secretを含むので、**バックアップファイルは秘密情報として扱う**(権限600、使い終わったら消す)。
> 暗号化したい場合は、`encryptionConfigSecretName`を使う公式手順に従う。暗号化した場合は、
> リストア側にも同じEncryptionConfigurationのSecretが要る。今は暗号化していない。

## 4. フェーズ2の準備: CAの取り出しとサーバ証明書の作成(移行日、停止の前)

### 4-1. CAを取り出す

```bash
cd ~/rancher-migration
kubectl --context local -n cattle-system get secret tls-rancher -o jsonpath='{.data.tls\.crt}' | base64 -d > ca.crt
kubectl --context local -n cattle-system get secret tls-rancher -o jsonpath='{.data.tls\.key}' | base64 -d > ca.key
chmod 600 ca.key
# cacerts settingと同じCAかを確認する。2つのフィンガープリントが一致すること(22:46:E2:0A:…:77:71:88)
openssl x509 -in ca.crt -noout -fingerprint -sha256
kubectl --context local get setting cacerts -o jsonpath='{.value}' | openssl x509 -noout -fingerprint -sha256
```

### 4-2. 同じCAでサーバ証明書を発行する

Docker版では、dynamiclistenerがサーバ証明書を自動で更新していた。**Helm版では、この証明書を
自分で管理することになる**(→ [9-2. サーバ証明書の更新](#9-2-サーバ証明書の更新))。
SANには今の証明書のIPとホスト名を全部入れる。

```bash
cd ~/rancher-migration
cat > server.ext <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:192.168.1.149,DNS:rancher.ibid.lan,DNS:rancher.brc.riken.jp,DNS:localhost,DNS:rancher.cattle-system,IP:127.0.0.1
EOF
openssl ecparam -name prime256v1 -genkey -noout -out tls.key
openssl req -new -key tls.key -subj "/O=ibid/CN=rancher.ibid.lan" -out tls.csr
openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1825 -sha256 -extfile server.ext -out tls.crt
chmod 600 tls.key
openssl verify -CAfile ca.crt tls.crt          # OKになること
openssl x509 -in tls.crt -noout -ext subjectAltName -enddate
```

有効期限は5年にしている。利用者はプロキシ側の証明書を見るので、ブラウザの398日制限は関係しない。
期限は[roadmap](roadmap.md)などに控えておく。

## 5. フェーズ2: 切り替え(移行日)

### 5-1. 最新のバックアップを取って取り出す

```bash
kubectl --context local apply -f - <<EOF
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: migration-$(date +%Y%m%d)
spec:
  resourceSetName: rancher-resource-set-full
EOF
kubectl --context local get backups.resources.cattle.io migration-$(date +%Y%m%d) -w
BACKUP_FILE=$(kubectl --context local get backups.resources.cattle.io migration-$(date +%Y%m%d) -o jsonpath='{.status.filename}')
docker cp "$RANCHER_CONTAINER:/var/lib/rancher/rancher-backups/$BACKUP_FILE" ~/rancher-migration/
```

**この時点から後に行ったRancher側の変更は、移行先には引き継がれない。**

### 5-2. Dockerコンテナを止め、切り戻し用のバックアップを取る

公式ドキュメント「Backing up Rancher Installed with Docker」と同じやり方。

```bash
docker update --restart=no "$RANCHER_CONTAINER"   # ホストを再起動しても上がってこないようにする
docker stop "$RANCHER_CONTAINER"
docker create --volumes-from "$RANCHER_CONTAINER" --name rancher-data-$(date +%Y%m%d) rancher/rancher:v2.14.1
docker run --rm --volumes-from rancher-data-$(date +%Y%m%d) -v ~/rancher-migration:/backup alpine:latest \
  tar zcf /backup/rancher-data-backup-v2.14.1-$(date +%Y%m%d).tar.gz \
  --exclude=var/lib/rancher/k3s/agent/containerd /var/lib/rancher
chmod 600 ~/rancher-migration/rancher-data-backup-*.tar.gz   # Secretを含む
```

コンテナ本体(`$RANCHER_CONTAINER`)は**削除しない**。

containerdのイメージキャッシュ(7.8GB、再取得できる)を除外すると、tarは約720MBで済む(2026-10-13実績)。

### 5-3. K3sを入れる

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='v1.35.4+k3s1' sh -s - server \
  --node-ip 192.168.1.149 \
  --tls-san 192.168.1.149 --tls-san rancher.ibid.lan \
  --write-kubeconfig-mode 600
K="sudo k3s kubectl"    # 以降の手順はこの$K/$Hを使う
H="sudo helm --kubeconfig /etc/rancher/k3s/k3s.yaml"
$K get nodes        # Ready
$K -n kube-system get svc traefik   # 80/443がホストで待ち受けること(servicelb)
```

K3sに標準で入るTraefik(と、ホストの80/443を開けるservicelb)を、そのままIngressとして使う。
Docker版を止めた後なので、ポートはぶつからない。

### 5-4. rancher-backupを入れてリストアする

[公式の新しいクラスタへの移行手順](https://documentation.suse.com/cloudnative/rancher-manager/v2.14/en/rancher-admin/back-up-restore-and-disaster-recovery/migrate-to-a-new-cluster.html)に従う。
**Rancherを入れる前に**リストアする。

```bash
$H repo add rancher-charts https://charts.rancher.io && $H repo update
# フェーズ1でUIから入れたのと同じchart版を指定する(local側のhelm listで確認できる)
$H install rancher-backup-crd rancher-charts/rancher-backup-crd -n cattle-resources-system --create-namespace --version <版>
$H install rancher-backup rancher-charts/rancher-backup -n cattle-resources-system --version <版> \
  --set persistence.enabled=true --set persistence.storageClass=local-path --set persistence.size=10Gi
```

バックアップファイルを、operatorが参照するボリュームに置く。

```bash
POD=$($K -n cattle-resources-system get pod -l app.kubernetes.io/name=rancher-backup -o jsonpath='{.items[0].metadata.name}')
$K -n cattle-resources-system exec -i "$POD" -- sh -c "cat > /var/lib/backups/$BACKUP_FILE" < ~/rancher-migration/"$BACKUP_FILE"   # イメージにtarが無いのでkubectl cpは使えない
```

> マウント先は109.0.9では`/var/lib/backups`。chartの版を変えた場合は、
> `$K -n cattle-resources-system describe pod "$POD"`のMountsで確認する。

```bash
$K apply -f - <<EOF
apiVersion: resources.cattle.io/v1
kind: Restore
metadata:
  name: restore-migration
spec:
  backupFilename: $BACKUP_FILE
  prune: false
EOF
$K get restores.resources.cattle.io restore-migration -w     # Completedになるまで待つ
$K -n cattle-resources-system logs -l app.kubernetes.io/name=rancher-backup --tail=50
```

### 5-5. 証明書のSecretを作る

```bash
$K create namespace cattle-system --dry-run=client -o yaml | $K apply -f -
$K -n cattle-system create secret tls tls-rancher-ingress --cert ~/rancher-migration/tls.crt --key ~/rancher-migration/tls.key
$K -n cattle-system create secret generic tls-ca --from-file=cacerts.pem=$HOME/rancher-migration/ca.crt
```

`tls-ca`(`privateCA=true`)により、Rancherが`cacerts` settingとagentに配るCAチェックサムを、
このCAから計算する。CAが同じなので、チェックサムは今と変わらない。

### 5-6. RancherをHelmで入れる(v2.14.1)

```bash
$H repo add rancher-latest https://releases.rancher.com/server-charts/latest && $H repo update
$H search repo rancher-latest/rancher --versions | grep 2.14.1   # 無ければrancher-stableを探す
$H install rancher rancher-latest/rancher -n cattle-system --version 2.14.1 \
  --set hostname=rancher.ibid.lan \
  --set replicas=1 \
  --set ingress.tls.source=secret \
  --set privateCA=true
$K -n cattle-system rollout status deploy/rancher --timeout=15m
```

`hostname`は、chartが作るIngressのホスト名にしか使われない。server-urlはリストアした
settingの値(`https://192.168.1.149`)が残る想定。**(要検証③)**

```bash
$K get setting server-url -o jsonpath='{.value}{"\n"}'   # https://192.168.1.149 のままであること
# 変わっていたら元に戻す:
# $K patch setting server-url --type=merge -p '{"value":"https://192.168.1.149"}'
```

### 5-7. IPでの接続を受けるIngressと、デフォルト証明書を設定する

Kubernetesでは、IngressのホストにIPアドレスを書けない。chartのIngress(`host: rancher.ibid.lan`)だけでは、
`https://192.168.1.149`(agent・kubeconfig)や、プロキシから別のHostヘッダで来たリクエストに一致しない。
そこで、**ホストを指定しない受け皿のIngress**を追加する。あわせて、SNIが無い接続にも同じ証明書を
返すよう、Traefikのデフォルト証明書(TLSStore `default`)を設定する。**(要検証④)**

```bash
$K apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rancher-catchall
  namespace: cattle-system
spec:
  ingressClassName: traefik
  tls:
    - secretName: tls-rancher-ingress
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rancher
                port:
                  number: 80
---
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: cattle-system
spec:
  defaultCertificate:
    secretName: tls-rancher-ingress
EOF
```

## 6. 切り替え後の確認

```bash
# 返ってくる証明書が同じCAから発行されていること(issuerがdynamiclistener-ca@1781590233)
openssl s_client -connect 192.168.1.149:443 </dev/null 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName
$K get setting cacerts -o jsonpath='{.value}' | openssl x509 -noout -fingerprint -sha256   # 22:46:E2:0A:…:77:71:88
$K get clusters.management.cattle.io                     # dev1/prod1/harvester1がActive(数分かかることがある)
$K get gitrepos -n fleet-default                         # ibid-dev / ibid-production がReady
```

- [ ] 既存のkubeconfig context(`rancher`/`local`/`dev1`/`prod1`/`harvester1`)がそのまま使える(トークンもリストアされる)
- [ ] 下流の`cattle-system/cattle-cluster-agent`が再接続している(2.-4.で用意した直接kubeconfigでログを見る。`x509`や`CA checksum`のエラーが無いこと)
- [ ] プロキシ経由(`https://rancher.brc.riken.jp`)でUIにログインできる
- [ ] Harvester UI拡張(Extensions)が表示される。消えていれば入れ直す **(要検証⑤)**
- [ ] Fleetのバンドルが`ibid-dev` 54/54、`ibid-production` 34/34に戻る(2026-10-13時点の数)
- [ ] 下流クラスタのWordPress/アプリに影響が無い

問題が無ければ、[9-1. 定期バックアップ](#9-1-定期バックアップ)を設定する。
**BaculaのFileSetを、K3s側の保存先に変えること**(→ 9-1.)。変えないと、二次コピーが止まったことに気づけない。

## 7. 切り戻し

agentはIPとCAしか見ていないので、Docker版に戻せばそのまま再接続する。
**K3s側で行った変更は失われる。**

```bash
sudo systemctl stop k3s && sudo systemctl disable k3s
sudo /usr/local/bin/k3s-killall.sh            # 80/443とコンテナを確実に解放する
docker start "$RANCHER_CONTAINER"
docker update --restart=unless-stopped "$RANCHER_CONTAINER"   # 2.-2.で記録した元のポリシーに合わせる
```

コンテナが壊れている場合は、5-2.のtarを、公式ドキュメント
「Restoring Backups—Docker Installs」の手順で戻す。

移行が安定したら(目安2週間)、次のものを片付ける。

- 止めたコンテナと`rancher-data-*`コンテナ
- `~/rancher-migration`のtarとバックアップファイル(`ca.key`は[9-2.](#9-2-サーバ証明書の更新)で使うので、安全な場所に移す)
- `docker update --restart=no`のまま放置しないこと

## 8. フェーズ3: アップグレード(例: 2.14.1 → 2.14.2)

1. [Harvesterのサポートマトリクス](https://www.suse.com/suse-harvester/support-matrix/all-supported-versions/harvester-v1-8-x/)で、
   アップグレード先の版がHarvester v1.8.xに対応しているかを確認する(2026-10-13時点では2.14.1 / 2.14.2のみ)。
   マイナーバージョンは1つずつ上げる。
2. 直前にバックアップを取る(5-1.と同じ`Backup` CR)。
3. 今のvaluesのまま版だけ上げる。
   ```bash
   $H get values rancher -n cattle-system -o yaml > ~/rancher-migration/rancher-values.yaml
   $H repo update
   $H upgrade rancher rancher-stable/rancher -n cattle-system --version 2.14.2 -f ~/rancher-migration/rancher-values.yaml
   $K -n cattle-system rollout status deploy/rancher --timeout=15m
   ```
4. 6.と同じ確認をする。rancher-backupのchartも、Rancherの版に合うものへ上げる。
5. 失敗したときは、`helm rollback rancher -n cattle-system`で戻す。Rancherのデータ(CRD・settings)まで戻す
   必要がある場合は、2.のバックアップを使い、公式の「Rollback」手順に従う。

### 実施記録: 2.14.1 → 2.14.2(2026-10-13)

| 時刻(JST) | 内容 |
|---|---|
| 11:47 | `Backup/pre-upgrade-2142`を取得し、`helm upgrade`(`rancher-stable`、`-f`で今のvalues) |
| 11:50 | Rancher v2.14.2が起動。server-urlとCAは変わらず |
| 11:51〜11:52 | 下流のcattle-cluster-agentがv2.14.2へ入れ替わる(3クラスタとも) |
| 11:58 | Fleetが54/54・34/34に戻る |

- リリースノートの既知の問題は、rancher-logging(inotifyの上限)だけ。このリポジトリでは使っていない。
- 更新されたのはRancherが管理するもの(fleet-agent、rancher-webhook、cattle-cluster-agent)だけで、
  サイトやアプリのHelmリリースは更新されなかった。
- rancher-backupのchartは109.0.9のままでよかった(2.14.2の`rancher-charts`でも最新)。
- 同じ時間帯の11:46に、prod1の`rdndw`ノードが手作業で再起動された(このホストから`ubuntu`でSSHし、
  `sudo reboot`)。アップグレードとは無関係だが、その影響で、そのノードのWordPress 6サイトの片方の
  レプリカと、`metadatabase-v2`(1レプリカ)が数分止まった。Fleetの34/34への戻りが遅れたのもこのため。

K3s自体の更新は、Rancherの更新とは別の日に、
Rancherのサポートマトリクスに載っているK3sの版へ上げる(`INSTALL_K3S_VERSION`を指定してインストールスクリプトを再実行する)。

## 9. 移行後の運用

### 9-1. 定期バックアップ

Docker版では設定済み(3.)。**`Backup` CRはリストアの対象外**なので、移行後のK3s側で
同じ`Backup/daily`を作り直す(2026-10-13に作成済み)。

```bash
$K apply -f - <<'EOF'
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: daily
spec:
  resourceSetName: rancher-resource-set-full
  schedule: "0 18 * * *"    # UTC。03:00 JST
  retentionCount: 14
EOF
```

保存先はこのホストのlocal-path(`/var/lib/rancher/k3s/storage/<PV名>_cattle-resources-system_<PVC名>/`)。
Docker版のときはRancherのボリュームの中にあり、それをBaculaで二次コピーしていた。移行後は場所が
変わるので、**BaculaのFileSetに新しいパスを追加する**(本リポジトリの管理外)。実際のパスは次で確認する。

```bash
$K get pv -o custom-columns=NAME:.metadata.name,CLAIM:.spec.claimRef.name,PATH:.spec.hostPath.path,LPATH:.spec.local.path
```

2026-10-13時点の保存先(**BaculaのFileSetに追加すること**):
`/var/lib/rancher/k3s/storage/pvc-706cec26-f26a-4e03-b536-6cfe41d59891_cattle-resources-system_rancher-backup-1/`

### 9-2. サーバ証明書の更新

4-2.で発行した証明書は自動では更新されない(Docker版のdynamiclistenerとの違い)。期限が近づいたら、
同じCA(`ca.key`)で4-2.をやり直し、Secretを差し替えてRancherを再起動する。

```bash
$K -n cattle-system create secret tls tls-rancher-ingress --cert tls.crt --key tls.key --dry-run=client -o yaml | $K apply -f -
$K -n cattle-system rollout restart deploy/rancher
```

`ca.key`を失うと、CAを変えるしか無くなる(=全agentの再登録が必要になる)。安全な場所に保管すること。

### 9-3. K3s自身の証明書

K3sの内部証明書は、期限の90日前を過ぎてからK3sを再起動すると自動で更新される。
年に1回はK3sの更新か再起動を行う。

## 10. 要検証ポイント

すべて2026-10-13の移行で確認した。

| # | 内容 | 結果 |
|---|---|---|
| ① | Docker版の埋め込みK3sで、hostPathの静的PVを使ったrancher-backupが動くか | **OK**(2026-10-13)。ディレクトリの所有者をUID 1000に変える必要あり(3.) |
| ② | 2.14.1でのResourceSet名(`rancher-resource-set-full`か) | **OK**(2026-10-13)。`rancher-resource-set-basic`と`-full`がある。`-full`はSecretを含む |
| ③ | Helmで入れた後もserver-urlが`https://192.168.1.149`のまま残るか | **OK**(2026-10-13)。リストアした値がそのまま残った。`cacerts`のフィンガープリントも同じ |
| ④ | 受け皿のIngressとTLSStoreで、IP直接アクセス(SNI無し)・プロキシ経由の両方に正しい証明書が返るか。agentのwebsocketがつながるか | **OK**(2026-10-13)。SNI無し・IP・各ホスト名とも同じCAの証明書が返る。agentはRancher起動の約20秒後に`Connected to proxy`。プロキシ経由の`/ping`も200 |
| ⑤ | Harvester UI拡張などのUIPluginがリストアで戻るか | **OK**(2026-10-13)。`harvester` 1.8.2が`cached`・ready |

## 11. 実施記録(2026-10-13)

| 時刻(JST) | 内容 |
|---|---|
| 11:03 | 移行用バックアップ`migration-20261013`を取得し、ホストへ取り出す(5-1.) |
| 11:04 | Dockerコンテナ`rancher`を停止(`--restart=no`に変更)。**ここからRancher停止** |
| 11:06 | 切り戻し用のtar(721MB)を作成(5-2.) |
| 11:08 | K3s v1.35.4+k3s1をインストール(5-3.)。rancher-backup 109.0.9を導入 |
| 11:10 | リストア完了(73秒、5-4.)。証明書のSecretを作成(5-5.) |
| 11:14 | Rancher v2.14.1をHelmで導入し、起動(5-6.)。受け皿のIngressとTLSStoreを適用(5-7.) |
| 11:15 | dev1/prod1/harvester1のagentが再接続。既存のkubeconfig contextもそのまま使えた |
| 11:25 | Fleetが`ibid-dev` 54/54、`ibid-production` 34/34に戻る |
| 11:26 | K3s側に`Backup/daily`を作り直し、初回分を取得 |

**Rancher UIの停止は約10分、Fleetの同期が元に戻るまでは約20分**だった。

気づいた点:

- 切り替え前後で、agentの`CATTLE_CA_CHECKSUM`は`52f8ea80…`のまま変わらなかった。agent側の作業は不要だった。
- 新しいRancherは、下流の全ノードでsystem-agentの更新ジョブ(`apply-system-agent-upgrader-on-*`)を
  流し直した。版は同じ(v0.3.16)で、すべてCompleteになった。prod1に、置き換えられた古い試行のPodが
  1つ`Unknown`で残ったが、害は無い。
- **それに続いて、dev1とprod1の全ノードでrke2(kubelet)が1台ずつ再起動した**(11:17〜11:24。
  kube-proxyのstatic Podの起動時刻で確認した。prod1の`rdndw`と`wz25m`だけは11:53ごろ)。
  ほとんどのコンテナは止まらなかったが、dev1の`fddfs`ノードではmariadbが3サイト
  (`acd-en`・`kougaku-en`・`web-en`)で再起動した。本番のWordPressは2レプリカなので、サイトは止まっていない。
  **移行の作業時間帯は、下流ノードのkubeletが再起動するものとして計画すること。**
- Fleetのagentは下流で再デプロイされ、すべてのバンドルが揃うまで約10分かかった(途中は`WaitApplied`)。
- 移行後のホストのメモリ使用量は約5.8GiB(Docker版のときは約10GiB使っていた)。
- 秘密情報を扱う手順(直接kubeconfigの取得、CAの取り出し、バックアップファイルの取り出しと投入、
  証明書のSecretの作成)は運用者が実行し、それ以外はClaude Codeが実行した。

残作業:

- [ ] BaculaのFileSetに、K3s側のバックアップの保存先を追加する(9-1.)
- [ ] 2026-10-27ごろ、問題が無ければDocker版の後片付けをする(7.の最後)
- [ ] `~/rancher-migration/ca.key`を安全な場所に保管する(9-2.)
