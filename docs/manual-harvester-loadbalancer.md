# Harvester Cloud Provider による LoadBalancer 化手順（MetalLB代替）

このクラスタ（Rancher 経由で Harvester 上にプロビジョニングされた RKE2 クラスタ）には
**Harvester Cloud Provider**（`cloudprovider.harvesterhci.io`）が組み込まれています。
このため `Service type=LoadBalancer` を作成すると、MetalLB ではなく Harvester Cloud Provider が
先に反応し、Harvester 側の `IPPool` カスタムリソースから IP を払い出そうとします。

MetalLB と Harvester Cloud Provider を同時に使うと同じ Service を取り合って競合するため、
本リポジトリでは **MetalLB を廃止し、Harvester Cloud Provider の LoadBalancer 機能に一本化**します。

## 背景: 発生したエラー

Service の Events やゲストクラスタ側の `harvester-cloud-provider` Pod のログに、以下のような
エラーが出ます。

```
Error syncing load balancer: failed to ensure load balancer: update load balancer IP of
service <namespace>/<service-name> failed, error: timeout waiting for IP address,
last error:ip is not allocated, mode: pool, message: no matched IPPool with requirement
&{Network:default/public Project: Namespace:harvester-public Cluster:<cluster-name>}
```

これは Harvester 側に、次の条件に一致する `IPPool` がまだ存在しないために発生します。

- `selector.network`: `default/public`
- `selector.scope[].namespace`: `harvester-public`
- `selector.scope[].guestCluster`: `<cluster-name>`（**クラスタを再作成すると変わる**ので、
  必ず実際に出ているエラーメッセージの `Cluster:` の値を使うこと。例: `dev1`, `dev2` など）

> `harvester-cloud-provider` 自体が正常に動作していても（Node の初期化には成功するなど）、
> IPPool が無いと Service の LoadBalancer 化だけがこのエラーで失敗し続けます。
> `kubectl -n kube-system logs -l app.kubernetes.io/name=harvester-cloud-provider` で
> 同様のログが繰り返し出ていれば、まず IPPool の有無を疑ってください。

### 既知の落とし穴: ゲストクラスタ側のクラスタ名が正しく名乗れていない

IPPoolの`selector.scope[].guestCluster`を実際のクラスタ名(例: `dev1`)に設定しているのに、
エラーメッセージの`Cluster:`がそれと違う値(典型的には`kubernetes`)になっていて
一致しない、というケースがある。これはHarvester側ではなく**ゲストクラスタ側の
`harvester-cloud-provider`(Cloud Controller Manager)が、自分の所属クラスタ名を
正しく認識できていない**ことが原因。

確認方法(ゲストクラスタ側):

```bash
kubectl -n kube-system get helmchartconfig harvester-cloud-provider -o jsonpath='{.spec.valuesContent}'
```

正常なクラスタ(移行後に新規作成したstaging/production等)では
`{"global":{"cattle":{"clusterId":"c-m-xxxxxxxx","clusterName":"<クラスタ名>"}}}`
のように`clusterName`が入っているが、`clusterId`しか入っていない(`clusterName`が
欠落している)場合、CCMはクラスタ名をKubernetesの伝統的なデフォルト値
`kubernetes`のまま名乗ってしまう。dev1は移行前の単一クラスタ時代に作られた
名残でこの`clusterName`が入っていなかった実績がある。

**恒久修正(Rancher localクラスタ側。2026-07-07に全3クラスタへ適用済み)**:
クラスタ定義の `spec.rkeConfig.chartValues` に `clusterName` を明示する。
ここが正(source of truth)で、HelmChartConfigはここから生成される。

```bash
kubectl --context rancher -n fleet-default patch clusters.provisioning.cattle.io <クラスタ名> --type merge \
  -p '{"spec":{"rkeConfig":{"chartValues":{"harvester-cloud-provider":{"cloudConfigPath":"/var/lib/rancher/rke2/etc/config-files/cloud-provider-config","global":{"cattle":{"clusterName":"<クラスタ名>"}}}}}}}'
```

> ゲストクラスタ側のHelmChartConfigを直接patchする暫定対処は**再発する**。
> 実際に2026-07-07、chartValuesが空だったstaging1/prod1でノードプール入替を契機に
> LBが `kubernetes-*` 名で再作成され、IPPool不一致でstagingの全サイトが外部到達不能になった
> (prod1は既存LB CRが残っていたため無事故だったが同じ地雷を抱えていた)。

