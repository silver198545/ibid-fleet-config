#!/usr/bin/env python3
"""devのサイトのfleet.yamlにあるプラグインのバージョン固定を、WordPress.orgの最新版へ上げる。

scripts/bump-plugins.sh(書き換え)と scripts/plugin-check.sh(確認だけ)から呼ばれる。fleet.yaml の
helm.values.plugins の
    - name: <slug>
      version: "<version>"
の組だけを書き換える(コメントや他の行はそのまま残すため、YAMLを読み直して書き出すことはしない)。
version を指定していないプラグインは対象外。

最新版の「必要なWordPressのバージョン(requires)」がチャートの appVersion
(イメージのWordPressのバージョン)より新しい場合は上げない。WordPress.orgで公開停止された
プラグインは警告を出して飛ばす。既存より古い版には下げない。

使い方:
  plugin_updates.py <WordPressのバージョン> <fleet.yaml>...
      fleet.yaml を書き換え、変更内容のMarkdown(PR本文用。変更が無ければ空)を標準出力に出す
  plugin_updates.py --check-out <JSON> [--installed-dir <dir>] [--wordfence <フィード>] <WordPressのバージョン> <fleet.yaml>...
      書き換えずに、サイトごとのプラグインの状態をJSONに書き出す(scripts/plugin-check.sh → plugin_notify.py)。
      --installed-dir の <dir>/<site>.json(devのPodの wp plugin list)があれば、devに実際に入っている版を基準にし、
      Gitの固定と違うもの(devの管理画面で更新・追加・削除し、まだGitに取り込んでいないもの)も出す。
      無ければGitの固定の版を基準にする。
      --wordfence(Wordfence Intelligenceのproductionフィード)があれば、devと本番
      (envs/production/sites/<site>/fleet.yaml)で使っている版の脆弱性(Critical・High)も調べる。
      判定は scripts/lib/vuln_report.py と同じ(qa/vuln-policy.yaml の基準)。
"""
import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

PAIR = re.compile(r'(?m)^(\s*- name: )([a-z0-9-]+)(\n\s+version: ")([^"]+)(")')
API = "https://api.wordpress.org/plugins/info/1.2/"


def vkey(v):
    """'2.5.3.4' や '10.0' を比較できる形にする(数字以外の部分は文字列として比べる)。"""
    return [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in re.split(r"[.\-]", v)]


def newer(a, b):
    """a が b より新しければ True。"""
    ka, kb = vkey(a), vkey(b)
    n = max(len(ka), len(kb))
    ka += [(0, 0, "")] * (n - len(ka))
    kb += [(0, 0, "")] * (n - len(kb))
    return ka > kb


def plugin_info(slug):
    query = urllib.parse.urlencode({
        "action": "plugin_information",
        "request[slug]": slug,
        "request[fields][sections]": 0,
        "request[fields][versions]": 0,
    })
    with urllib.request.urlopen(f"{API}?{query}", timeout=30) as resp:
        return json.load(resp)


def site_of(path):
    return path.rstrip("/").split("/")[-2]


def latest_versions(slugs, wp_version):
    """slug → 上げられる最新版。上げられないもの(WordPressの版が足りない)は blocked に入れる。"""
    latest, blocked = {}, {}
    for slug in slugs:
        try:
            info = plugin_info(slug)
        except Exception as e:  # 公開停止(404)・一時的な障害
            print(f"警告: {slug}: WordPress.orgから情報を取れません({e})。飛ばします。", file=sys.stderr)
            continue
        if "error" in info or not info.get("version"):
            print(f"警告: {slug}: {info.get('error', '版が不明')}。飛ばします。", file=sys.stderr)
            continue
        requires = info.get("requires") or ""
        if requires and newer(requires, wp_version):
            print(f"警告: {slug} {info['version']} はWordPress {requires}以上が必要"
                  f"(現在{wp_version})。飛ばします。", file=sys.stderr)
            blocked[slug] = {"version": info["version"], "requires": requires}
            continue
        latest[slug] = info["version"]
    return latest, blocked


def vulns_of(idx, vcmp_in_range, slug, version):
    """その版に当たる脆弱性(Critical・High)。vuln_report.check_wp と同じ基準。"""
    found = []
    for v, s in idx.get(("plugin", slug), []):
        if not any(vcmp_in_range(version, r) for r in (s.get("affected_versions") or {}).values()):
            continue
        rating = ((v.get("cvss") or {}).get("rating") or "").capitalize()
        if rating not in ("Critical", "High"):
            continue
        found.append({
            "rating": rating.upper(),
            "id": v.get("cve") or v.get("id", "?"),
            "title": v.get("title") or "",
            "patched": (s.get("patched_versions") or []) if s.get("patched") else [],
        })
    return found


