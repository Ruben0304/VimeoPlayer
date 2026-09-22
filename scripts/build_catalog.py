#!/usr/bin/env python3
"""Descarga el catálogo completo de lamovie.org y lo guarda comprimido en
VimeoPlayer/LaMovieCatalog.deflate, la instantánea que viaja dentro de la app.

Formato: JSON {"generatedAt", "posts": [...]} comprimido con DEFLATE crudo
(lo que `NSData.decompressed(using: .zlib)` espera). Cada post usa las mismas
claves que la API, así que se decodifica directamente como `CatalogItem`.

Uso: python3 scripts/build_catalog.py
"""
import json, os, sys, time, zlib, urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

API = "https://lamovie.org/wp-api/v1/listing/"
KINDS = ["movies", "tvshows", "animes", "novels", "wwe"]
PER_PAGE = 30  # máximo que acepta la API
KEEP = ["_id", "title", "original_title", "overview", "slug", "images", "rating", "genres",
        "type", "release_date", "runtime", "tagline", "certification"]
OUT = os.path.join(os.path.dirname(__file__), "..", "VimeoPlayer", "LaMovieCatalog.deflate")


def fetch(kind, page):
    query = urllib.parse.urlencode({"page": page, "orderBy": "latest", "order": "desc",
                                    "postType": kind, "postsPerPage": PER_PAGE})
    request = urllib.request.Request(API + kind + "?" + query,
                                     headers={"Accept": "application/json", "User-Agent": "Mozilla/5.0"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)["data"]
        except Exception as error:
            if attempt == 4:
                raise
            time.sleep(2 * (attempt + 1))


def compact(post):
    out = {}
    for key in KEEP:
        value = post.get(key)
        if value in (None, "", [], {}):
            continue
        if key == "images":
            value = {k: v for k, v in value.items() if v}
        if key == "overview":
            value = " ".join(value.split())
        out[key] = value
    # La API a veces manda el id como texto ("123"); la app lo espera numérico.
    out["_id"] = int(out["_id"])
    return out


def main():
    posts = {}
    string_ids = []
    for kind in KINDS:
        first = fetch(kind, 1)
        last = first["pagination"]["last_page"]
        pages = [first] + list(ThreadPoolExecutor(6).map(lambda p: fetch(kind, p), range(2, last + 1)))
        for data in pages:
            for post in data["posts"] if isinstance(data["posts"], list) else []:
                if isinstance(post["_id"], str):
                    string_ids.append(post["_id"])
                item = compact(post)
                posts[item["_id"]] = item
        if string_ids:
            print(f"  ids como texto: {string_ids[:5]}… ({len(string_ids)})", file=sys.stderr)
            string_ids.clear()
        print(f"{kind}: {sum(1 for p in posts.values() if p.get('type') == kind)} títulos ({last} páginas)", file=sys.stderr)

    payload = {
        "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "posts": sorted(posts.values(), key=lambda p: -p["_id"]),
    }
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = compressor.compress(raw) + compressor.flush()
    with open(OUT, "wb") as f:
        f.write(packed)
    print(f"{len(posts)} títulos · JSON {len(raw) / 1e6:.1f} MB · comprimido {len(packed) / 1e6:.1f} MB → {os.path.normpath(OUT)}", file=sys.stderr)


if __name__ == "__main__":
    main()
