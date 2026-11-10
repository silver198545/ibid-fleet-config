# WordPressから旧基盤(134.160.65.0/24)への通信の遮断

**新基盤での運用が正式に決まるまでの暫定措置です。** dev1・staging1・prod1のWordPressのPodから、
`134.160.65.0/24` への通信をすべて拒否しています。

- 定義: `envs/<env>/infra/egress-deny/`(Calicoの `GlobalNetworkPolicy` `deny-wordpress-to-production-public`)
- 対象: ラベル `app.kubernetes.io/name=wordpress` のPodだけ(MariaDB・バックアップJob等は対象外)。
  新しく作ったサイトにも自動で効く
- 拒否しない通信: クラスタ内の通信、DNS、WordPress.org(プラグイン更新)など、`134.160.65.0/24` 以外はすべて通る

## 経緯(2026-11-10)

外部公開中の旧基盤のサーバ(`<site>.brc.riken.jp`)のアクセスログに、
`WordPress/7.1.4; https://abc.dev.ibid.lan/ja` のようなdevのWordPressからのアクセスが出ていた。
dev/stagingには本番のコンテンツを入れているため、記事中に `https://<site>.brc.riken.jp/...` へのリンクが
多数ある(web・cell・kougaku・jcm・dna などで数十〜数百件)。WordPressがページの表示時にリンク先の
埋め込み情報(oEmbed)を取りに行くなどして、旧基盤のサーバへアクセスしていた。
サイトを個別に消しても他のサイトで同じことが起きるため、ネットワークで止めた。

当初はdev1/staging1で旧基盤のWebサーバ3台(.8/.10/.12)だけを止めたが、新基盤での運用が決まるまでは
旧基盤側へ一切触れないよう、同日中に3環境とも `/24` 全体の拒否に広げた。

## 止まっているもの(承知の上での措置)

- **prod1のwp-cron(全サイト)**: 本番のWordPressは `WP_HOME` が公開URL(`https://<site>.brc.riken.jp/...`、
  旧基盤のnginx経由)のため、wp-cronが自分の公開URLへ送るリクエストが届かない。予約投稿・期限切れデータの
  掃除・プラグインの定期タスクが動かない(ページ表示には影響しない)。
  wp-config.phpに `DISABLE_WP_CRON` は無く、wp-cronを外から動かすCronJobも無い
- **SMTPで送るメール**: SMTPサーバがこのアドレス範囲にあるサイト(prod1で4サイト。WP Mail SMTPの設定)は、
  問い合わせフォームの通知などのメールが送れない
- WordPressの「サイトヘルス」のループバック確認なども失敗として出る

dev1/staging1は `WP_HOME` が内部名(`<site>.<env>.ibid.lan`)なのでwp-cronは止まらない。

## なぜKubernetesのNetworkPolicyではないのか

Bitnamiのwordpressチャートが作るNetworkPolicy(`wordpress-<site>`)が `egress: [{}]`(全許可)になっている。
NetworkPolicyは「どれか1つでも許可すれば通る」ため、拒否用のNetworkPolicyを足しても効かない
(2026-11-10に試して効かないことを確認)。Calicoの `GlobalNetworkPolicy` は `order: 100` で
KubernetesのNetworkPolicyより先に評価され、`Deny` が優先される。prod1はCNIが `canal` だが、
ポリシーはCalicoが処理するので同じものが効く。

`projectcalico.org/v3` のAPIサーバは入っていないため、CRD(`crd.projectcalico.org/v1`)を直接書いている。

## 確認

```bash
# ポリシーが入っているか
for c in dev1 staging1 prod1; do
  kubectl --context $c get globalnetworkpolicies.crd.projectcalico.org deny-wordpress-to-production-public \
    -o jsonpath="{.spec.egress[0].destination.nets}{'\n'}"
done

# 遮断されているか(「遮断OK」が出ること、wordpress.org は 2xx/3xx が返ること)
P=$(kubectl --context prod1 -n wordpress-dna get pod -l app.kubernetes.io/name=wordpress -o name | head -1)
kubectl --context prod1 -n wordpress-dna exec $P -c wordpress -- sh -c \
  'for t in https://134.160.65.10/ https://134.160.65.12/; do curl -sk -o /dev/null --connect-timeout 3 -m 5 $t && echo "$t 通る" || echo "$t 遮断OK"; done
   curl -s -o /dev/null -m 5 -w "wordpress.org: %{http_code}\n" https://api.wordpress.org/'
```

## 解除する場合

新基盤での運用が決まったら(または一部だけ通す必要が出たら)、各環境とも次の順で行う。

1. 部分的に通す場合は `globalnetworkpolicy.yaml` の `nets` を狭める(例: SMTPサーバだけ外す)PRを
   dev → staging → production の順に出す。
2. 全面解除する場合は `envs/<env>/infra/egress-deny/` を削除するPRを出す。`keepResources: true` のため
   バンドルを消してもポリシーは残るので、マージ後に手作業で消す:
   ```bash
   kubectl --context <dev1|staging1|prod1> delete globalnetworkpolicies.crd.projectcalico.org deny-wordpress-to-production-public
   ```
3. prod1のwp-cronとメールが動き出すことを確認する(予約投稿や溜まったcronイベントは次のアクセス時にまとめて動く)。

解除せずに止まっているものを戻すなら、wp-cronはチャートでCronJobから `wp cron event run --due-now` を
動かす(`DISABLE_WP_CRON`)、メールはSMTPの送信先を変える、といった対応が必要(未対応)。

## 導入時の注意(2026-11-10の記録)

ポリシーは先に手作業(`kubectl apply`)で3クラスタに入れ、その後このバンドルで `helm.takeOwnership: true` により
Fleetの管理下へ引き継いだ。作り直しを伴わないため、引き継ぎの間も遮断は途切れない。
クラスタを作り直した場合は、このバンドルが自動で入れ直す。
