#!/usr/bin/env python3
"""Chrome milestone metadata; numeric branches are verified by Git at checkout.

Dates describe the listed Chrome Stable version's rollout, not a WebRTC branch cut.
Source: https://developer.chrome.com/docs/web-platform/versionhistory/reference
"""
import datetime
import json
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
CACHE = ROOT / ".build" / "create_lib" / "milestones.json"
BASE = "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions/all/releases"


def fetch(params):
    request = urllib.request.Request(BASE + "?" + urllib.parse.urlencode(params),
                                     headers={"User-Agent": "LocalWebRTCBuilder/1.0"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def records(releases):
    result = {}
    for release in releases:
        version = release.get("version", "")
        if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", version):
            continue
        parts = tuple(map(int, version.split(".")))
        date = release.get("serving", {}).get("startTime", "")[:10]
        if not date:
            continue
        milestone = str(parts[0])
        row = {"milestone": milestone, "branch": str(parts[2]),
               "version": version, "date": date}
        previous = result.get(milestone)
        if previous is None or parts > tuple(map(int, previous["version"].split("."))):
            result[milestone] = row
        elif version == previous["version"] and date < previous["date"]:
            previous["date"] = date
    return result


def read_cache():
    try:
        data = json.loads(CACHE.read_text())
        return data["milestones"], data["fetched_at"]
    except (OSError, ValueError, KeyError):
        return {}, ""


def lookup(milestone=None):
    cached, timestamp = read_cache()
    if timestamp:
        try:
            age = datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(timestamp)
        except (ValueError, TypeError):
            age = datetime.timedelta(days=1)
        if age < datetime.timedelta(hours=24) and (milestone is None or milestone in cached):
            return cached
    try:
        params = {"order_by": "version desc", "pageSize": 1000}
        if milestone is not None:
            params["filter"] = f"version>={milestone},version<{int(milestone) + 1}"
        releases = []
        # Bound requests; recent milestones normally fit in a single page.
        for _ in range(10):
            data = fetch(params)
            releases.extend(data.get("releases", []))
            rows = records(releases)
            token = data.get("nextPageToken")
            if not token or (milestone is None and len(rows) >= 12):
                break
            params["pageToken"] = token
        if not rows or (milestone is not None and milestone not in rows):
            raise ValueError("No Chrome Stable release was found for this selection.")
        # Only refresh the list timestamp for a full recent-list lookup.
        cached.update(rows)
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        CACHE.write_text(json.dumps({"fetched_at": now if milestone is None else timestamp,
                                     "milestones": cached}, indent=2))
        return rows
    except (OSError, ValueError, urllib.error.URLError) as error:
        if cached and (milestone is None or milestone in cached):
            print(f"Network lookup failed; using cached metadata from {timestamp or 'an earlier lookup'}.", file=sys.stderr)
            return cached
        raise ValueError(f"Milestone lookup unavailable: {error}. Enter a branch-head directly instead.") from error


def main():
    mode = sys.argv[1]
    if mode == "list":
        rows = lookup()
        for milestone in sorted(rows, key=int, reverse=True)[:12]:
            row = rows[milestone]
            print("\t".join(row[key] for key in ("milestone", "branch", "date", "version")))
    elif mode == "resolve":
        milestone = sys.argv[2].upper().lstrip("M")
        if not milestone.isdigit() or int(milestone) < 80:
            raise ValueError("Enter a milestone of M80 or newer, e.g. M156.")
        milestone = str(int(milestone))
        print(lookup(milestone)[milestone]["branch"])
    else:
        raise ValueError("Usage: milestones.py list | resolve M<number>")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, IndexError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
