#!/usr/bin/env python3
"""サイトのfleet.yamlの helm.values.plugins(プラグインの版の固定)を読み書きする。

scripts/capture-plugins.sh(devに入っている版をGitに取り込む)と scripts/plugin-check.sh から使う。

運用(2026-11-09〜): サイトの管理者がdevの管理画面でプラグインを更新・追加して動作を確かめ、
capture-plugins.sh(Rundeckの 0-dev-plugin-capture)でその版をGitに取り込む。そこから先は
staging → 本番へ構成として昇格する(チャートのプラグイン同期Jobが各環境に同じ版を入れる)。

fleet.yaml はコメントを残すため、YAMLとして読み直して書き出すことはせず、`    plugins:` の
ブロック(helm.values 直下。インデント4)だけを行単位で書き換える。各要素は
      - name: <slug>
        version: "<version>"
        activate: false        # 無効のプラグインだけ(同期Jobは既定で有効化するため)
の形。ブロックの中のコメントは、次の要素に付いたものとして残す。

使い方(capture):
  plugin_pins.py capture --inventory-dir <dir> <fleet.yaml>...
    <dir>/<site>.json は devのPodの `wp plugin list --format=json --fields=name,version,status`。
    fleet.yaml を書き換え、変更内容のMarkdown(PR本文用。変更が無ければ空)を標準出力に出す。
    WordPress.orgに無いプラグイン・WordPress.orgに無い版は取り込まない(同期Jobが入れられないため。警告を出す)。
"""
import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

API = "https://api.wordpress.org/plugins/info/1.2/"
SLUG = re.compile(r"^[a-z0-9-]+$")


def site_of(path):
    return path.rstrip("/").split("/")[-2]


def parse(text):
    """(開始行, 終了行(含まない), 要素のリスト) を返す。ブロックが無ければ None。
    要素は {"name", "version", "activate"(True/False), "comments"(前に付くコメント行)}。"""
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.rstrip() == "    plugins:":
            break
    else:
        return None
    entries, comments, j = [], [], i + 1
    while j < len(lines):
        line = lines[j]
        s = line.strip()
        if s and (len(line) - len(line.lstrip())) <= 4:
            break
        if not s:
            j += 1
            continue
        if s.startswith("#"):
            comments.append(line)
        elif s.startswith("- name:"):
            entries.append({"name": s.split(":", 1)[1].strip(), "version": "", "activate": True, "comments": comments})
            comments = []
        elif s.startswith("version:") and entries:
            entries[-1]["version"] = s.split(":", 1)[1].strip().strip('"').strip("'")
        elif s.startswith("activate:") and entries:
            entries[-1]["activate"] = s.split(":", 1)[1].split("#")[0].strip().lower() != "false"
        else:
            sys.exit(f"エラー: plugins: の中に読めない行があります: {line!r}")
        j += 1
    # 末尾の空行はブロックに含めない
    while j > i + 1 and not lines[j - 1].strip():
        j -= 1
    return i, j, entries


def render(entries):
    out = ["    plugins:"]
    for e in entries:
        out += e.get("comments") or []
        out.append(f"      - name: {e['name']}")
        if e["version"]:
            out.append(f'        version: "{e["version"]}"')
        if not e["activate"]:
            out.append("        activate: false")
    return out


def write_entries(text, entries):
    """plugins: ブロックを entries で置き換えた本文を返す。ブロックが無ければ、ひな形のコメント
    (`    # plugins:` と続く `    #   ...`)を置き換えるか、`  values:` の直後に入れる。"""
    lines = text.split("\n")
    p = parse(text)
    if p:
        i, j, _ = p
        return "\n".join(lines[:i] + render(entries) + lines[j:])
    for i, line in enumerate(lines):
        if line.rstrip() == "    # plugins:":
            j = i + 1
            while j < len(lines) and lines[j].startswith("    #   "):
                j += 1
            return "\n".join(lines[:i] + render(entries) + lines[j:])
    for i, line in enumerate(lines):
        if line.rstrip() == "  values:":
            return "\n".join(lines[:i + 1] + render(entries) + lines[i + 1:])
    sys.exit("エラー: helm.values(`  values:`)が見つかりません。")


def org_versions(slug, cache={}):
    """WordPress.orgにある版の集合(最新版を含む)。無ければ None。"""
    if slug not in cache:
        q = urllib.parse.urlencode({"action": "plugin_information", "request[slug]": slug,
                                    "request[fields][sections]": 0, "request[fields][versions]": 1})
        try:
            with urllib.request.urlopen(f"{API}?{q}", timeout=30) as r:
                info = json.load(r)
        except Exception:
            info = {"error": "取得できません"}
        if "error" in info or not info.get("version"):
            cache[slug] = None
        else:
            cache[slug] = set((info.get("versions") or {}).keys()) | {info["version"]}
    return cache[slug]


def capture(inv_dir, files):
    report = []
    for f in files:
        site = site_of(f)
        inv_file = os.path.join(inv_dir, f"{site}.json")
        if not os.path.exists(inv_file):
            print(f"警告: {site}: devのプラグイン一覧がありません。飛ばします。", file=sys.stderr)
            continue
        installed = [x for x in json.load(open(inv_file))
                     if x.get("status") not in ("must-use", "dropin") and SLUG.match(x.get("name", ""))]
        text = open(f, encoding="utf-8").read()
        p = parse(text)
        old = p[2] if p else []
        old_by = {e["name"]: e for e in old}
        inst_by = {x["name"]: x for x in installed}

        def accept(x):
            vs = org_versions(x["name"])
            if vs is None:
                print(f"警告: {site}: {x['name']} はWordPress.orgに無いため取り込みません(手で管理する)。", file=sys.stderr)
                return False
            if x["version"] not in vs:
                print(f"警告: {site}: {x['name']} {x['version']} はWordPress.orgで配布されていない版のため取り込みません"
                      f"(Gitは今のまま)。devの管理画面で配布中の版へ更新してから取り込んでください。", file=sys.stderr)
                return False
            return True

        new, changes = [], []
        # 既にある要素は順番を保つ
        for e in old:
            x = inst_by.get(e["name"])
            if x is None:
                changes.append(f"削除(devから消えた): `{e['name']}` {e['version']}")
                continue
            if not accept(x):
                new.append(e)
                continue
            act = x["status"] != "inactive"
            n = dict(e, version=x["version"], activate=act)
            if e["version"] != x["version"]:
                changes.append(f"更新: `{e['name']}` {e['version'] or '(版の指定なし)'} → {x['version']}")
            if e["activate"] != act:
                changes.append(f"{'有効化' if act else '無効化'}: `{e['name']}`")
            new.append(n)
        for x in sorted(installed, key=lambda x: x["name"]):
            if x["name"] in old_by or not accept(x):
                continue
            act = x["status"] != "inactive"
            new.append({"name": x["name"], "version": x["version"], "activate": act, "comments": []})
            changes.append(f"追加: `{x['name']}` {x['version']}{'(無効)' if not act else ''}")

        if new == old or not changes:
            continue
        with open(f, "w", encoding="utf-8") as out:
            out.write(write_entries(text, new))
        report.append((site, changes))

    for site, changes in report:
        print(f"### {site}")
        for c in changes:
            print(f"- {c}")
        print()


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--inventory-dir", required=True)
    c.add_argument("files", nargs="+")
    a = ap.parse_args()
    if a.cmd == "capture":
        capture(a.inventory_dir, a.files)


if __name__ == "__main__":
    main()
