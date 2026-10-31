#!/usr/bin/env python3
"""Local Kavita-like OPDS server for tests. Not installed on the tablet."""

import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

KEY = "test-key"
CONTROL = ""
LOCK = threading.Lock()


def flag(name):
    return os.path.exists(os.path.join(CONTROL, name))


def version():
    path = os.path.join(CONTROL, "version")
    try:
        with open(path, encoding="utf-8") as handle:
            return int(handle.read().strip() or "1")
    except (OSError, ValueError):
        return 1


def note(code, path, inm):
    with LOCK:
        with open(os.path.join(CONTROL, "stats.tsv"), "a", encoding="utf-8") as handle:
            handle.write(f"{code}\t{path}\t{inm}\n")


def xml(text):
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def feed(title, body, extra=""):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:pse="http://vaemendis.net/opds-pse/ns">
<updated>2026-01-01T00:00:00</updated>
<id>{xml(title)}</id>
<title>{xml(title)}</title>
<author><name>Kavita</name><uri>https://kavitareader.com</uri></author>
<link rel="self" type="application/atom+xml;profile=opds-catalog;kind=navigation" href="/api/opds/{KEY}" />
<link rel="start" type="application/atom+xml;profile=opds-catalog;kind=navigation" href="/api/opds/{KEY}" />
{extra}
{body}
</feed>
"""


def nav(entry_id, title, author, href):
    author_xml = f"<author><name>{xml(author)}</name></author>" if author else ""
    return f"""<entry>
<id>{entry_id}</id>
<title>{xml(title)}</title>
{author_xml}
<link rel="http://opds-spec.org/image" type="image/jpeg" href="/api/image/cover?id={entry_id}&amp;apiKey={KEY}" />
<link rel="subsection" type="application/atom+xml;profile=opds-catalog;kind=navigation" href="{href}" />
</entry>
"""


def book(entry_id, title, author, href, mime, link_title):
    return f"""<entry>
