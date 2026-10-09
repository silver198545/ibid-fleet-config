# cert-manager + FreeIPA ACME 導入手順(TLS証明書の自動発行)

社内限定サイトのTLSは、FreeIPA(`ibid.lan`)のACME(Dogtag CA)から発行する。設計判断は
[roadmap.md](roadmap.md)の項目2、ゲストクラスタのノードに必要な2枚目のNIC(FreeIPA向け)は
[manual-multi-env.md](manual-multi-env.md)の「2. クラスタの新規作成」を参照。ホスト名規約は`<site>.<env>.ibid.lan`。外部公開が必要なサイトは別ドメイン+
外部NginxProxyManager経由とし、本手順の対象外。

## 前提: なぜDNS-01(RFC2136)なのか

FreeIPAが乗るネットワーク(v3333, 192.168.100.0/24)から、ゲストクラスタが乗るネットワーク
(v140, 192.168.1.0/24)への到達性は**意図的なセグメント分離**でブロックされている。ACMEの
HTTP-01チャレンジはFreeIPA側からIngress(Traefik)への到達を要求するため使用できない。
そのため、クラスタ→FreeIPAへの発信のみで完結する**DNS-01(RFC2136によるTXTレコード動的更新)**
を使う。

## FreeIPA側の設定(1回だけ、全環境共通)

### 1. TSIG鍵の生成

```bash
tsig-keygen -a hmac-sha256 certmanager-key
```

出力される`secret`の値は、後でcert-manager用のSealedSecretに使うので保管する。

### 2. 鍵定義を両CAサーバー(ibidipa1, ibidipa2)に追記

`/etc/named/ipa-ext.conf`はIPAが公式に提供する拡張ポイント(`ipa-server-upgrade`で消えない)。
**両サーバーに同一内容**を追記すること(どちらが更新要求を受けても検証できるようにするため)。

```bash
cat <<'EOF' >> /etc/named/ipa-ext.conf

key "certmanager-key" {
    algorithm hmac-sha256;
    secret "<1で生成したsecret>";
};
EOF
```

### 3. ゾーンの動的更新ポリシーに追記

既存のGSS-TSIG(`krb5-self`、DHCP/ホスト自己登録が使用中)の許可は**変更せず追記**すること。

```bash
ipa dnszone-mod ibid.lan --update-policy="grant IBID.LAN krb5-self * A; grant IBID.LAN krb5-self * AAAA; grant IBID.LAN krb5-self * SSHFP; grant certmanager-key subdomain ibid.lan TXT;"
```

**重要な注意(過去に本番DNS障害を起こした実績あり):**
`update-policy`の文法を誤ると、追記した1行だけでなく**ゾーン全体が読み込み拒否され、
`ibid.lan`のDNS解決が組織全体で止まる**(全ノードSERVFAIL)。特に`wildcard`ナイムタイプは
`*.`が名前の**先頭ラベル**である場合のみ有効で、`_acme-challenge.*.ibid.lan`のような
「固定プレフィックス+ワイルドカード+固定サフィックス」は無効。複数ラベルの可変部分に
マッチさせたい場合は`subdomain`ナイムタイプ(深さ無制限でマッチ)を使うこと。

**`update-policy`変更後は、両サーバーで即座に以下を確認する:**

```bash
journalctl -u named --since "30 seconds ago" | grep -i "ibid.lan"
dig @192.168.100.21 ibidipa1.ibid.lan. +short   # ibidipa1側
dig @192.168.100.22 ibidipa2.ibid.lan. +short   # ibidipa2側
```

`zone ibid.lan/IN: not loaded due to errors`や`invalid update policy`が出た場合は直ちに
`ipa dnszone-mod`で元の値に戻し、両サーバーで`systemctl restart named`
(`rndc reload`では復旧しないことがある)。

### 4. 反映確認(nsupdateで直接テスト)

```bash
cat <<EOF | nsupdate -y hmac-sha256:certmanager-key:<secret> -v
server 192.168.100.21
update add _acme-challenge.test.dev.ibid.lan. 60 TXT "test-value"
send
EOF
dig @192.168.100.21 TXT _acme-challenge.test.dev.ibid.lan. +short
# 後片付け
cat <<EOF | nsupdate -y hmac-sha256:certmanager-key:<secret> -v
server 192.168.100.21
update delete _acme-challenge.test.dev.ibid.lan. TXT
send
EOF
```

### 5. ACMEの有効化(未有効なら)

両CAサーバー(CAロールを持つ全台)で個別に実行すること。

