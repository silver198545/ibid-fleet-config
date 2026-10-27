#!/usr/bin/env python3
"""1つのアプリ・サイトの脆弱性を判定する(scripts/vuln-scan.sh から呼ぶ)。

使い方: vuln_report.py --policy qa/vuln-policy.yaml --name <name> [--trivy <trivyのJSON>...]
          [--unscanned <理由>...] [--info <情報>...] [--wp <wp-cliの一覧のJSON>] [--wordfence <フィードのJSON>]
          [--eol-cache <dir>] [--findings-out <file>] [--strict]

--trivy は Trivy(image --format json)の結果。--wp は scripts/vuln-scan.sh が wp-cli で取った
{"core": "<版>", "plugins": [...], "themes": [...]}(各要素は wp plugin/theme list の name・version・update_version)。
--wordfence は Wordfence Intelligence の scanner フィード(v3)。無ければWordPressの検査は警告にして飛ばす。
--unscanned は検査できなかったものの理由(警告。--strict(qa/vuln-policy.yaml の enforce: true)ならNG)。
--info は判定に数えない情報(上流の更新等)。
判定の基準は qa/vuln-policy.yaml の先頭のコメントと docs/manual-vuln-scan.md。
結果を1行ずつ表示し、最後に「VULN_RESULT <NGの数> <警告の数>」を出す。終了コードは常に0。
--findings-out にはNG・警告を1件ずつJSONで書き出す(週次の通知で前回と比べるため)。
"""
import argparse
import datetime
import json
import os
import re
import sys
import time
import urllib.request

import yaml

TODAY = datetime.date.today()

# イメージの環境変数(公式のnode・rubyイメージ)、Bitnamiの部品(/opt/bitnami/ のSPDX。Trivyの --list-all-pkgs が要る)
# → endoflife.date の製品名
RUNTIME_ENV = {"NODE_VERSION": "nodejs", "RUBY_VERSION": "ruby", "PHP_VERSION": "php"}
BITNAMI_PKGS = {"php": "php", "mariadb": "mariadb", "node": "nodejs"}
OS_PRODUCTS = {"debian": "debian", "ubuntu": "ubuntu", "alpine": "alpine-linux", "photon": "photon"}


def load_policy(path):
    p = yaml.safe_load(open(path)) or {}
    return p, p.get("ignore") or []


def ignored(rules, name, vid, pkg, path, expired):
    """除外に当たれば理由を返す。期限切れの除外は効かせず expired に積む。
    path はイメージ内のパッケージの場所(Trivyの PkgPath)の前方一致"""
    for r in rules:
        if r.get("id") != vid:
            continue
        if r.get("targets") and name not in r["targets"]:
            continue
        if r.get("pkg") and r["pkg"] != pkg:
            continue
        if r.get("path") and not (path or "").startswith(r["path"]):
            continue
        until = r.get("until")
        if isinstance(until, str):
            until = datetime.date.fromisoformat(until)
        if until and until < TODAY:
            expired.add(f"{vid}({until} まで)")
            continue
        return r.get("reason", "")
    return None


# ---------------------------------------------------------------------------
# EOL(endoflife.date。1日キャッシュする)
# ---------------------------------------------------------------------------

