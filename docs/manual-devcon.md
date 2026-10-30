# dev/staging確認用デスクトップ(devcon)

開発者がdev/stagingのサイト・アプリ(`*.dev.ibid.lan` / `*.staging.ibid.lan`)の動作を確かめるための、
Apache Guacamoleから使うデスクトップVM。クラスタのネットワーク(v140)は利用者の端末から見えないため、
このVMの中のFirefoxで見る。アプリを足しても、Ingressを書けばそのまま見られる
(外部Nginxへの設定追加・公開制限・グローバルドメインの申請は要らない)。

- 用途は**動作確認だけ**(日常的な編集には使わない)。本番の公開(外部Nginx)とは無関係。
- VM・FreeIPA・Guacamoleはこのリポジトリの管理外。本書は構築時(2026-10-28)の記録と再構築の手順。
- 利用者側の準備(CA証明書・プロキシ・DNS)は不要。Guacamoleにログインするだけ。
- rancherにSSHできる人(Rundeckのオペレータなど)は、devconを使わずに、rancherを経由するSOCKSプロキシで手元のブラウザから
  見ることもできる([runbook/rundeck-app-operator.md](runbook/rundeck-app-operator.md) 初回設定の5.)。

```
利用者のブラウザ ──> Guacamole(192.168.1.236) ──RDP──> devcon(192.168.1.8) ──> Traefik(dev1 .33 / staging1 .50)
                                                     └─ DNS・CA・ログインはFreeIPA(192.168.100.21/22)
```

## 1. 構成

| 項目 | 値 |
|---|---|
| ホスト名 | `devcon.ibid.lan` |
| IP | `192.168.1.8/24`(ens192、v140、GW `192.168.1.240`)/ `192.168.100.8/24`(ens224、FreeIPA側) |
| 基盤 | VMware(Harvesterではない。Harvesterのホストはメモリに余裕がないため) |
| リソース | 16 vCPU / 31GiB / 70GB(基盤の都合。必要量は2 vCPU・4〜6GiB・40GB程度で、同時に2〜3人まで) |
| OS | AlmaLinux 9.8。既定ターゲットは `multi-user.target`(gdm等は無し、xrdpのセッションだけで使う) |
| デスクトップ | Xfce(EPEL)+ xrdp / xorgxrdp(EPEL)。コンポジット無効 |
| ブラウザ | Firefox ESR(AppStream)。FreeIPA CAをポリシーで信頼させる |
| 日本語入力 | ibus-anthy(`fcitx5-mozc` はEPEL 9に無い) |
| ログイン | FreeIPA(SSSD)。HBACルール `allow_devcon` で `devcon_users` グループだけ |
| SELinux | enforcing |

確認先と経路(構築時にすべて開通を確認済み):

| 宛先 | 用途 |
|---|---|
| `192.168.1.33:443` / `192.168.1.50:443` | dev1 / staging1のTraefik |
| `192.168.100.21` / `.22` の 53, 88, 389, 443, 464, 636/tcp | FreeIPA(DNS・Kerberos・LDAP) |
| Guacamole(`192.168.1.236`)→ devcon:3389 | RDP |

## 2. 構築手順

### 2.1 パッケージ

`@Xfce` グループは使わない(gdm・電源管理・スクリーンセーバー・音声プラグインまで入るため)。

```bash
dnf install -y --setopt=install_weak_deps=False \
  xfce4-session xfce4-panel xfce4-settings xfconf xfdesktop xfwm4 Thunar tumbler \
  xfce4-terminal xfce4-appfinder xfce-polkit \
  dbus-x11 xorg-x11-xinit xorg-x11-xauth \
  xrdp xorgxrdp xrdp-selinux \
  firefox \
  langpacks-ja google-noto-sans-cjk-ttc-fonts google-noto-serif-cjk-ttc-fonts google-noto-emoji-color-fonts \
  ibus ibus-anthy ibus-gtk3 ibus-gtk2
systemctl enable --now xrdp
```

前提: EPEL・CRBが有効、`ipa-client` でFreeIPAに参加済み(`access_provider = ipa`)。

### 2.2 FreeIPA(管理者がibidipa1で実行)

```bash
ipa hbacsvc-add xrdp-sesman --desc="xrdp (RDP) login"
ipa group-add devcon_users --desc="devcon(dev/staging確認用デスクトップ)の利用者"
ipa group-add-member devcon_users --users=<開発者>,...
ipa hbacrule-add allow_devcon --desc="devcon_users -> devcon.ibid.lan (xrdp)"
ipa hbacrule-add-user allow_devcon --groups=devcon_users
ipa hbacrule-add-host allow_devcon --hosts=devcon.ibid.lan
ipa hbacrule-add-service allow_devcon --hbacsvcs=xrdp-sesman
# 確認(許可/拒否が想定どおりか)
ipa hbactest --user=<ユーザー> --host=devcon.ibid.lan --service=xrdp-sesman
```

