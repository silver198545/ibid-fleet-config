#!/usr/bin/env python3
"""qa/checks.yaml のチェックを1つのアプリ・サイトに対して実行する(scripts/qa.sh から呼ぶ)。

使い方: qa_http.py <checks.yaml> <apps|sites> <name> <base_url> [--production <base_url>]

base_url はアプリなら https://<app>.<env>.ibid.lan、サイトならサイトのURL(sitePathを含み / で終わる)。
--production を渡すと same_as_production の比較を行う(本番に無いときは渡さない)。
結果を1行ずつ表示し、最後に「QA_RESULT <OKの数> <全体の数>」を出す。1つでもNGなら終了コード1。
"""
import argparse
import json
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import yaml

# 内部CA(FreeIPA)の証明書は検証しない(scripts/ の curl -k と同じ)
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

TIMEOUT = 60
RETRIES = 3        # 接続できない・5xxのときのやり直し(Podの入れ替え直後にTraefikが一時的に502を返すため)
RETRY_WAIT = 10


def fetch(url):
    """(status, body(bytes), content_type, 秒) を返す。接続できなければ status=0。"""
    last = (0, b"", "", 0.0)
    for i in range(RETRIES):
        started = time.monotonic()
        req = urllib.request.Request(url, headers={"User-Agent": "ibid-qa"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT, context=CTX) as r:
                last = (r.status, r.read(), r.headers.get("Content-Type", ""), time.monotonic() - started)
        except urllib.error.HTTPError as e:
            last = (e.code, e.read(), e.headers.get("Content-Type", ""), time.monotonic() - started)
        except (urllib.error.URLError, OSError) as e:
            last = (0, str(e).encode(), "", time.monotonic() - started)
        if 0 < last[0] < 500:
            break
        if i < RETRIES - 1:
            time.sleep(RETRY_WAIT)
    return last


def html_title(text):
    m = re.search(r"<title[^>]*>(.*?)</title>", text, re.S | re.I)
    return m.group(1).strip() if m else None


def json_value(body, key):
    try:
        return json.loads(body).get(key)
    except (ValueError, AttributeError):
        return None


def run_check(check, base, prod_base, forbidden):
    """(ok, 表示用の行) を返す。"""
    url = urllib.parse.urljoin(base, check["path"])
    status, body, ctype, secs = fetch(url)
    text = body.decode("utf-8", errors="replace")
    label = "/" + url.split("/", 3)[3] if url.count("/") >= 3 else url
    problems, notes = [], []

    want = check.get("status", 200)
    if status != want:
        problems.append(f"HTTP {status}(期待 {want})" if status else f"接続できません: {text[:120]}")
    else:
        for s in check.get("contains", []):
            if s not in text:
                problems.append(f"「{s}」が含まれない")
        if "html" in ctype:
            for s in forbidden:
                if s in text:
                    problems.append(f"エラー表示「{s}」がある")
        data = None
        if check.get("json"):
            try:
                data = json.loads(body)
            except ValueError:
                problems.append("JSONではない")
        if data is not None and "min_items" in check:
            target = data.get(check["key"]) if check.get("key") and isinstance(data, dict) else data
            n = len(target) if isinstance(target, (list, dict)) else 0
            notes.append(f"{check.get('key', '要素')}={n}件")
            if n < check["min_items"]:
                problems.append(f"要素数 {n}(下限 {check['min_items']})")
        if "min_number" in check:
            m = re.search(check["min_number"]["pattern"], text)
            if not m:
                problems.append("件数が見つからない")
            else:
                n = int(m.group(1))
                notes.append(f"件数={n}")
                if n < check["min_number"]["min"]:
                    problems.append(f"件数 {n}(下限 {check['min_number']['min']})")
        if "max_seconds" in check and secs > check["max_seconds"]:
            problems.append(f"応答 {secs:.1f}秒(上限 {check['max_seconds']}秒)")

        if prod_base and check.get("same_as_production"):
            p_status, p_body, _, _ = fetch(urllib.parse.urljoin(prod_base, check["path"]))
            if p_status != 200:
                notes.append(f"本番がHTTP {p_status}のため比較せず")
            else:
                p_text = p_body.decode("utf-8", errors="replace")
                for item in check["same_as_production"]:
                    if item == "title":
                        mine, theirs = html_title(text), html_title(p_text)
                    elif item.startswith("json:"):
                        mine, theirs = json_value(body, item[5:]), json_value(p_body, item[5:])
                    else:
                        raise SystemExit(f"不明な same_as_production: {item}")
                    if mine != theirs:
                        problems.append(f"{item} が本番と違う: 「{mine}」/ 本番「{theirs}」")
                    else:
                        notes.append(f"{item}が本番と一致")

    head = "OK" if not problems else "NG"
    line = f"{head}  {status or '---'}  {secs:5.2f}s  {label}"
    detail = problems + notes
    if detail:
        line += "  (" + "、".join(detail) + ")"
    return not problems, line


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("checks")
    ap.add_argument("kind", choices=["apps", "sites"])
    ap.add_argument("name")
    ap.add_argument("base_url")
    ap.add_argument("--production")
    args = ap.parse_args()

    with open(args.checks) as f:
        conf = yaml.safe_load(f)
    if args.kind == "apps":
        checks = conf["apps"].get(args.name)
        if not checks:
            print(f"エラー: qa/checks.yaml に {args.name} のチェックがありません。", file=sys.stderr)
            sys.exit(2)
    else:
        checks = conf["sites"]

    ok = 0
    for c in checks:
        passed, line = run_check(c, args.base_url, args.production, conf.get("forbidden", []))
        print(line, flush=True)
        ok += passed
    print(f"QA_RESULT {ok} {len(checks)}")
    sys.exit(0 if ok == len(checks) else 1)


if __name__ == "__main__":
    main()