```bash
ipa-acme-manage enable
ipa-acme-manage status   # "ACME is enabled"になること
```

## クラスタ側の設定(Fleet管理、本リポジトリの範囲)

`envs/<env>/infra/cert-manager/`でcert-manager本体を導入し、
`envs/<env>/infra/cert-manager-issuer/`でTSIG鍵のSealedSecretと`ClusterIssuer`
(`freeipa-acme`)を導入する。TSIG鍵の値は全環境で同一だが、SealedSecretは
**環境ごとに個別にkubeseal(`--context <env1>`)し直す**必要がある
(封印鍵が環境ごとに異なるため、他環境からのコピーは復号できない)。

```bash
kubeseal --context <dev1|prod1> --format yaml < <平文Secretのyaml> \
  > envs/<env>/infra/cert-manager-issuer/sealedsecret-rfc2136-tsig.yaml
```

`ClusterIssuer`は全環境で同一内容(同じFreeIPA ACMEエンドポイントを使う)。ACMEアカウント鍵
(`freeipa-acme-account-key`)はcert-managerが初回発行時に自動生成するため、Git管理不要。

## サイト側でのCertificate発行

各サイトのfleet.yaml側でIngressに以下のannotationを付けると、cert-managerが自動でCertificateを
発行する(Ingress化の詳細は[manual-harvester-loadbalancer.md](manual-harvester-loadbalancer.md)
「Traefik を LoadBalancer 化する」章、サイト側fleet.yamlの書き方は
[manual-wordpress.md](manual-wordpress.md)参照)。

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: freeipa-acme
```

## サイトホスト名のDNS(環境ごとのワイルドカード、クラスタ作成時に1回)

各サイト・アプリはTraefikの共有LoadBalancer IP(環境ごとに1つ)を経由し、Traefikがホスト名で
振り分ける。そのため、DNSは**環境ごとのワイルドカードAレコード1つ**で足りる(2026-10-09から)。

| レコード | 値(2026-10-09) |
|---|---|
| `*.dev.ibid.lan` | `192.168.1.33`(dev1のTraefik) |
| `*.production.ibid.lan` | `192.168.1.99`(prod1のTraefik) |

- **サイトやアプリを追加しても、DNSの作業は無い**(リハーサルサイト`<site>-rh`も同じ)。
- **TraefikのIPが変わったとき**(クラスタの作り直し等)は、このレコードを1件書き換える:
  ```bash
  kinit admin
  kubectl --context <dev1|prod1> -n kube-system get svc rke2-traefik   # 新しいIP
  ipa dnsrecord-mod ibid.lan '*.<dev|production>' --a-rec <新しいIP>
  ```
- **新しい環境を作ったとき**(例: staging)は追加する:
  `ipa dnsrecord-add ibid.lan '*.<env>' --a-rec <TraefikのLB IP>`

TSIG鍵(`certmanager-key`)はTXTレコードのみ許可(`grant certmanager-key subdomain ibid.lan TXT`)
のため、Aレコードの操作はcert-manager用の自動化経路を流用できない。**IPA管理者権限で
`ipa dnsrecord-*`を使う**(nsupdate+TSIGではない)。

### ワイルドカードが効かなくなる場合(注意)

- **個別のAレコードがあると、そちらが優先される。** 以前はサイトごとに個別のレコードを登録していたが、
  クラスタの作り直しでTraefikのIPが変わった後も古い値のまま残り、サイトに届かなくなっていた
  (2026-10-09に見つけて全て削除した)。個別のレコードは作らないこと。
- **その名前の下に別のレコードがあると、その名前にはワイルドカードが効かない**(DNSの仕様)。
  例えば`_acme-challenge.web.production`のTXTが残っていると、`web.production`はワイルドカードの対象外になる。
  cert-managerは発行後にTXTを消すが、クラスタを作り直したときなどに消し忘れが残ることがある
  (2026-10-09に本番の4件を削除した)。証明書が全てReadyなのに残っているTXTは消してよい:
  ```bash
  dig +short TXT _acme-challenge.<site>.<env>.ibid.lan @192.168.100.21   # 残っているか
  ipa dnsrecord-del ibid.lan _acme-challenge.<site>.<env> --del-all
  ```

確認:

```bash
for ns in 192.168.100.21 192.168.100.22; do
  dig +short web.dev.ibid.lan @$ns; dig +short web.production.ibid.lan @$ns
done
```

作業端末で古い値が返り続ける場合は、systemd-resolvedのキャッシュを消す(`sudo resolvectl flush-caches`)。