**利用者を足す・外すのは `ipa group-add-member` / `group-remove-member devcon_users` だけ**でよい。

### 2.3 xrdp

`/etc/xrdp/sesman.ini`(既定からの変更点):

```diff
-EnableUserWindowManager=true
+EnableUserWindowManager=false
-DefaultWindowManager=startwm-bash.sh
+DefaultWindowManager=/usr/local/bin/xrdp-startxfce
-AllowRootLogin=true
+AllowRootLogin=false
-MaxSessions=50
+MaxSessions=10
-DisconnectedTimeLimit=0
+DisconnectedTimeLimit=28800
-Policy=Default
+Policy=UB
 [Chansrv]
+EnableFuseMount=false
```

- `EnableUserWindowManager=false`: `~/.Xclients` 等に頼らず、全員同じスクリプトでXfceを起動する。
- `DisconnectedTimeLimit=28800`: 切断したままのセッションは8時間で終了する。
- `Policy=UB`: 同じユーザーなら、画面サイズが違っても同じセッションに再接続する。
- `EnableFuseMount=false`: ドライブ転送を使わないので `~/thinclient_drives` を作らせない。

`/etc/xrdp/xrdp.ini` の `[Channels]` で `rdpdr=false`(ドライブ転送)・`rdpsnd=false`(音声)。
TLSは既定(`TLSv1.2, TLSv1.3`)、証明書はxrdpの自己署名のまま(Guacamole側で `ignore-cert`)。

`/usr/local/bin/xrdp-startxfce`(0755)。**置き場所は `/usr/local/bin` にする**: `/etc/xrdp/`(`etc_t`)や
`/usr/local/libexec/`(`usr_t`)に置くと、SELinux enforcingで `entrypoint` が拒否される。`bin_t` になる場所が必要。

```bash
#!/bin/bash
# xrdp セッションの起動スクリプト(sesman.ini の DefaultWindowManager から呼ばれる)
# 全ユーザー共通で Xfce を起動する。~/.Xclients や ~/startwm.sh には頼らない。
[ -r /etc/profile ] && . /etc/profile
[ -r /etc/locale.conf ] && . /etc/locale.conf
export LANG=${LANG:-ja_JP.UTF-8}
export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce DESKTOP_SESSION=xfce
# xrdp 向けの Xfce 既定値(コンポジット無効など)を先に読ませる
export XDG_CONFIG_DIRS=/etc/xrdp/xdg:/etc/xdg
# 日本語入力(ibus-anthy)
export GTK_IM_MODULE=ibus QT_IM_MODULE=ibus XMODIFIERS=@im=ibus
exec dbus-run-session -- startxfce4
```

`/etc/xrdp/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml`(xrdp越しでは重いのでコンポジットを切る):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
```

### 2.4 日本語入力

`/etc/xdg/autostart/ibus-daemon.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=IBus
Exec=ibus-daemon --daemonize --xim --replace
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
```

`/etc/dconf/db/local.d/10-ibus-devcon`(作ったあとに `dconf update`。ユーザーが変えた値が優先される):

```ini
[desktop/ibus/general]
preload-engines=['xkb:jp::jpn', 'anthy']
engines-order=['xkb:jp::jpn', 'anthy']

[desktop/ibus/general/hotkey]
triggers=['Zenkaku_Hankaku', '<Control>space', '<Super>space']
```

### 2.5 Firefox

`/etc/firefox/policies/policies.json`。Linux版では `ImportEnterpriseRoots` が効かないので
`Certificates.Install` でFreeIPA CAを読ませる。**DNS over HTTPSは必ず無効にして固定する**
(有効だとFreeIPAのDNSを迂回し、`*.dev.ibid.lan` 等が引けない)。

```json
{
  "policies": {
    "Certificates": { "Install": ["/etc/ipa/ca.crt"] },
    "DNSOverHTTPS": { "Enabled": false, "Locked": true },
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DisableAppUpdate": true,
    "DisableProfileImport": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "UserMessaging": {
      "WhatsNew": false, "ExtensionRecommendations": false, "FeatureRecommendations": false,
      "UrlbarInterventions": false, "SkipOnboarding": true, "MoreFromMozilla": false, "FirefoxLabs": false
    },
    "RequestedLocales": ["ja", "en-US"],
    "Homepage": { "URL": "file:///usr/local/share/devcon/index.html", "StartPage": "homepage" }
  }
}
```

ホームページ(`/usr/local/share/devcon/index.html`)は、dev/stagingのURLの形と日本語入力の切り替え方を載せた静的ページ。

### 2.6 OTPトークンを持つ利用者向けのSSSD設定

`/etc/sssd/sssd.conf` の末尾に追加(xrdpはPAMのすべての質問に同じパスワードを答えるため、2要素の質問を1つにまとめる):

```ini
[prompting/2fa/xrdp-sesman]
single_prompt = True
first_prompt = Password (+OTP):
```

`/etc/pam.d/xrdp-sesman` はパッケージの既定のまま(`password-auth` をinclude)。
`pam_sss use_first_pass` にする方法は、OTPの質問に答えられず1回で2回失敗が記録されるので使わない。

### 2.7 firewalld

`public` ゾーン(ens192・ens224の両方)で、全体向けの `ssh` サービスを外し、次の2つだけ受け付ける。

```xml
<rule family="ipv4">
  <source address="192.168.1.240/32"/>   <!-- 管理用の接続元 -->
  <service name="ssh"/>
  <accept/>