> **さらに重要: Rancher UIでのクラスタ設定変更(ノードプール編集等)は、この
> chartValuesを黙って `{}` に消すことがある**。実例: 2026-07-07、朝まで設定が
> 入っていたdev1が、ノードプールのディスク拡張編集後に `{}` になり、入替中に
> `kubernetes-*` LBの作成・削除が繰り返される症状で発覚した(staging1/prod1に
> 元から設定が無かったのも、過去のUI操作で消されたためと推定)。
> **クラスタの新規作成・再構築・UI経由の設定変更をしたら、毎回
> `kubectl --context rancher -n fleet-default get clusters.provisioning.cattle.io <クラスタ名> -o jsonpath='{.spec.rkeConfig.chartValues.harvester-cloud-provider}'`
> で残存を確認すること。**症状(kubernetes-*名のLBが作成されては消える)が出たら
> まずここを疑う。

### 既知の落とし穴: IPPoolの範囲にHarvester管理VIPを含めない

IPPoolの範囲が、Harvester管理クラスタ自身のUI用VIP(`kube-system/ingress-expose` Service)や
他の使用中IPと重なっていると、そのIPがサイトLBに払い出された時点で**ARP flappingが起き、
サイトとHarvester UIの両方が不安定になる**(症状: サイトのhttpsがRancher系UIの
`/dashboard/` へのリダイレクトを返す、ARPテーブルのMACが交互に入れ替わる)。

- 実例(2026-07-08解消): staging用pool2が `.60-.70` で、`.60` = Harvester UIのVIPだった。
  dnaサイトに `.60` が割り当てられ衝突 → pool2を `.61-.70` に変更して解消。
- VIPの確認: Harvester管理クラスタで `kubectl -n kube-system get svc ingress-expose`
- 範囲変更の手順(割当済みIPを除外する場合、webhookに拒否されるため順序が重要):
  1. 該当LB CRを削除(`kubectl -n harvester-public delete loadbalancer <名前>`)
  2. 直後にIPPoolのrangeを変更(CCMが取り直す前に)
  3. **CCMはServiceの既存status IPを維持しようとする**ため、旧IPが残る場合は
     `kubectl -n <ns> patch svc <名前> --subresource=status --type merge -p '{"status":{"loadBalancer":{"ingress":[]}}}'`
     でstatusをクリアし、LB CRを再度削除 → Serviceにアノテーションを付けて再同期を促す
  4. サイトのWordPressがIP直URLをDBに焼き込んでいる場合はURL置換も必要
     (`manual-wordpress-restore.md` 手順6)

### どのクラスタが「Harvester管理クラスタ」なのか迷ったら

Rancher + Harvester 構成では、Rancher のクラスタ一覧に紛らわしいクラスタが複数存在します。

- ゲストクラスタ（例: `dev1`, `dev2`）: WordPress や Traefik が動く RKE2 クラスタ
- `local`: **Rancher 自体が動いている管理クラスタ**（Harvester ではない）。
  `harvesterconfigs` / `harvestermachines` などの CRD はあるが、
  `loadbalancer.harvesterhci.io` の IPPool はここには存在しない。
- 実際の Harvester クラスタ: 上記のどちらでもない、別名でインポートされたクラスタ。
  `kubectl api-resources | grep -i harvester` を実行して
  `loadbalancer.harvesterhci.io` 系のリソース（`ippools`, `loadbalancers` 等）が
  出てくるクラスタが本物の Harvester 管理クラスタです。

## 1. Harvester 管理クラスタに IPPool を作成する

**この手順は本リポジトリ（Fleet で管理するゲストクラスタ）ではなく、Harvester の
管理クラスタ側で実施します。**

複数のゲストクラスタ・複数の Namespace の Service から共通で使えるように、
`selector.scope` をワイルドカード（`*`）にした「グローバルプール」として作成するのが
シンプルで確実です（`namespace` や `guestCluster` を個別に指定する方式は、
クラスタを再作成すると値がズレて再度マッチしなくなるため非推奨）。

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: loadbalancer.harvesterhci.io/v1beta1
kind: IPPool
metadata:
  name: pool1
  labels:
    loadbalancer.harvesterhci.io/global-ip-pool: 'true'
spec:
  ranges:
    - rangeStart: 192.168.1.150
      rangeEnd: 192.168.1.200
      subnet: 192.168.1.0/24
      gateway: 192.168.1.1
  selector:
    network: default/public
    priority: 1
    scope:
      - project: '*'
        namespace: '*'
        guestCluster: '*'
