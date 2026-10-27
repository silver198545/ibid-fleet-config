#!/usr/bin/env python3
"""脆弱性チェックの結果をSlackへ送る文面にする(scripts/vuln-scan.sh --notify から呼ぶ)。

使い方: vuln_notify.py --env <env> --kind <apps|sites> --baseline <前回のキー一覧> --baseline-out <今回の分>
          --enforce <0|1> [--url <RundeckのログURL>] --payload-out <SlackへのJSON>
          --summary "<name> <NG数> <警告数>"... --findings <vuln_report.py --findings-out のJSON>...

前回(--baseline)に無かったNG・警告を「新たに見つかったもの」として並べる。NGは1件ずつ(同じパッケージ・版・番号は
1行にまとめ、該当するアプリ・サイトを後ろに書く。サイトは同じイメージ・プラグインのものが多いため)、
警告はパッケージごとに件数でまとめる(初回などに数十件並んで読めなくならないように。詳細はログ)。
"""
import argparse
import datetime
import json
import os

MAX_NEW = 25
MAX_INFO = 15


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", required=True)
    ap.add_argument("--kind", required=True)
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--baseline-out", required=True)
    ap.add_argument("--enforce", default="0")
    ap.add_argument("--url", default="")
    ap.add_argument("--payload-out", required=True)
    ap.add_argument("--summary", nargs="*", default=[])
    ap.add_argument("--findings", nargs="*", default=[])
    a = ap.parse_args()

    findings = []
    for f in a.findings:
        if os.path.exists(f):
            findings += json.load(open(f))
    current = {x["key"] for x in findings if x["level"] in ("NG", "WARN")}
    first = not os.path.exists(a.baseline)
    before = set() if first else set(json.load(open(a.baseline)))
    new_keys = current - before
    resolved = len(before - current)

    rows = [s.split() for s in a.summary]
    total_ng = sum(int(r[1]) for r in rows)
    total_warn = sum(int(r[2]) for r in rows)

    # 新たに見つかったもの。NGは (source, pkg, 版, id) ごと、警告は (source, pkg) ごとにまとめる
    ng_groups, warn_groups = {}, {}
    for x in findings:
        if x["key"] not in new_keys:
            continue
        if x["level"] == "NG":
            g = ng_groups.setdefault((x["source"], x["pkg"], x["version"], x["id"], x["title"]), {"x": x, "targets": []})
        else:
            g = warn_groups.setdefault((x["source"], x["pkg"] or x["title"]), {"x": x, "targets": [], "ids": set()})
            g["ids"].add(x["id"] or x["title"])
        if x["target"] not in g["targets"]:
            g["targets"].append(x["target"])
    new_ng = len(ng_groups)
    new_warn = sum(len(g["ids"]) for g in warn_groups.values())

    def where(ts):
        return ts[0] if len(ts) == 1 else f"{ts[0]} ほか{len(ts) - 1}"

    lines = [f"*脆弱性チェック({a.env} {a.kind})* {datetime.date.today()}  "
             f"NG {total_ng}件・警告 {total_warn}件(対象 {len(rows)})"]
    if first:
        lines.append("初回のため、見つかったものをすべて新規として扱います。")
    lines.append(f"前回から: 新たに NG {new_ng}件・警告 {new_warn}件 / 解消 {resolved}件")

    ng_targets = [r for r in rows if int(r[1]) > 0]
    if ng_targets:
        lines.append("")
        lines.append("*NGのあるもの*")
        lines += [f"• {r[0]}: NG {r[1]}・警告 {r[2]}" for r in ng_targets]

    if ng_groups:
        lines.append("")
        lines.append("*新たに見つかったNG*")
        for (source, pkg, version, vid, title), g in sorted(ng_groups.items())[:MAX_NEW]:
            x = g["x"]
            if source == "note":
                lines.append(f"• {title} — {where(g['targets'])}")
            else:
                fix = f" → {x['fixed']}" if x["fixed"] else "(修正版なし)"
                lines.append(f"• [{source}] {pkg} {version}{fix} {vid} {title[:60]} — {where(g['targets'])}")
        if len(ng_groups) > MAX_NEW:
            lines.append(f"...ほか{len(ng_groups) - MAX_NEW}件(ログを参照)")
    if warn_groups:
        lines.append("")
        lines.append("*新たに見つかった警告*(パッケージごとの件数。詳細はログ)")
        ordered = sorted(warn_groups.items(), key=lambda kv: (-len(kv[1]["ids"]), kv[0]))
        for (source, pkg), g in ordered[:MAX_NEW]:
            label = g["x"]["title"] if source == "note" else f"[{source}] {pkg}"
            count = f"{len(g['ids'])}件" if source != "note" else ""
            lines.append(f"• {label} {count} — {where(g['targets'])}".replace("  ", " "))
        if len(ordered) > MAX_NEW:
            lines.append(f"...ほか{len(ordered) - MAX_NEW}パッケージ(ログを参照)")

    info = [x for x in findings if x["level"] == "INFO"]
    if info:
        lines.append("")
        lines.append("*更新を促すもの*")
        lines += [f"• {x['target']}: {x['title']}" for x in info[:MAX_INFO]]
        if len(info) > MAX_INFO:
            lines.append(f"...ほか{len(info) - MAX_INFO}件")

    lines.append("")
    lines.append(("enforce: true(NGで本番への昇格を止めます)" if a.enforce == "1"
                  else "enforce: false(記録・通知だけ。昇格は止めません)") + "。基準: qa/vuln-policy.yaml")
    if a.url.startswith("http"):
        lines.append(f"詳細: {a.url}")

    json.dump({"text": "\n".join(lines)}, open(a.payload_out, "w"), ensure_ascii=False)
    json.dump(sorted(current), open(a.baseline_out, "w"))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