</rule>
<rule family="ipv4">
  <source address="192.168.1.236/32"/>   <!-- Guacamole -->
  <port port="3389" protocol="tcp"/>
  <accept/>
</rule>
```

### 2.8 SELinux

作業前は `disabled` だった。`SELINUX=permissive` にして `/.autorelabel` を置いて再起動し、AVCが出ないことを
確かめてから `setenforce 1`、設定ファイルも `enforcing` にした。xrdpは `unconfined_service_t` で動き、
`xrdp-selinux` が必要な許可を足す。

### 2.9 自動更新

`dnf-automatic.timer` は有効だが、**ダウンロードと通知だけ**にしている(適用は管理者が手動。
過去にFreeIPAサーバーでdnf-automaticの無人更新が障害を起こしたため)。`/etc/dnf/automatic.conf`:

```diff
-apply_updates = yes
+apply_updates = no
-emit_via = email
+emit_via = motd,stdio
```

更新の有無はログイン時のmotdと `journalctl -u dnf-automatic` に出る。

## 3. Guacamoleの接続設定

| 項目 | 値 |
|---|---|
| プロトコル / ホスト / ポート | RDP / `192.168.1.8` / `3389` |
| ユーザ名 / パスワード | `${GUAC_USERNAME}` / `${GUAC_PASSWORD}`(ドメインは空) |
| セキュリティモード | Any、サーバ証明書を無視する: 有効 |
| キーボードレイアウト | Japanese (Qwerty)(`ja-jp-qwerty`) |
| タイムゾーン | Asia/Tokyo |
| サイズ変更方法 | `display-update` |
| 音声 / ドライブ転送 | 無効 |
| クリップボード | LF、コピー・貼り付けとも許可 |

**guacdの修正(Guacamole 1.5.5)**: guacdはユーザー `daemon`(ホーム `/sbin`)で動き、FreeRDPが
`~/.config/freerdp` を作れず、TLSを始める前に `Security negotiation failed` で失敗する
(ログに `The current user's home directory ("/sbin") is not writable`)。書き込めるHOMEを渡す:

```bash
install -d -o daemon -g daemon -m 0700 /var/lib/guacd
mkdir -p /etc/systemd/system/guacd.service.d
cat > /etc/systemd/system/guacd.service.d/home.conf <<'EOF'
[Service]
Environment=HOME=/var/lib/guacd
EOF
systemctl daemon-reload && systemctl restart guacd
```

## 4. 使い方(利用者向け)

1. Guacamoleにログインし、接続 `devcon` を開く。
   - OTPトークンが無い人: そのままXfceが表示される。
   - OTPトークンがある人: 自動ログインが1回失敗してxrdpのログイン画面が出るので、
     パスワードに続けてOTPの6桁を入力する(下の注意を参照)。
2. Firefoxで `https://<site>.dev.ibid.lan/<ja|en>/`、`https://<app>.dev.ibid.lan/`
   (stagingは `.staging.ibid.lan`)を開く。
3. 日本語入力は「半角/全角」か `Ctrl+Space` で切り替える。コピー&ペーストはGuacamoleのクリップボード
   (`Ctrl+Alt+Shift`)経由。

**OTPトークンを持つ人の注意**: トークンを持つ人にはKDCがOTPだけを求めるが、Guacamoleへのログインは
パスワードだけで通る(LDAP)。そのため自動ログイン(`${GUAC_PASSWORD}`)が毎回1回失敗し、
**FreeIPAのロックの回数に数えられる**。対象者が増えるなら、接続のパスワード欄を空にして全員がログイン画面で
入力する方式に変えることを検討する。

## 5. 残っている課題

- OTPトークンを持つ人の自動ログインの失敗(上記)。
- リソースが必要量より大きい(基盤の都合で減らすなら2 vCPU・4〜6GiB程度)。
- 作業前から有効だったremiリポジトリはdevconでは使っていない(無効にしてよいか確認する)。
- xrdpの証明書は自己署名のまま(必要ならcertmongerでFreeIPAの証明書に替えられる)。
- devのWordPressは公開URLが全サイト共通の `wpdev1.brc.riken.jp` のため、devconから内部名で開いても
  正しく表示されない。内部名(`https://<site>.dev.ibid.lan/<ja|en>`)への切り替えが必要
  ([manual-wordpress-restore.md](manual-wordpress-restore.md) 6b)。
