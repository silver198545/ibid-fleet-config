#!/usr/bin/env python3
"""devのサイトのfleet.yamlにあるプラグインのバージョン固定を、WordPress.orgの最新版へ上げる。

scripts/bump-plugins.sh から呼ばれる。fleet.yaml の helm.values.plugins の
    - name: <slug>
      version: "<version>"
の組だけを書き換える(コメントや他の行はそのまま残すため、YAMLを読み直して書き出すことはしない)。
version を指定していないプラグインは対象外。

最新版の「必要なWordPressのバージョン(requires)」がチャートの appVersion
(イメージのWordPressのバージョン)より新しい場合は上げない。WordPress.orgで公開停止された
プラグインは警告を出して飛ばす。既存より古い版には下げない。

使い方: plugin_updates.py <WordPressのバージョン> <fleet.yaml>...
標準出力: 変更内容のMarkdown(PR本文用。変更が無ければ空)
"""
import json
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


def main():
    if len(sys.argv) < 3:
        sys.exit("使い方: plugin_updates.py <WordPressのバージョン> <fleet.yaml>...")
    wp_version, files = sys.argv[1], sys.argv[2:]

    contents = {f: open(f, encoding="utf-8").read() for f in files}
    slugs = sorted({m.group(2) for text in contents.values() for m in PAIR.finditer(text)})

    latest = {}
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
            continue
        latest[slug] = info["version"]

    changes = {}  # (slug, old, new) -> [site...]
    for f, text in contents.items():
        site = f.rstrip("/").split("/")[-2]

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


if __name__ == "__main__":
    main()