def eol_cycles(product, cache_dir):
    path = os.path.join(cache_dir, f"eol-{product}.json") if cache_dir else None
    if path and os.path.exists(path) and time.time() - os.path.getmtime(path) < 86400:
        return json.load(open(path))
    req = urllib.request.Request(f"https://endoflife.date/api/{product}.json", headers={"User-Agent": "ibid-vuln-scan"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    if path:
        os.makedirs(cache_dir, exist_ok=True)
        json.dump(data, open(path, "w"))
    return data


def eol_of(product, version, cache_dir):
    """(cycle, eol日付 or True/False) を返す。分からなければ None"""
    cycles = {c["cycle"]: c for c in eol_cycles(product, cache_dir)}
    nums = re.findall(r"\d+", version)
    for n in (2, 1):
        key = ".".join(nums[:n])
        if key in cycles:
            return key, cycles[key].get("eol")
    return None


def runtimes(trivy):
    """イメージから (表示名, 製品, 版) を取り出す"""
    out = []
    meta = trivy.get("Metadata", {})
    os_ = meta.get("OS") or {}
    if os_.get("Family") in OS_PRODUCTS and os_.get("Name"):
        out.append((f"{os_['Family']} {os_['Name']}", OS_PRODUCTS[os_["Family"]], os_["Name"]))
    env = dict(e.split("=", 1) for e in (meta.get("ImageConfig", {}).get("config", {}).get("Env") or []) if "=" in e)
    for k, product in RUNTIME_ENV.items():
        if env.get(k):
            out.append((f"{product} {env[k]}", product, env[k]))
    for r in trivy.get("Results") or []:
        if r.get("Type") != "bitnami":
            continue
        for p in r.get("Packages") or []:
            product = BITNAMI_PKGS.get(p.get("Name"))
            if product and p.get("Version") and all(o[1] != product for o in out):
                out.append((f"{p['Name']} {p['Version']}", product, p["Version"]))
    return out


# ---------------------------------------------------------------------------
# WordPress(Wordfence Intelligence の scanner フィード)
# ---------------------------------------------------------------------------

def vkey(v):
    key = []
    for p in re.split(r"[.\-+_]", str(v)):
        m = re.match(r"(\d+)(.*)", p)
        key.append((int(m.group(1)), m.group(2)) if m else (-1, p))
    return key


def vcmp(a, b):
    ka, kb = vkey(a), vkey(b)
    n = max(len(ka), len(kb))
    ka += [(0, "")] * (n - len(ka))
    kb += [(0, "")] * (n - len(kb))
    return (ka > kb) - (ka < kb)


def in_range(v, r):
    lo, hi = r.get("from_version", "*"), r.get("to_version", "*")
    if lo not in ("*", "", None):
        c = vcmp(v, lo)
        if c < 0 or (c == 0 and not r.get("from_inclusive", True)):
            return False
    if hi not in ("*", "", None):
        c = vcmp(v, hi)
        if c > 0 or (c == 0 and not r.get("to_inclusive", True)):
            return False
    return True


def wordfence_index(path):
    feed = json.load(open(path))
    idx = {}
    for vid, v in (feed.items() if isinstance(feed, dict) else enumerate(feed)):
        for s in v.get("software") or []:
            idx.setdefault((s.get("type"), s.get("slug")), []).append((v, s))
    return idx


# ---------------------------------------------------------------------------

class Report:
    def __init__(self, name, rules):
        self.name, self.rules = name, rules
        self.ng, self.warn, self.lines, self.findings = 0, 0, [], []
        self.expired, self.skipped = set(), {"ignored": 0, "os_nofix": 0, "low": 0}

    def add(self, level, source, pkg, version, fixed, vid, title, where="", path=""):
        reason = ignored(self.rules, self.name, vid, pkg, path, self.expired)
        if reason is not None:
            self.skipped["ignored"] += 1
            return
        if level == "NG":
            self.ng += 1
        else:
            self.warn += 1
        fix = f" → {fixed}" if fixed else "(修正版なし)"
        self.lines.append(f"{'NG ' if level == 'NG' else '警告'} [{source}] {pkg}@{version}{fix} {vid} {title[:80]}{where}")
        self.findings.append({"key": f"{self.name}|{source}|{pkg}|{vid}", "level": level, "target": self.name,
                              "source": source, "pkg": pkg, "version": version, "fixed": fixed or "",
                              "id": vid, "title": title[:120]})

    def note(self, level, text):
        if level == "NG":
            self.ng += 1
        elif level == "警告":
            self.warn += 1
        self.lines.append(f"{level:<3} {text}" if level != "--" else f"--  {text}")
        if level in ("NG", "警告"):
            self.findings.append({"key": f"{self.name}|note|{text}", "level": "NG" if level == "NG" else "WARN",
                                  "target": self.name, "source": "note", "pkg": "", "version": "", "fixed": "",
                                  "id": "", "title": text})


def check_trivy(rep, trivy, cache_dir, eol_warn_days):
    image = trivy.get("ArtifactName", "?")
    os_ = (trivy.get("Metadata", {}).get("OS") or {})
    rep.lines.append(f"== イメージ {image}" + (f"({os_.get('Family')} {os_.get('Name')})" if os_ else ""))
    if os_.get("EOSL"):
        rep.note("NG", f"OS {os_.get('Family')} {os_.get('Name')} はサポートが終了しています({image})")

    for label, product, version in runtimes(trivy):
        try:
            got = eol_of(product, version, cache_dir)
        except Exception as e:  # endoflife.date に届かなくても脆弱性の判定は続ける
            rep.note("--", f"{label}: EOLを確認できません({e})")
            continue
        if not got:
            continue
        cycle, eol = got
        if eol is True:
            rep.note("NG", f"{label}: サポート終了済み")
        elif isinstance(eol, str):
            days = (datetime.date.fromisoformat(eol) - TODAY).days
            if days < 0:
                rep.note("NG", f"{label}: {eol} にサポート終了済み")
            elif days < eol_warn_days:
                rep.note("警告", f"{label}: {eol} にサポート終了(あと{days}日)。{product} {cycle} より新しい版へ")
            else:
                rep.note("--", f"{label}: サポート終了 {eol}")

    seen = set()
    for r in trivy.get("Results") or []:
        cls = r.get("Class")
        for v in r.get("Vulnerabilities") or []:
            k = (cls, v["PkgName"], v["InstalledVersion"], v["VulnerabilityID"], v.get("PkgPath", ""))
            if k in seen:
                continue
            seen.add(k)
            sev, fixed = v.get("Severity"), v.get("FixedVersion", "")
            if sev not in ("CRITICAL", "HIGH"):
                rep.skipped["low"] += 1
                continue
            if cls == "lang-pkgs":
                if not fixed:
                    rep.skipped["low"] += 1  # 修正版の無い言語パッケージは追えないので数えない
                    continue
                level = "NG" if sev == "CRITICAL" else "WARN"
                source = r.get("Type", "lib")
            elif cls == "os-pkgs":
                if not fixed:
                    rep.skipped["os_nofix"] += 1
                    continue
                level, source = "WARN", "os"
            else:
                continue
            rep.add(level, source, v["PkgName"], v["InstalledVersion"], fixed,
                    v["VulnerabilityID"], f"{sev} {v.get('Title') or ''}".strip(), path=v.get("PkgPath", ""))


def check_wp(rep, wp, feed_path):
    items = [("core", "wordpress", wp.get("core"), "")]
    items += [("plugin", p["name"], p.get("version"), p.get("update_version") or "") for p in wp.get("plugins") or []]
    items += [("theme", t["name"], t.get("version"), t.get("update_version") or "") for t in wp.get("themes") or []]
    rep.lines.append(f"== WordPress {wp.get('core') or '?'}・プラグイン{len(wp.get('plugins') or [])}・テーマ{len(wp.get('themes') or [])}")
    updates = [f"{n} {v}→{u}" for kind, n, v, u in items if u]
    if updates:
        rep.note("--", f"更新のあるプラグイン・テーマ {len(updates)}件: " + ", ".join(updates[:10]) + (" ..." if len(updates) > 10 else ""))
    if not feed_path:
        rep.note("警告", "Wordfenceのキーが無いため、WordPressのコア・プラグイン・テーマの脆弱性を検査していません")
        return
    idx = wordfence_index(feed_path)
    for kind, slug, version, _ in items:
        if not version:
            continue
        for v, s in idx.get((kind, slug), []):
            if not any(in_range(version, r) for r in (s.get("affected_versions") or {}).values()):
                continue
            rating = ((v.get("cvss") or {}).get("rating") or "").capitalize()
            if rating not in ("Critical", "High"):
                rep.skipped["low"] += 1
                continue
            fixed = ", ".join(s.get("patched_versions") or []) if s.get("patched") else ""
            level = "NG" if rating == "Critical" and fixed else "WARN"
            title = f"{rating.upper()} {v.get('title') or ''}"
            if not fixed:
                title += "(削除・置換を検討)" if kind != "core" else ""
            rep.add(level, f"wp-{kind}", slug, version, fixed, v.get("cve") or v.get("id", "?"), title)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--policy", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--trivy", nargs="*", default=[])
    ap.add_argument("--unscanned", action="append", default=[])
    ap.add_argument("--info", action="append", default=[])
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--wp")
    ap.add_argument("--wordfence")
    ap.add_argument("--eol-cache")
    ap.add_argument("--findings-out")
    a = ap.parse_args()

    policy, rules = load_policy(a.policy)
    rep = Report(a.name, rules)
    for msg in a.unscanned:
        rep.note("NG" if a.strict else "警告", f"検査できませんでした: {msg}")
    for msg in a.info:
        rep.note("--", msg)
        rep.findings.append({"key": f"{a.name}|info|{msg}", "level": "INFO", "target": a.name, "source": "info",
                             "pkg": "", "version": "", "fixed": "", "id": "", "title": msg})
    for f in a.trivy:
        check_trivy(rep, json.load(open(f)), a.eol_cache, int(policy.get("eol_warn_days", 180)))
    if a.wp:
        check_wp(rep, json.load(open(a.wp)), a.wordfence)
    for e in sorted(rep.expired):
        rep.note("警告", f"qa/vuln-policy.yaml の除外が期限切れです(見直してください): {e}")

    print("\n".join(rep.lines))
    s = rep.skipped
    print(f"--  数えないもの: 修正版の無いOSパッケージのCRITICAL・HIGH {s['os_nofix']}件、"
          f"MEDIUM以下・修正版の無い言語パッケージ {s['low']}件、除外 {s['ignored']}件")
    if a.findings_out:
        json.dump(rep.findings, open(a.findings_out, "w"), ensure_ascii=False)
    print(f"VULN_RESULT {rep.ng} {rep.warn}")


if __name__ == "__main__":
    sys.exit(main())
