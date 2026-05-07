#!/usr/bin/env python3
import os
import glob
import csv
import math
import argparse
from collections import defaultdict

import yaml
import numpy as np
import rosbag
from sensor_msgs import point_cloud2


def load_yaml(path: str):
    with open(path, "r") as f:
        return yaml.safe_load(f)


def load_topics_from_record_profiles(profiles_path: str, profile_name: str):
    cfg = load_yaml(profiles_path)
    include = cfg.get("include", {})
    topics = include.get(profile_name)
    if not topics:
        raise SystemExit(f"Profile '{profile_name}' not found or empty in {profiles_path}")
    return list(topics)


def topic_to_lidar_name(topic: str) -> str:
    return topic.strip("/").replace("/", "_")


def roi_from_target(target: dict, margin: float):
    cx, cy, cz = target["center"]["x"], target["center"]["y"], target["center"]["z"]
    dx, dy, dz = target["size"]["dx"], target["size"]["dy"], target["size"]["dz"]
    return {
        "x_min": cx - dx / 2 - margin,
        "x_max": cx + dx / 2 + margin,
        "y_min": cy - dy / 2 - margin,
        "y_max": cy + dy / 2 + margin,
        "z_min": cz - dz / 2 - margin,
        "z_max": cz + dz / 2 + margin,
    }


def inside_roi(x, y, z, roi):
    return (
        roi["x_min"] <= x <= roi["x_max"]
        and roi["y_min"] <= y <= roi["y_max"]
        and roi["z_min"] <= z <= roi["z_max"]
    )


def iter_points_xyz_intensity(msg):
    field_names = [f.name for f in msg.fields]

    intensity_field = None
    for cand in ("reflectivity", "intensity", "i", "reflectance"):
        if cand in field_names:
            intensity_field = cand
            break

    read_fields = ("x", "y", "z", intensity_field) if intensity_field else ("x", "y", "z")

    for p in point_cloud2.read_points(msg, field_names=read_fields, skip_nans=True):
        if intensity_field:
            x, y, z, intensity = p
            yield float(x), float(y), float(z), float(intensity)
        else:
            x, y, z = p
            yield float(x), float(y), float(z), None


def dump_npz(npz_dir, bag_base, lidar_name, target_id, points_xyz_i):
    os.makedirs(npz_dir, exist_ok=True)
    safe_bag = bag_base.replace(".bag", "")
    out = os.path.join(npz_dir, f"{safe_bag}__{lidar_name}__{target_id}.npz")
    arr = np.asarray(points_xyz_i, dtype=np.float32) if points_xyz_i else np.zeros((0, 4), np.float32)
    np.savez_compressed(out, data=arr, header=np.array(["x", "y", "z", "intensity"], dtype=object))
    return out


