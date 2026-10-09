# ゲストクラスタノードの時刻同期(chrony)設定手順

Ubuntu 26.04のゲストクラスタノード(dev1/prod1)は、**既定の設定では時刻同期できていない**。
この手順で、社内から届くNTPサーバー(`ntp.nict.jp`)を使うようにchronyを設定し直す。

## 背景(2026-10-08 dev1/prod1で発覚)

- Ubuntu 26.04のchronyは、既定では`/etc/chrony/sources.d/ubuntu-ntp-pools.sources`に書かれた
  **NTS**(暗号化NTP、ntp.ubuntu.comのTCP 4460番ポートで鍵交換する)のpoolだけを使う。
- 社内ネットワークではNTSの鍵交換が通らず、ノードは**起動してから一度も同期していなかった**。
  VMの時計はホストから受け取った起動時の時刻のまま進み、ずれが少しずつ大きくなる。
  dev1では、作成から38日で1分半〜2分20秒ずれていた。
- ずれが大きくなるとetcdが`prober found high clock drift`を出す。TLS証明書の有効期限の判定や、
  ログの時刻の突き合わせにも支障が出る。
- Harvesterホストは、Harvesterの`ntp-servers`設定で`ntp.nict.jp`(NTSではない普通のNTP、
  UDP 123番ポート)を使っていて、こちらは同期できている。

## 確認方法

ノードにSSHして確認する:

```bash
timedatectl | grep 'System clock synchronized'   # no なら未同期
chronyc -n sources                                # 全行 ^? で Reach 0 なら到達不能
sudo chronyc -n authdata                          # NTS の Cook が 0 のまま Atmp だけ増える
```

クラスタ全体を一度に見るには、各ノードのNode Leaseの更新時刻と現在時刻を比べる。
Leaseは約10秒ごとに更新されるので、それ以上ずれているノードは時計が遅れている。

```bash
kubectl --context <cluster> -n kube-node-lease get lease \
  -o custom-columns=NODE:.metadata.name,RENEW:.spec.renewTime; date -u
```

## 手順

全ノードに対して行う。下のスクリプトはファイルに保存して`bash`で実行する。
対話シェルに直接貼り付けると、`!`などが履歴展開されて意図しない動きをすることがある。
control-planeノードはetcdのリーダー以外から1台ずつ行い、各ノードの後にetcdが
healthyかを確認する。

```bash
for ip in <ノードのIP> ...; do
  echo "===== $ip"
  ssh -o StrictHostKeyChecking=accept-new ubuntu@$ip '
    hostname
    # 届くかどうかの確認(時計は変えない)。届かなければ何もしない
    sudo chronyd -Q "server ntp.nict.jp iburst" 2>&1 | grep -E "wrong by" || { echo "SKIP: ntp.nict.jp unreachable"; exit 0; }
    # 同期先を追加し、NTSのpoolを無効化(sourcedirは *.sources しか読まない)
    echo "server ntp.nict.jp iburst" | sudo tee /etc/chrony/sources.d/ntp-nict.sources >/dev/null
    [ -f /etc/chrony/sources.d/ubuntu-ntp-pools.sources ] && \
      sudo mv /etc/chrony/sources.d/ubuntu-ntp-pools.sources /etc/chrony/sources.d/ubuntu-ntp-pools.sources.disabled
    sudo chronyc reload sources >/dev/null
    sleep 20
    # ずれを一度に補正する(数分ずれていても即時に合わせる)
    sudo chronyc makestep >/dev/null
    chronyc -n sources | grep "^\^"
    chronyc tracking | grep -E "Reference ID|Leap status"
  '
done
```

`^*`の付いた行が出て、`Leap status: Normal`になれば成功。`timedatectl`の
`System clock synchronized`が`yes`になるまでは、さらに数分かかることがある。

- NTSのpoolは`chrony.conf`ではなく`sources.d/`の別ファイルにある。`chrony.conf`を編集しても無効化できない。
  また、poolに`prefer`が付いているので、無効化しないと追加した`ntp.nict.jp`が同期先に選ばれない
  (`^-`のままになる)。
- 時計が一気に数分進んでも、etcdとKubernetesは問題なかった(2026-10-08のdev1/prod1で確認済み)。

## 切り戻し

```bash
sudo rm /etc/chrony/sources.d/ntp-nict.sources
sudo mv /etc/chrony/sources.d/ubuntu-ntp-pools.sources.disabled /etc/chrony/sources.d/ubuntu-ntp-pools.sources
sudo chronyc reload sources
```

## 注意: VMを作り直すと元に戻る

この設定はVMのディスク上にだけ入る。ノードの入れ替え、Machineの削除・再作成、
クラスタの再作成で新しく作られたVMは、既定のNTSの設定に戻る。恒久対策を入れるまでは、
作り直した後にこのページの手順をやり直す。

## 恒久対策: cloud-init(User Data)に入れる(prod1は2026-10-08、dev1は2026-10-09に実施済み)

Rancherのプール設定(HarvesterConfig)のUser Dataに、次の`write_files`と`runcmd`の3行を足す。
これで、新しく作られるVMは最初から`ntp.nict.jp`で同期する。以前のUser Dataは
`qemu-guest-agent`と`nfs-common`を入れるだけだった。全体は次のとおり(dev1・prod1の全プールで使っている。クラスタ作成時のチェックリストは[manual-multi-env.md](manual-multi-env.md)の「2. クラスタの新規作成」):

```yaml
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
  - nfs-common
write_files:
  - path: /etc/chrony/sources.d/ntp-nict.sources
    content: |
      server ntp.nict.jp iburst
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent.service]
  - [mv, /etc/chrony/sources.d/ubuntu-ntp-pools.sources, /etc/chrony/sources.d/ubuntu-ntp-pools.sources.disabled]
  - [systemctl, restart, chrony]
  - [chronyc, makestep]
```

- cloud-initの`ntp:`モジュールは使わない。このモジュールは`chrony.conf`を書き換えるが、NTSのpoolは
  `sources.d/`の別ファイルにあるので、それを無効にできるかどうかがはっきりしないため。
- 全プール(control-plane、worker)に入れる。
- User Dataを書き換えるとプールのVMが全て作り直される。SSD用のイメージ・anti-affinityの変更と
  1回にまとめる([manual-harvester-etcd-ssd.md](manual-harvester-etcd-ssd.md)の「恒久対策」と
  「既存クラスタに入れる場合の注意」)。

## 実施記録

| 日付 | クラスタ | 対象 | 補正前のずれ(分かったもの) |
|---|---|---|---|
| 2026-10-08 | dev1 | 全8台 | mbjvt 92秒、mq45p 109秒、pn8dq 117秒、td4mg 140秒 |
| 2026-10-08 | prod1 | 全8台 | 作成から7時間で、ずれはまだ小さかった |
| 2026-10-08 | prod1 | 恒久対策(全8台を入れ替え) | User Dataにchronyの設定を入れて入れ替えた。新しい8台とも`ntp-nict.sources`があり、`^*`で同期していることを確認 |
| 2026-10-09 | dev1 | 恒久対策(全8台を入れ替え) | User Dataにchronyの設定を入れて入れ替えた。入れ替え後、etcdのclock drift警告は0件、全ノードのLeaseの時刻が現在時刻と一致 |
