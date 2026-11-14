#!/usr/bin/env python3
"""Idempotently create categories and feed subscriptions from OPML."""

import json
import os
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


BASE_URL = os.environ.get("MINIFLUX_URL", "http://miniflux.miniflux.svc.cluster.local:8080").rstrip("/")
API_TOKEN = os.environ["MINIFLUX_API_TOKEN"]


def request(method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    headers = {"X-Auth-Token": API_TOKEN, "Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE_URL + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=45) as response:
        body = response.read()
        return json.loads(body) if body else None


def wait_for_api():
    for attempt in range(90):
        try:
            with urllib.request.urlopen(BASE_URL + "/healthcheck", timeout=5) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError):
            time.sleep(5)
    raise RuntimeError("Miniflux did not become healthy before the import deadline")


def main():
    wait_for_api()
    root = ET.parse("/bootstrap/feeds.opml").getroot()
    body = root.find("body")
    if body is None:
        raise RuntimeError("OPML document has no body")

    categories = {item["title"]: item["id"] for item in request("GET", "/v1/categories")}
    existing = {item["feed_url"] for item in request("GET", "/v1/feeds")}
    added = 0
    skipped = 0

    for outline in body.findall("outline"):
        title = outline.attrib.get("title") or outline.attrib.get("text")
        if not title:
            continue
        if title not in categories:
            created = request("POST", "/v1/categories", {"title": title})
            categories[title] = created["id"]

        for feed in outline.findall("outline"):
            feed_url = feed.attrib.get("xmlUrl")
            feed_title = feed.attrib.get("title") or feed.attrib.get("text") or feed_url
            if not feed_url:
                continue
            if feed_url in existing:
                skipped += 1
                continue
            request("POST", "/v1/feeds", {"feed_url": feed_url, "category_id": categories[title]})
            existing.add(feed_url)
            added += 1
            print(f"Added feed: {feed_title}", flush=True)

    print(f"Feed import complete: {added} added, {skipped} already present", flush=True)


if __name__ == "__main__":
    main()