EOF
```

> このコマンドは Harvester 管理クラスタの Kubectl Shell で実行してください（ゲストクラスタや
> Rancher の `local` クラスタではありません）。`ranges` のIP範囲・サブネット・ゲートウェイは
> 実際のネットワーク構成に合わせて調整してください（従来 MetalLB の IPAddressPool に
> 設定していた `192.168.1.150-192.168.1.200` をそのまま踏襲しています）。
>
> Harvester の UI には「Global Pool」という明示的なチェックボックスはありません。
> `spec.selector.scope` の各項目をすべて `*`（または未指定）にすると、
> `loadbalancer.harvesterhci.io/global-ip-pool: 'true'` ラベルが付き、
> 全クラスタ・全 Namespace から利用可能なグローバルプールとして扱われます。

作成後、IPPool の状態を確認します。

```bash
kubectl get ippools.loadbalancer.harvesterhci.io pool1 -o yaml
```

IPPool を作成すれば、`service.type: LoadBalancer` を指定している Service（例えば
[wordpress/fleet.yaml](../wordpress/fleet.yaml)）は追加の変更なしに外部IPが割り当てられます。

## 2. 外部IPが割り当てられたことを確認する

```bash
kubectl -n <namespace> get svc
```

期待値は `TYPE=LoadBalancer` かつ `EXTERNAL-IP` に IPPool の範囲内のアドレスが入っていることです。

## Traefik を LoadBalancer 化する(サイト数増加に伴うIngress方式への転換、2026-07-10〜)

1サイト=1 LoadBalancer IPのままだとIPPoolが枯渇するため（`docs/roadmap.md` 優先度・高の項目1）、
**Traefik を1つの共有LoadBalancer IPで公開し、各WordPressサイトはホスト名ベースのIngressで
振り分ける**方式に転換する。各サイトのcert-manager Ingress annotationについては
[manual-cert-manager-freeipa-acme.md](manual-cert-manager-freeipa-acme.md) を参照。

### 設定方法(Rancher Cluster CR経由、Fleet管理外)

`rke2-traefik`はRKE2組み込みのHelmChartConfigで管理されており、`harvester-cloud-provider`の
`clusterName`修正と同じ理由で、**直接`kubectl patch svc`しても永続しない**
（Rancherが定期的にHelmChartを再同期し上書きする）。source of truthは
ゲストクラスタ側ではなくRancher local クラスタの`Cluster` CRの`spec.rkeConfig.chartValues`。

```bash
kubectl --context rancher -n fleet-default patch clusters.provisioning.cattle.io <クラスタ名> --type merge \
  -p '{"spec":{"rkeConfig":{"chartValues":{"rke2-traefik":{"service":{"spec":{"type":"LoadBalancer"}}}}}}}'
```

> **落とし穴: キーパスは `service.spec.type` であって `service.type` ではない。**
> Traefik公式チャート(v40系、Rancherが`rke2-traefik`として再パッケージ)のvalues.yamlでは
> Service関連の値が`service.spec`配下(K8s Service specへの素通し領域)にネストされており、
> `service.type`を渡してもテンプレート側で読まれず黙って無視される(エラーにならない)。
> `helm --kube-context <ctx> -n kube-system get values rke2-traefik`で意図通りの値が
> user-suppliedとして反映されていても、`get manifest`のServiceが`ClusterIP`のままなら
> このキーパス違いを疑うこと。

反映確認:

```bash
# HelmChartConfigに反映されたか(数秒で反映)
kubectl --context <クラスタ名> get helmchartconfig -n kube-system rke2-traefik -o jsonpath='{.spec.valuesContent}'
# helm-install Jobが再実行されHelmアップグレードが走るまで待つ(概ね15〜30秒)
kubectl --context <クラスタ名> get job -n kube-system helm-install-rke2-traefik
# ServiceがLoadBalancerになりEXTERNAL-IPが付与されたか
kubectl --context <クラスタ名> get svc rke2-traefik -n kube-system
```

`harvester-cloud-provider`と同様、**このchartValuesもノードプール編集等のRancher UI操作で
黙って消えることがある**既知の問題を抱えている。ノード入替後は必ず
`kubectl --context rancher -n fleet-default get clusters.provisioning.cattle.io <クラスタ名> -o jsonpath='{.spec.rkeConfig.chartValues.rke2-traefik}'`
で残存を確認すること。

払い出されたIP(dev1: `192.168.1.39`、pool1 `192.168.1.30-49`の範囲内)は、各サイトの
ホスト名(`<site>.<env>.ibid.lan`)のDNS Aレコードとして登録する
([manual-cert-manager-freeipa-acme.md](manual-cert-manager-freeipa-acme.md) 参照)。
staging/productionへ展開する際も同じ手順を各クラスタに対して行い、環境ごとに異なる
LB IPを払い出させる(pool2/pool3からそれぞれ1つずつ消費するだけで済み、
サイトごとのIP消費は発生しなくなる)。

## 補足

- MetalLB は廃止したため、[catalog-repos/chart-repos.yaml](../catalog-repos/chart-repos.yaml) から
  MetalLB の ClusterRepo、`metallb/` の Fleet バンドルは削除済みです。
- Fleet でも Traefik の Service や HelmChartConfig を管理すると、所有権競合が発生することがあります。
  Traefik 設定の管理者は 1 つに揃えてください。
