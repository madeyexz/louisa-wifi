#!/usr/bin/env python3
"""Scrape every Louisa Coffee store from louisacoffee.co and write data/stores.json.

Each store gets a list of Wi-Fi password candidates derived from its phone number.
The app tries them in order, so put the most likely first.
"""
import html
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

URL = "https://www.louisacoffee.co/visit_result"
# One query never returns everything, so union a few broad ones.
QUERIES = [("name", "門市"), ("address", "路"), ("address", "街"), ("address", "號"), ("name", "")]
OUT = Path(__file__).resolve().parent.parent / "data" / "stores.json"


def fetch(field, value):
    body = urllib.parse.urlencode({f"data[{field}]": value}).encode()
    req = urllib.request.Request(URL, data=body, headers={"User-Agent": "louisa-wifi"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode("utf-8")


def coord(raw):
    """Decimal degrees, or DMS like 25°02'56.5"N which a few stores use."""
    raw = html.unescape(raw).strip()
    try:
        return float(raw or 0)
    except ValueError:
        m = re.match(r"(\d+)°\s*(\d+)'\s*([\d.]+)", raw)
        return int(m[1]) + int(m[2]) / 60 + float(m[3]) / 3600 if m else 0.0


def parse(page):
    for block in page.split('<div class="row"><hr></div>'):
        name = re.search(r"<h4>(.*?)</h4>", block)
        if not name:
            continue
        phone = re.search(r"<p>電話/(.*?)</p>", block)
        addr = re.search(r'rel-store-address="(.*?)"', block)
        lat = re.search(r'rel-store-lat="(.*?)"', block)
        lng = re.search(r'rel-store-lng="(.*?)"', block)
        yield {
            "name": html.unescape(name.group(1)).strip(),
            "phone": html.unescape(phone.group(1)).strip() if phone else "",
            "address": re.sub(r"\s+", " ", html.unescape(addr.group(1))).strip() if addr else "",
            "lat": coord(lat.group(1)) if lat else 0.0,
            "lng": coord(lng.group(1)) if lng else 0.0,
        }


def passwords(phone):
    """Louisa uses the store phone number as the Wi-Fi password, but the exact
    form varies: usually without the leading 0, and in Taipei (02) without the
    whole area code. Some stores use the full number. Return the likely forms,
    best first."""
    # First number only; drop extensions like #12 or 分機.
    first = re.split(r"[#轉,、/]|分機|ext", phone, flags=re.I)[0]
    d = re.sub(r"\D", "", first)
    if not d:
        return []
    # A wrong password costs ~15s on macOS, so keep this list short.
    # Usual form, then the full number (#1), then the rarer short form.
    out = [d[2:], d, d[1:]] if d.startswith("02") else [d[1:], d, d[-8:]]
    seen = set()
    return [p for p in out if 8 <= len(p) <= 63 and not (p in seen or seen.add(p))]


def main():
    stores = {}
    for field, value in QUERIES:
        for s in parse(fetch(field, value)):
            stores.setdefault(s["name"], s)
        print(f"{field}={value!r}: {len(stores)} stores so far", file=sys.stderr)

    out = []
    for s in sorted(stores.values(), key=lambda s: s["name"]):
        pw = passwords(s["phone"])
        if not pw:
            print(f"skip {s['name']}: no usable phone ({s['phone']!r})", file=sys.stderr)
            continue
        if not (21 < s["lat"] < 26.5 and 118 < s["lng"] < 122.5):
            s["lat"] = s["lng"] = 0.0  # unknown; still searchable by name
        out.append({"name": s["name"], "address": s["address"], "phone": s["phone"],
                    "lat": round(s["lat"], 6), "lng": round(s["lng"], 6), "passwords": pw})

    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    missing = sum(1 for s in out if not s["lat"])
    print(f"wrote {len(out)} stores to {OUT} ({missing} without coordinates)", file=sys.stderr)


if __name__ == "__main__":
    main()