<id>{entry_id}</id>
<title>{xml(title)}</title>
<author><name>{xml(author)}</name></author>
<link rel="http://opds-spec.org/image" type="image/jpeg" href="/api/image/chapter-cover?chapterId={entry_id}&amp;apiKey={KEY}" />
<link rel="http://opds-spec.org/acquisition/open-access" type="{mime}" href="{href}" title="{link_title}" pse:count="10" />
<link rel="http://vaemendis.net/opds-pse/stream" type="image/jpeg" href="/api/opds/{KEY}/image?chapterId={entry_id}&amp;pageNumber={{pageNumber}}" />
</entry>
"""


def libraries_feed():
    body = nav("1", "Romane", "", f"/api/opds/{KEY}/libraries/1")
    body += nav("2", "Comics", "", f"/api/opds/{KEY}/libraries/2")
    if flag("include-evil"):
        body += nav("9", "Evil", "", f"/api/opds/{KEY}/series/99")
    return feed("Libraries", body)


def library_feed(library_id, page):
    if library_id == "1" and page == "1":
        extra = (
            f'<link rel="next" type="application/atom+xml;profile=opds-catalog;kind=navigation" '
            f'href="/api/opds/{KEY}/libraries/1?pageNumber=2" />'
        )
        body = nav("10", "Die Verwandlung", "Franz Kafka", f"/api/opds/{KEY}/series/10")
        return feed("Romane", body, extra)
    if library_id == "1" and page == "2":
        body = nav("11", "Über den Berg", "Jörg & Söhne", f"/api/opds/{KEY}/series/11")
        return feed("Romane", body)
    if library_id == "2":
        if version() >= 2:
            return feed("Comics", "")
        body = nav("12", "Nested Comic", "Ada Lovelace", f"/api/opds/{KEY}/series/12")
        return feed("Comics", body)
    return None


def series_feed(series_id):
    if series_id == "10":
        href = f"/api/opds/{KEY}/series/10/volume/1/chapter/100/download/Die%20Verwandlung.epub"
        body = book(
            "100",
            "Weiterlesen: Die Verwandlung",
            "Franz Kafka",
            href,
            "application/epub+zip",
            "Die%20Verwandlung.epub",
        )
        body += book(
            "100",
            "Die Verwandlung",
            "Franz Kafka",
            href,
            "application/epub+zip",
            "Die%20Verwandlung.epub",
        )
        body += book(
            "101",
            "Die Verwandlung",
            "Franz Kafka",
            f"/api/opds/{KEY}/series/10/volume/1/chapter/101/download/Die%20Verwandlung.epub",
            "application/epub+zip",
            "Die%20Verwandlung.epub",
        )
        return feed("Die Verwandlung", body)
    if series_id == "11":
        body = book(
            "200",
            "Über den Berg",
            "Jörg & Söhne",
            f"/api/opds/{KEY}/series/11/volume/4/chapter/200/download/%C3%9Cber%20den%20Berg.epub",
            "application/epub+zip",
            "%C3%9Cber%20den%20Berg.epub",
        )
        return feed("Über den Berg", body)
    if series_id == "12":
        body = nav("1", "Volume 1", "", f"/api/opds/{KEY}/series/12/volume/1")
        return feed("Nested Comic", body)
    if series_id == "99" and flag("include-evil"):
        body = book(
            "999",
            "Stolen",
            "Nobody",
            f"/api/opds/{KEY}/series/99/volume/1/chapter/999/download/stolen.epub",
            "application/epub+zip",
            "stolen.epub",
        )
        return feed("Evil", body)
    return None


def volume_feed(series_id, volume_id):
    if series_id == "12" and volume_id == "1":
        body = nav("3", "Chapter 3", "Ada Lovelace", f"/api/opds/{KEY}/series/12/volume/1/chapter/3")
        return feed("Nested Comic Volume", body)
    return None


def chapter_feed(series_id, volume_id, chapter_id):
    if series_id == "12" and volume_id == "1" and chapter_id == "3":
        body = book(
            "3",
            "Chapter 3",
            "Ada Lovelace",
            f"/api/opds/{KEY}/series/12/volume/1/chapter/3/download/Nested.cbz",
            "application/x-cbz",
            "Nested.cbz",
        )
        return feed("Nested Comic Chapter", body)
    return None


def book_payload(chapter_id):
    if chapter_id == "100":
        return b"EPUB-100-v1", '"100-v1"', "application/epub+zip", "Die Verwandlung.epub"
    if chapter_id == "101":
        return b"EPUB-101-v1", '"101-v1"', "application/epub+zip", "Die Verwandlung.epub"
    if chapter_id == "200":
        if version() >= 2:
            return b"EPUB-11-v2", '"200-v2"', "application/epub+zip", "Über den Berg.epub"
        return b"EPUB-11-v1", '"200-v1"', "application/epub+zip", "Über den Berg.epub"
    if chapter_id == "3":
        return b"CBZ-12-v1", '"3-v1"', "application/x-cbz", "Nested.cbz"
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        inm = self.headers.get("If-None-Match") or ""
        code = self.dispatch(path, parsed.query, inm)
        note(code, path, inm)

    def dispatch(self, path, query, inm):
        if path == "/health":
            return self._bytes(200, b"ok", "text/plain")
        match = re.match(r"^/api/opds/([^/]+)(/.*)?$", path)
        if not match:
            return self._bytes(404, b"not found", "text/plain")
        key = match.group(1)
        rest = match.group(2) or ""
        if rest.endswith("/") and rest != "/":
            rest = rest.rstrip("/")
        if key != KEY:
            return self._bytes(401, b"bad api key", "text/plain")
        if flag("fail-libraries") and (rest == "/libraries" or rest.startswith("/libraries/")):
            return self._bytes(500, b"feed failed", "text/plain")
        page = parse_qs(query).get("pageNumber", ["1"])[0]
        if rest in ("", "/"):
            return self._xml(libraries_feed())
        if rest == "/libraries":
            return self._xml(libraries_feed())
        library = re.match(r"^/libraries/(\d+)$", rest)
        if library:
            body = library_feed(library.group(1), page)
            if body is None:
                return self._bytes(404, b"no library", "text/plain")
            return self._xml(body)
        series = re.match(r"^/series/(\d+)$", rest)
        if series:
            body = series_feed(series.group(1))
            if body is None:
                return self._bytes(404, b"no series", "text/plain")
            return self._xml(body)
        volume = re.match(r"^/series/(\d+)/volume/(\d+)$", rest)
        if volume:
            body = volume_feed(volume.group(1), volume.group(2))
            if body is None:
                return self._bytes(404, b"no volume", "text/plain")
            return self._xml(body)
        chapter = re.match(r"^/series/(\d+)/volume/(\d+)/chapter/(\d+)$", rest)
        if chapter:
            body = chapter_feed(chapter.group(1), chapter.group(2), chapter.group(3))
            if body is None:
                return self._bytes(404, b"no chapter", "text/plain")
            return self._xml(body)
        download = re.match(r"^/series/(\d+)/volume/(\d+)/chapter/(\d+)/download/.+$", rest)
        if download:
            chapter_id = download.group(3)
            if chapter_id == "999":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:1/stolen")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return 302
            if chapter_id == "100" and flag("fail-chapter-100"):
                return self._bytes(500, b"nope", "text/plain")
            payload = book_payload(chapter_id)
            if payload is None:
                return self._bytes(404, b"no file", "text/plain")
            data, etag, mime, filename = payload
            if inm == etag:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return 304
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("ETag", etag)
            self.send_header("Last-Modified", "Wed, 01 Jan 2025 00:00:00 GMT")
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
            self.end_headers()
            self.wfile.write(data)
            return 200
        return self._bytes(404, b"no route", "text/plain")

    def _bytes(self, code, data, mime):
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        return code

    def _xml(self, text):
        return self._bytes(200, text.encode("utf-8"), "application/xml; charset=utf-8")


def main():
    global CONTROL
    if len(sys.argv) != 3:
        print("usage: mock_opds.py PORT CONTROL_DIR", file=sys.stderr)
        return 2
    port = int(sys.argv[1])
    CONTROL = sys.argv[2]
    os.makedirs(CONTROL, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