def check(wp_version, files, out, feed, installed_dir=None):
    contents = {f: open(f, encoding="utf-8").read() for f in files}
    pairs = {f: [(m.group(2), m.group(4)) for m in PAIR.finditer(t)] for f, t in contents.items()}

    # devに実際に入っているもの(must-use・dropin・WordPress.orgの名前の形でないものは除く)
    installed = {}
    if installed_dir:
        for f in files:
            p = os.path.join(installed_dir, f"{site_of(f)}.json")
            if os.path.exists(p):
                installed[site_of(f)] = {x["name"]: x for x in json.load(open(p))
                                         if x.get("status") not in ("must-use", "dropin")
                                         and re.match(r"^[a-z0-9-]+$", x.get("name", ""))}

    slugs = sorted({slug for ps in pairs.values() for slug, _ in ps}
                   | {slug for inv in installed.values() for slug in inv})
    latest, blocked = latest_versions(slugs, wp_version)

    idx = in_range = None
    if feed:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import vuln_report  # PyYAMLが要るので、脆弱性を調べるときだけ読む
        idx, in_range = vuln_report.wordfence_index(feed), vuln_report.in_range

    sites = {}
    for f, ps in pairs.items():
        site = site_of(f)
        pinned = dict(ps)
        inv = installed.get(site)
        prod_file = os.path.join("envs/production/sites", site, "fleet.yaml")
        prod = {}
        if os.path.exists(prod_file):
            prod = {m.group(2): m.group(4) for m in PAIR.finditer(open(prod_file, encoding="utf-8").read())}
        names = list(pinned) + sorted(set(inv or {}) - set(pinned))
        rows = []
        for slug in names:
            pin = pinned.get(slug, "")
            if inv is not None:
                cur = inv[slug]["version"] if slug in inv else ""
                # Gitへの取り込み待ち: 追加(Gitに無い)・更新(版が違う)・削除(devに無い)
                if not pin:
                    state = "added"
                elif not cur:
                    state = "removed"
                elif cur != pin:
                    state = "changed"
                else:
                    state = ""
                if slug not in latest and slug not in blocked and state == "added":
                    state = "unmanaged"  # WordPress.orgに無い(Gitで管理できない)
            else:
                cur, state = pin, ""
            new = latest.get(slug)
            row = {"slug": slug, "current": cur, "pinned": pin, "uncaptured": state,
                   "latest": new if cur and new and newer(new, cur) else "",
                   "blocked": blocked.get(slug) if cur and slug in blocked and newer(blocked[slug]["version"], cur) else None,
                   "production": prod.get(slug, ""), "vulns": [], "production_vulns": []}
            if idx is not None:
                if cur:
                    row["vulns"] = vulns_of(idx, in_range, slug, cur)
                if row["production"] and row["production"] != cur:
                    row["production_vulns"] = vulns_of(idx, in_range, slug, row["production"])
            if row["latest"] or row["blocked"] or row["vulns"] or row["production_vulns"] or row["uncaptured"]:
                rows.append(row)
        sites[site] = rows

    declared = {site_of(f): len(ps) for f, ps in pairs.items()}
    json.dump({"wp_version": wp_version, "checked_vulns": idx is not None, "checked_installed": bool(installed),
               "declared": declared, "sites": sites},
              open(out, "w"), ensure_ascii=False, indent=1)


def bump(wp_version, files):
    contents = {f: open(f, encoding="utf-8").read() for f in files}
    slugs = sorted({m.group(2) for text in contents.values() for m in PAIR.finditer(text)})
    latest, _ = latest_versions(slugs, wp_version)

    changes = {}  # (slug, old, new) -> [site...]
    for f, text in contents.items():
        site = site_of(f)

        def repl(m):
            slug, old = m.group(2), m.group(4)
            new = latest.get(slug)
            if not new or not newer(new, old):
                return m.group(0)
            changes.setdefault((slug, old, new), []).append(site)
            return f"{m.group(1)}{slug}{m.group(3)}{new}{m.group(5)}"

        updated = PAIR.sub(repl, text)
        if updated != text:
            with open(f, "w", encoding="utf-8") as out:
                out.write(updated)

    for (slug, old, new), sites in sorted(changes.items()):
        print(f"- `{slug}`: {old} → {new}({', '.join(sorted(sites))})")


def main():
    ap = argparse.ArgumentParser(description="devのサイトのプラグインの版を最新へ上げる・確認する")
    ap.add_argument("--check-out", help="書き換えずに、更新できるものをこのJSONに書き出す")
    ap.add_argument("--wordfence", help="Wordfenceのproductionフィード(--check-out のときだけ使う)")
    ap.add_argument("--installed-dir", help="devのPodの wp plugin list(<site>.json)を置いたディレクトリ(--check-out のときだけ使う)")
    ap.add_argument("wp_version")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    if a.check_out:
        check(a.wp_version, a.files, a.check_out, a.wordfence, a.installed_dir)
    else:
        bump(a.wp_version, a.files)


if __name__ == "__main__":
    main()
