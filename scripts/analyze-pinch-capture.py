#!/usr/bin/env python3
"""Summarize explicitly captured raw OpenLaunch trackpad frames."""
import collections
import json
import math
import pathlib
import statistics
import sys


def active_points(frame):
    return [p for p in frame["points"] if p["state"] in (3, 4)]


def geometry(points):
    if not points:
        return None
    cx = sum(p["x"] for p in points) / len(points)
    cy = sum(p["y"] for p in points) / len(points)
    radius = sum(math.hypot(p["x"] - cx, p["y"] - cy) for p in points) / len(points)
    return cx, cy, radius


def five_segments(rows):
    result, current = [], []
    for row in rows:
        if row["contactCount"] == 5:
            current.append(row)
        elif current:
            result.append(current)
            current = []
    if current:
        result.append(current)
    return result


def summarize(path):
    data = json.loads(path.read_text())
    frames = data["frames"]
    counts = collections.Counter()
    states = collections.Counter()
    identities = collections.Counter()
    rows = []
    for frame in frames:
        contacts = active_points(frame)
        counts[len(contacts)] += 1
        for point in frame["points"]:
            states[str(point["state"])] += 1
        identities[len({p["fingerID"] for p in contacts})] += 1
        g = geometry(contacts)
        rows.append({
            "t": frame["timestamp"], "contactCount": len(contacts),
            "fingerIDs": sorted(p["fingerID"] for p in contacts),
            "pathIDs": sorted(p["pathID"] for p in contacts),
            "geometry": g,
        })

    segments = []
    for i, segment in enumerate(five_segments(rows), 1):
        valid = [r for r in segment if r["geometry"]]
        if not valid:
            continue
        start, end = valid[0], valid[-1]
        initial_radius = start["geometry"][2]
        min_row = min(valid, key=lambda r: r["geometry"][2])
        minimum_radius = min_row["geometry"][2]
        center_drift = max(math.hypot(r["geometry"][0] - start["geometry"][0], r["geometry"][1] - start["geometry"][1]) for r in valid)
        elapsed = end["t"] - start["t"]
        enough_shrink = initial_radius >= 0.08 and minimum_radius <= initial_radius * 0.65 and initial_radius - minimum_radius >= 0.045
        segments.append({
            "ordinal": i, "frames": len(segment), "elapsedSeconds": round(elapsed, 4),
            "initialMeanRadius": round(initial_radius, 5), "minimumMeanRadius": round(minimum_radius, 5),
            "contractionFraction": round((initial_radius - minimum_radius) / initial_radius, 4) if initial_radius else None,
            "maximumCentroidDrift": round(center_drift, 5),
            "maximumAllowedCentroidDrift": 0.12,
            "minimumPointToPointIDOverlap": min((len(set(a["fingerIDs"]) & set(b["fingerIDs"])) for a, b in zip(segment, segment[1:])), default=5),
            "existingThresholdsReached": bool(enough_shrink and elapsed <= 2.5 and center_drift <= 0.12),
            "firstFiveFingerIDs": start["fingerIDs"],
            "lastFiveFingerIDs": end["fingerIDs"],
        })

    gaps = []
    for a, b in zip(rows, rows[1:]):
        if a["contactCount"] == 5 and b["contactCount"] == 4:
            gaps.append({"at": round(b["t"] - rows[0]["t"], 4), "followingFourPointFrame": round(b["t"], 5), "fourIDs": b["fingerIDs"]})
    times = [f["timestamp"] for f in frames]
    deltas = [b - a for a, b in zip(times, times[1:]) if b >= a]
    return {
        "file": path.name, "phase": data["phase"], "label": data["label"],
        "captureSource": data["captureSource"], "deviceIsBuiltIn": data["deviceIsBuiltIn"],
        "rawFrames": len(frames), "droppedFrames": data["droppedFrames"],
        "durationSeconds": round(times[-1] - times[0], 4) if len(times) > 1 else 0,
        "frameIntervalMsMedian": round(statistics.median(deltas) * 1000, 3) if deltas else None,
        "contactCountHistogram": {str(k): counts[k] for k in sorted(counts)},
        "rawStateHistogram": dict(sorted(states.items())),
        "fiveFingerSegments": segments,
        "fiveToFourTransitions": gaps,
        "identityCardinalityHistogram": {str(k): identities[k] for k in sorted(identities)},
    }


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: analyze-pinch-capture.py CAPTURE_DIRECTORY")
    directory = pathlib.Path(sys.argv[1])
    reports = [summarize(path) for path in sorted(directory.glob("[0-9][0-9]-*.json"))]
    result = {"analysisVersion": 1, "phaseReports": reports}
    target = directory / "analysis.json"
    target.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
