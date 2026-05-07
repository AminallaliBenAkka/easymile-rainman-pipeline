#!/usr/bin/env python3
import argparse
import csv
from collections import defaultdict

def to_float(x):
    try:
        return float(x)
    except Exception:
        return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default="/navigator/ads/results/searchbox_metrics.csv")
    ap.add_argument("--out", default="/navigator/ads/results/searchbox_summary.txt")
    ap.add_argument("--target", default="", help="Filter target_id (exact match)")
    ap.add_argument("--lidar", default="", help="Filter lidar (contains)")
    args = ap.parse_args()

    rows = []
    with open(args.csv, "r", newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            if args.target and row.get("target_id") != args.target:
                continue
            if args.lidar and args.lidar not in (row.get("lidar") or ""):
                continue
            rows.append(row)

    if not rows:
        raise SystemExit("No rows after filtering. Check CSV path / filters.")

    # Aggregate per (lidar,target)
    agg = defaultdict(lambda: {
        "bags": 0,
        "frames_total": 0,
        "frames_hit": 0,
        "points_mean_sum": 0.0,
        "points_mean_n": 0,
        "dist_mean_sum": 0.0,
        "dist_mean_n": 0,
        "dist_std_sum": 0.0,
        "dist_std_n": 0,
    })

    for row in rows:
        key = (row["lidar"], row["target_id"])
        a = agg[key]
        a["bags"] += 1

        ft = int(row["frames_total"])
        fh = int(row["frames_hit"])
        a["frames_total"] += ft
        a["frames_hit"] += fh

        pm = to_float(row.get("points_mean_when_hit"))
        if pm is not None:
            a["points_mean_sum"] += pm
            a["points_mean_n"] += 1

        dm = to_float(row.get("distance_mean_m"))
        if dm is not None:
            a["dist_mean_sum"] += dm
            a["dist_mean_n"] += 1

        ds = to_float(row.get("distance_std_m"))
        if ds is not None:
            a["dist_std_sum"] += ds
            a["dist_std_n"] += 1

    # Write summary
    lines = []
    lines.append("ADS SearchBox summary (aggregated per lidar + target)\n")
    lines.append(f"Input CSV: {args.csv}\n")

    # Header
    lines.append(
        "lidar,target,bags,hit_ratio_global,points_mean_avg,distance_mean_avg,distance_std_avg"
    )

    for (lidar, target) in sorted(agg.keys()):
        a = agg[(lidar, target)]
        hit_ratio = (a["frames_hit"] / a["frames_total"]) if a["frames_total"] else 0.0
        points_mean_avg = (a["points_mean_sum"] / a["points_mean_n"]) if a["points_mean_n"] else 0.0
        dist_mean_avg = (a["dist_mean_sum"] / a["dist_mean_n"]) if a["dist_mean_n"] else None
        dist_std_avg  = (a["dist_std_sum"] / a["dist_std_n"]) if a["dist_std_n"] else None

        lines.append(
            f"{lidar},{target},{a['bags']},{hit_ratio:.4f},"
            f"{points_mean_avg:.2f},"
            f"{'' if dist_mean_avg is None else f'{dist_mean_avg:.3f}'},"
            f"{'' if dist_std_avg is None else f'{dist_std_avg:.3f}'}"
        )

    with open(args.out, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"[OK] Wrote summary to {args.out}")

if __name__ == "__main__":
    main()
