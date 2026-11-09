#!/usr/bin/env python3
"""プラグインの確認結果(plugin_updates.py --check-out のJSON)を、Slackへ送る文面にする。
scripts/plugin-check.sh から呼ぶ。

使い方: plugin_notify.py --report <JSON> [--url <RundeckのログURL>] [--payload-out <SlackへのJSON>]

運用(2026-11-09〜): サイトの管理者がdevの管理画面でプラグインを更新して確かめ、Rundeckの 0-dev-plugin-capture で
Gitに取り込み、staging → 本番へ昇格する。この通知はその判断材料で、次の順に並べる。
  1. :rotating_light: devで脆弱性(Critical・High)のある版を使っているもの
  2. :warning: 本番の版に脆弱性があり、devでは直っているもの(昇格待ち)
  3. :memo: devで更新・追加・削除・有効/無効の切り替えをしたが、まだGitに取り込んでいないもの
  4. 新しい版があるもの
脆弱性の詳細(番号・内容)はSlackとRundeckのログにだけ出す(このリポジトリはpublicなので、GitHubには出さない)。
"""
import argparse
import datetime
import json

MAX_LINES = 40


def vuln_text(vs):
    worst = sorted(vs, key=lambda v: v["rating"] != "CRITICAL")[0]
    more = f" ほか{len(vs) - 1}件" if len(vs) > 1 else ""
    return f"{worst['rating']} {worst['id']} {worst['title'][:60]}{more}"


def capped(lines, items, fmt, unit="件"):
    for it in items[:MAX_LINES]:
        lines.append(fmt(it))
    if len(items) > MAX_LINES:
        lines.append(f"...ほか{len(items) - MAX_LINES}{unit}(ログを参照)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--url", default="")
    ap.add_argument("--payload-out")
    a = ap.parse_args()

    r = json.load(open(a.report))
    sites = r["sites"]
    rows = [(s, x) for s, xs in sorted(sites.items()) for x in xs]

    updatable = {}
    for s, x in rows:
        if x["latest"]:
            updatable.setdefault(s, []).append(x)
    vulnerable = [(s, x) for s, x in rows if x["vulns"]]
    prod_only = [(s, x) for s, x in rows if x["production_vulns"] and not x["vulns"]]
    uncaptured, unmanaged = {}, {}
    for s, x in rows:
        if x["uncaptured"] == "unmanaged":
            unmanaged.setdefault(x["slug"], []).append(s)
        elif x["uncaptured"]:
            uncaptured.setdefault(s, []).append(x)

    base = "devに入っている版" if r.get("checked_installed") else "Gitで固定している版(devのPodを読めなかった)"
    lines = [f"*WordPressプラグインのお知らせ(dev)* {datetime.date.today()}  WordPress {r['wp_version']} 基準",
             f"対象 {len(sites)}サイト({base}で判定)。新しい版のあるサイト {len(updatable)}・"
             f"プラグイン {sum(len(v) for v in updatable.values())}件 / Gitに未取り込みのサイト {len(uncaptured)}"]

    if vulnerable:
        lines += ["", ":rotating_light: *脆弱性のある版を使っているもの(早めにdevの管理画面で更新し、取り込んで本番へ)*"]

        def fmt_vuln(it):
            s, x = it
            if x["latest"]:
                how = f"{x['current']} → {x['latest']}"
            elif x["blocked"]:
                how = f"{x['current']}(最新 {x['blocked']['version']} はWordPress {x['blocked']['requires']}以上が必要。管理者に相談)"
            else:
                how = f"{x['current']}(更新できる版がありません。削除・置換を検討)"
            return f"• *{s}*: `{x['slug']}` {how} — {vuln_text(x['vulns'])}"
        capped(lines, vulnerable, fmt_vuln)

    if prod_only:
        lines += ["", ":warning: *本番の版に脆弱性があり、devでは直っているもの(Gitへの取り込み・本番への昇格を進めてください)*"]
        capped(lines, prod_only, lambda it: f"• *{it[0]}*: `{it[1]['slug']}` 本番 {it[1]['production']} / "
                                            f"dev {it[1]['current'] or '(削除済み。本番では手で削除)'} — {vuln_text(it[1]['production_vulns'])}")

    if uncaptured:
        lines += ["", ":memo: *devで変更済み・Gitに未取り込み*(確認が済んだら `0-dev-plugin-capture` で取り込む)"]

        def fmt_unc(it):
            s, xs = it
            parts = []
            for x in xs:
                if x["uncaptured"] == "changed":
                    parts.append(f"{x['slug']} {x['pinned']}→{x['current']}")
                elif x["uncaptured"] == "added":
                    parts.append(f"{x['slug']} {x['current']}(追加)")
                elif x["uncaptured"] in ("activated", "deactivated"):
                    parts.append(f"{x['slug']}({'有効化' if x['uncaptured'] == 'activated' else '無効化'})")
                else:
                    parts.append(f"{x['slug']}(削除)")
            return f"• {s}: " + ", ".join(parts)
        capped(lines, sorted(uncaptured.items()), fmt_unc, "サイト")

    if updatable:
        lines += ["", "*新しい版があるもの*(devの管理画面で更新して確かめる)"]
        capped(lines, sorted(updatable.items()),
               lambda it: f"• {':rotating_light: ' if any(x['vulns'] for x in it[1]) else ''}{it[0]}: "
                          + ", ".join(f"{x['slug']} {x['current']}→{x['latest']}" for x in it[1]), "サイト")

    blocked = {}
    for s, x in rows:
        if x["blocked"] and not x["latest"]:
            blocked.setdefault((x["slug"], x["blocked"]["version"], x["blocked"]["requires"]), []).append(s)
    if blocked:
        lines += ["", "*WordPress本体の更新待ち*(最新版が今のWordPressより新しい版を必要とするもの。管理画面で更新しない)"]
        for (slug, ver, req), ss in sorted(blocked.items()):
            lines.append(f"• `{slug}` {ver}(WordPress {req}以上): {', '.join(sorted(ss))}")

    if not (vulnerable or prod_only or uncaptured or updatable or blocked):
        lines += ["", "対応が必要なものはありません。"]

    lines += ["", "流れ: devの管理画面で更新 → 動作を確認 → Rundeck(WordPressControl)の `0-dev-plugin-capture` でGitに取り込む"
                  " → `2-staging` → `3-production-promote`。"]
    if unmanaged:
        lines.append("WordPress.orgに無いためGitで管理していないもの(各環境の管理画面で更新): "
                     + ", ".join(f"{k}({', '.join(sorted(v))})" for k, v in sorted(unmanaged.items())))
    if not r["checked_vulns"]:
        lines.append("※ Wordfenceのフィードを使えなかったため(キーが無い・取得に失敗)、脆弱性は調べていません。ログを確認してください。")
    if a.url.startswith("http"):
        lines.append(f"詳細: {a.url}")

    text = "\n".join(lines)
    if a.payload_out:
        json.dump({"text": text}, open(a.payload_out, "w"), ensure_ascii=False)
    print(text)


if __name__ == "__main__":
    main()