def process_bag(bag_path, lidar_topics, targets: dict, margin: float, nth_frame: int, dump_npz_dir=None):
    rois = {tid: roi_from_target(tdef, margin) for tid, tdef in targets.items()}

    acc = defaultdict(lambda: {
        "frames_total": 0,
        "frames_hit": 0,
        "points_sum": 0,
        "points_min": None,
        "points_max": 0,
        "dist_sum": 0.0,
        "dist_sq_sum": 0.0,
        "dist_count": 0,
        "int_sum": 0.0,
        "int_sq_sum": 0.0,
        "int_count": 0,
    })

    per_topic_counter = defaultdict(int)
    non_pc2_topics = {}

    bag_base = os.path.basename(bag_path)

    with rosbag.Bag(bag_path) as bag:
        info = bag.get_type_and_topic_info()
        present_topics = set(info.topics.keys())
        topics = [t for t in lidar_topics if t in present_topics]

        if not topics:
            return [], {"missing_in_bag": lidar_topics}

        roi_points_cache = defaultdict(list)

        for topic, msg, _t in bag.read_messages(topics=topics):
            per_topic_counter[topic] += 1
            if nth_frame > 1 and (per_topic_counter[topic] % nth_frame != 0):
                continue

            msg_type = getattr(msg, "_type", "")
            if msg_type != "sensor_msgs/PointCloud2":
                non_pc2_topics[topic] = msg_type
                continue

            lidar_name = topic_to_lidar_name(topic)

            for tid, roi in rois.items():
                key = (lidar_name, tid)
                acc[key]["frames_total"] += 1

                points_in_roi = 0
                for x, y, z, intensity in iter_points_xyz_intensity(msg):
                    if inside_roi(x, y, z, roi):
                        points_in_roi += 1

                        d = math.sqrt(x*x + y*y + z*z)
                        acc[key]["dist_sum"] += d
                        acc[key]["dist_sq_sum"] += d*d
                        acc[key]["dist_count"] += 1

                        if intensity is not None:
                            acc[key]["int_sum"] += intensity
                            acc[key]["int_sq_sum"] += intensity * intensity
                            acc[key]["int_count"] += 1

                        if dump_npz_dir is not None:
                            roi_points_cache[key].append([x, y, z, intensity if intensity is not None else 0.0])

                if points_in_roi > 0:
                    acc[key]["frames_hit"] += 1
                    acc[key]["points_sum"] += points_in_roi
                    acc[key]["points_max"] = max(acc[key]["points_max"], points_in_roi)
                    acc[key]["points_min"] = points_in_roi if acc[key]["points_min"] is None else min(acc[key]["points_min"], points_in_roi)

        if dump_npz_dir is not None:
            for (lidar_name, tid), pts in roi_points_cache.items():
                dump_npz(dump_npz_dir, bag_base, lidar_name, tid, pts)

    rows = []
    for topic in lidar_topics:
        lidar_name = topic_to_lidar_name(topic)
        for tid, tdef in targets.items():
            key = (lidar_name, tid)
            m = acc[key]
            ft = m["frames_total"]
            fh = m["frames_hit"]

            hit_ratio = (fh / ft) if ft > 0 else 0.0
            points_mean = (m["points_sum"] / fh) if fh > 0 else 0.0

            dist_mean = (m["dist_sum"] / m["dist_count"]) if m["dist_count"] > 0 else None
            dist_std = None
            if m["dist_count"] > 1 and dist_mean is not None:
                dist_var = (m["dist_sq_sum"] / m["dist_count"]) - (dist_mean * dist_mean)
                dist_std = math.sqrt(max(dist_var, 0.0))

            int_mean = (m["int_sum"] / m["int_count"]) if m["int_count"] > 0 else None
            int_std = None
            if m["int_count"] > 1 and int_mean is not None:
                int_var = (m["int_sq_sum"] / m["int_count"]) - (int_mean * int_mean)
                int_std = math.sqrt(max(int_var, 0.0))

            rows.append({
                "bag": bag_base,
                "lidar": lidar_name,
                "topic": topic,
                "target_id": tid,
                "expected_distance_m": tdef.get("expected_distance", ""),
                "frames_total": ft,
                "frames_hit": fh,
                "hit_ratio": round(hit_ratio, 6),
                "points_mean_when_hit": round(points_mean, 3),
                "points_min_when_hit": m["points_min"] if m["points_min"] is not None else 0,
                "points_max_when_hit": m["points_max"],
                "distance_mean_m": round(dist_mean, 4) if dist_mean is not None else "",
                "distance_std_m": round(dist_std, 4) if dist_std is not None else "",
                "intensity_mean": round(int_mean, 4) if int_mean is not None else "",
                "intensity_std": round(int_std, 4) if int_std is not None else "",
                "nth_frame": nth_frame,
            })

    return rows, {"non_pc2": non_pc2_topics}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bags", default="/navigator/logs/record/**/*.bag", help="Glob to bag files")
    ap.add_argument("--targets", default="/navigator/ads/config/targets.yaml")
    ap.add_argument("--profiles", default="/opt/rapidash/robot/rainman-v0/etc/default/record-profiles.yaml")
    ap.add_argument("--profile", default="ads")
    ap.add_argument("--out", default="/navigator/ads/results/searchbox_metrics.csv")
    ap.add_argument("--nth-frame", type=int, default=1)
    ap.add_argument("--dump-npz", default="", help="If set, dump ROI points into this directory")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.out), exist_ok=True)

    targets_cfg = load_yaml(args.targets)
    margin = float(targets_cfg.get("margin_m", 0.50))
    targets = targets_cfg["targets"]

    lidar_topics = load_topics_from_record_profiles(args.profiles, args.profile)

    bag_paths = sorted(glob.glob(args.bags, recursive=True))
    if not bag_paths:
        raise SystemExit(f"No bags found with: {args.bags}")

    dump_npz_dir = args.dump_npz.strip() or None
    if dump_npz_dir:
        os.makedirs(dump_npz_dir, exist_ok=True)

    all_rows = []
    global_non_pc2 = {}

    for bag_path in bag_paths:
        rows, warn = process_bag(
            bag_path=bag_path,
            lidar_topics=lidar_topics,
            targets=targets,
            margin=margin,
            nth_frame=max(1, args.nth_frame),
            dump_npz_dir=dump_npz_dir,
        )
        all_rows.extend(rows)
        global_non_pc2.update(warn.get("non_pc2", {}))

    if not all_rows:
        raise SystemExit("No rows generated. Check bags/topics/targets.")

    fieldnames = list(all_rows[0].keys())
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(all_rows)

    print(f"[OK] Wrote {len(all_rows)} rows to {args.out}")

    if global_non_pc2:
        print("\n[WARN] Some topics were not PointCloud2 and were skipped:")
        for t, ty in sorted(global_non_pc2.items()):
            print(f"  - {t} : {ty}")


if __name__ == "__main__":
    main()
