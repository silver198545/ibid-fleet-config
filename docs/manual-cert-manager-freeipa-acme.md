# cert-manager + FreeIPA ACME 導入手順(TLS証明書の自動発行)

社内限定サイトのTLSは、FreeIPA(`ibid.lan`)のACME(Dogtag CA)から発行する。詳細な設計判断・
ネットワーク構成は[freeipa-harvester-networkの検討記録]内部メモ相当だが、本リポジトリでは
以下に手順として残す。ホスト名規約は`<site>.<env>.ibid.lan`。外部公開が必要なサイトは別ドメイン+
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
(`freeipa-acme`)を導入する。TSIG鍵の値は3環境で同一だが、SealedSecretは
**環境ごとに個別にkubeseal(`--context <env1>`)し直す**必要がある
(封印鍵が環境ごとに異なるため、他環境からのコピーは復号できない)。

```bash
kubeseal --context <dev1|staging1|prod1> --format yaml < <平文Secretのyaml> \
  > envs/<env>/infra/cert-manager-issuer/sealedsecret-rfc2136-tsig.yaml
```

`ClusterIssuer`は3環境で同一内容(同じFreeIPA ACMEエンドポイントを使う)。ACMEアカウント鍵
(`freeipa-acme-account-key`)はcert-managerが初回発行時に自動生成するため、Git管理不要。

## サイト側でのCertificate発行

各サイトのfleet.yaml側でIngressに以下のannotationを付けると、cert-managerが自動でCertificateを
発行する(Ingress化の詳細は別途)。

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: freeipa-acme
```
