# 運用手順書(ランブック)

日常の運用で使う手順だけをまとめたもの。背景や設計の説明は [docs/](../) の詳しい手順書を参照する。

| 手順書 | 使う場面 |
|---|---|
| [wordpress-new-site.md](wordpress-new-site.md) | WordPressサイトを新しく作る |
| [wordpress-update.md](wordpress-update.md) | WordPress本体・MariaDB・プラグインを更新する、本番へ反映する |
| [app-new.md](app-new.md) | 自作アプリを新しく展開する |
| [app-update.md](app-update.md) | 自作アプリを更新する、本番へ反映する |
| [troubleshooting.md](troubleshooting.md) | うまく動かないとき |

## 共通の前提

- 作業端末に `git`・`gh`(認証済み)・`kubectl`(コンテキスト `dev1` / `prod1` / `local`)・`kubeseal` があること
  ([manual-tooling-setup.md](../manual-tooling-setup.md))
- コマンドはリポジトリのルートで、`main` を最新にしてから実行する: `git checkout main && git pull`
- 変更はすべて **dev → 確認 → production** の順に流す。本番を直接書き換えない
- dev だけに触れるPRは CI(validate)が通れば自動でマージされる。**本番に触れるPRは必ず人が差分を見てマージする**
- 名前の規則: サイトは `<site>`(例: `web`)、ホスト名は `<site>.dev.ibid.lan` / `<site>.production.ibid.lan`。
  DNSはワイルドカードなので登録作業は無い

## 本番のバックアップ(本番に反映する前に毎回)

```bash
TS=$(date +%Y%m%d%H%M)
for s in $(ls envs/production/sites); do
  kubectl --context prod1 -n wordpress-$s create job --from=cronjob/wordpress-$s-backup wordpress-$s-backup-manual-$TS
done
kubectl --context prod1 get jobs -A | grep backup-manual-$TS    # 全部 Complete になるまで待つ
```

1サイトだけなら `for` を外して `s=<site>` で実行する。
