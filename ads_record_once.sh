#!/usr/bin/env bash
set -euo pipefail

# ============================================
# ads_record_once.sh (clean JSON + rainman_weather + distribution)
# - Trigger recording via weather_mocker only
# - Detect new bag object created during THIS run (bags are dirs *.bag)
# - Rename bag dir with prefix ads_<RECORD_ID>__
# - Write a JSON log (minimal, non-redundant) with:
#     record_id, timestamp_utc, status
#     ads_label, ads_condition
#     rainman_weather, rainman_weather_id
#     rainman_weather_distribution (during recording) + dominant
#     bag {ads_name, original_name, path}
#     weather_begin (parsed from /weather_data at start)
#     bag_topics_total + bag_checker_selected_row (full columns)
#     bag_checker_raw
#     active_record_requests_snippet
# ============================================

# CONFIG
RECORD_DURATION=120
SENSORS_STARTUP_DELAY=15
SAFETY_MARGIN=10

WEATHER_PUBLISH_WINDOW=30
WEATHER_PUBLISH_PERIOD=2
NEW_TIMEOUT=360

# NEW: sample real weather during the recording
WEATHER_SAMPLE_PERIOD=10   # seconds

TS="$(date +'%Y%m%d_%H%M%S')"
RECORD_ID="ADS_${TS}"

WEATHER_MOCKER="/navigator/sensorslab/resources-runtime/rainman/weather_mocker.py"
BAG_CHECKER="/navigator/sensorslab/resources-runtime/rainman/bag_checker.py"

EZLOGDIR="${EZLOGDIR:-/navigator/logs}"
RECORD_DIR="${EZLOGDIR%/}/record"

ADS_LOG_DIR="/navigator/logs/ads"
mkdir -p "$ADS_LOG_DIR"
LOG_JSON="${ADS_LOG_DIR}/${RECORD_ID}.json"

echo "[ADS] Record ID = $RECORD_ID"
echo "[ADS] RECORD_DIR = $RECORD_DIR"

# HELPERS
list_bag_objects() {
  find "$RECORD_DIR" -maxdepth 1 \
    \( -type d -name "*.bag" -o -type f -name "*.bag" -o -type f -name "*.bag.dir" \) \
    -printf "%y %f\n" 2>/dev/null | sort
}

rename_with_id() {
  local path="$1"
  local dir base new_base new_path
  dir="$(dirname "$path")"
  base="$(basename "$path")"

  [[ "$base" == "ads_${RECORD_ID}__"* ]] && { echo "$path"; return 0; }

  new_base="ads_${RECORD_ID}__${base}"
  new_path="${dir%/}/${new_base}"

  [[ -e "$new_path" ]] && { echo "$path"; return 0; }

  mv -- "$path" "$new_path"
  echo "$new_path"
}

# LOCK (avoid parallel runs)
LOCKFILE="/tmp/ads_record_once.lock"
exec 9>"$LOCKFILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { echo "[ADS] Already running, exit."; exit 0; }
fi

# ACTIVE RECORDING CHECK (skip if any active)
ACTIVE_RAW="$(rostopic echo -n1 /blackbox/active_record_requests 2>/dev/null || true)"
if echo "$ACTIVE_RAW" | grep -qE '^\s*-\s*name:'; then
  echo "[ADS] Active recording detected -> SKIP"
  STATUS="skipped_active_recording"
  CHECK_OUT="SKIPPED: active recording detected"
  WEATHER_RAW_BEGIN="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"

  export RECORD_ID STATUS CHECK_OUT WEATHER_RAW_BEGIN LOG_JSON
  export ACTIVE_RAW_END="$ACTIVE_RAW"
  export NEW_OBJ="" BAG_FINAL=""
  export WEATHER_SAMPLES=""   # none

  python3 <<'PY'
import os, json, re
from datetime import datetime, timezone

def f(pattern, txt):
    m = re.search(pattern, txt or "", re.MULTILINE)
    return float(m.group(1)) if m else None

def parse_weather(raw: str):
    if not raw:
        return {}
    d = {
        "visibility_m": f(r"visibility_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "rain_intensity_mmph": f(r"precipitation_mean_intensity_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "temperature_c": f(r"air_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "dew_point_c": f(r"dew_point_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "humidity_percent": f(r"hygrometry_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "humidity_raw_percent": f(r"hygrometry_raw_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "wind_mean_speed_10min_ms": f(r"mean_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "wind_mean_dir_10min_deg": f(r"mean_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "wind_max_speed_10min_ms": f(r"max_instantaneous_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "wind_max_dir_10min_deg": f(r"max_instantaneous_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "rain_over_1min_mm": f(r"over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "rain_over_24h_mm": f(r"over_24h:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "snow_particles": f(r"snow_particles:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "hail_particles": f(r"hail_particles:\s*\[(\-?\d+(\.\d+)?)\]", raw),
    }
    # ADS condition (keep your existing logic)
    vis = d.get("visibility_m")
    rain = d.get("rain_intensity_mmph")
    if vis is None:
        cond = None
    elif vis < 200: cond = "very_dense_fog"
    elif vis < 500: cond = "dense_fog"
    elif vis < 1000: cond = "fog"
    elif vis < 3000: cond = "mist"
    elif rain is not None and rain > 0: cond = "rain"
    else: cond = "clear"
    d["condition"] = cond
    return d

# Rainman official classification table (your list)
def classify_rainman(w: dict):
    if not w:
        return None, None
    snow = w.get("snow_particles")
    hail = w.get("hail_particles")
    vis  = w.get("visibility_m")
    rain = w.get("rain_intensity_mmph")

    if snow is not None and snow >= 2: return 0, "Snow"
    if hail is not None and hail >= 2: return 1, "Hail"

    if vis is not None:
        if vis <= 50:   return 2, "Very Dense Fog"
        if vis <= 100:  return 3, "Dense Fog"
        if vis <= 250:  return 4, "Fog"
        if vis <= 1000: return 5, "Mist"

    if rain is not None:
        if rain >= 15.0: return 6, "Heavy Rain"
        if rain >= 7.5:  return 7, "Moderate Rain"
        if rain >= 2.5:  return 8, "Light Rain"
        if rain > 0.0:   return 9, "Drizzle"
        if rain == 0.0:  return 10, "No Precipitation"
        if rain < 0.0:   return 11, "Debug"
    return None, None

wb = parse_weather(os.environ.get("WEATHER_RAW_BEGIN",""))
cond = wb.get("condition") if wb else None
rid, rlabel = classify_rainman(wb)

log = {
  "record_id": os.environ.get("RECORD_ID",""),
  "timestamp_utc": datetime.now(timezone.utc).isoformat(),
  "status": os.environ.get("STATUS",""),

  "ads_label": f"ADS {cond}" if cond else "ADS",
  "ads_condition": cond,

  "rainman_weather": rlabel,
  "rainman_weather_id": rid,
  "rainman_weather_distribution": None,
  "rainman_weather_dominant": None,

  "bag": {
    "ads_name": os.environ.get("RECORD_ID",""),
    "original_name": "",
    "path": "",
  },

  "weather_begin": wb,

  "bag_topics_total": None,
  "bag_checker_selected_row": None,
  "bag_checker_raw": os.environ.get("CHECK_OUT",""),

  "active_record_requests_snippet": (os.environ.get("ACTIVE_RAW_END","") or "")[:1500],
}

with open(os.environ["LOG_JSON"], "w") as f:
  json.dump(log, f, indent=2)

print("[ADS] Log written to", os.environ["LOG_JSON"])
PY
  exit 0
fi

# Snapshot BEFORE + weather begin
BEFORE="/tmp/${RECORD_ID}_before.txt"
AFTER="/tmp/${RECORD_ID}_after.txt"
list_bag_objects > "$BEFORE"
WEATHER_RAW_BEGIN="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"

# We will store weather samples during recording here (newline separated raw msgs)
WEATHER_SAMPLES_FILE="/tmp/${RECORD_ID}_weather_samples.txt"
: > "$WEATHER_SAMPLES_FILE"

# Publish weather mock
echo "[ADS] Publishing fake rain for ${WEATHER_PUBLISH_WINDOW}s..."
END=$(( $(date +%s) + WEATHER_PUBLISH_WINDOW ))
while (( $(date +%s) < END )); do
  python3 "$WEATHER_MOCKER" -r -1 >/dev/null 2>&1 || true
  sleep "$WEATHER_PUBLISH_PERIOD"
done

# Wait expected
echo "[ADS] Waiting sensors startup (${SENSORS_STARTUP_DELAY}s)..."
sleep "$SENSORS_STARTUP_DELAY"

# Sample /weather_data during the RECORD_DURATION
echo "[ADS] Recording window ${RECORD_DURATION}s (sampling weather every ${WEATHER_SAMPLE_PERIOD}s)..."
t_end=$(( $(date +%s) + RECORD_DURATION ))
while (( $(date +%s) < t_end )); do
  rostopic echo -n1 /weather_data 2>/dev/null >> "$WEATHER_SAMPLES_FILE" || true
  echo "---" >> "$WEATHER_SAMPLES_FILE"
  sleep "$WEATHER_SAMPLE_PERIOD"
done

echo "[ADS] Waiting flush margin (${SAFETY_MARGIN}s)..."
sleep "$SAFETY_MARGIN"

# Detect NEW bag object by diff
echo "[ADS] Waiting new bag object (timeout ${NEW_TIMEOUT}s)..."
NEW_OBJ=""
t0=$(date +%s)

while true; do
  list_bag_objects > "$AFTER"
  CAND="$(python3 - <<'PY' "$BEFORE" "$AFTER"
import sys
before=set(x.strip() for x in open(sys.argv[1]) if x.strip())
after=[x.strip() for x in open(sys.argv[2]) if x.strip()]
new=[x for x in after if x not in before]
print(new[-1] if new else "")
PY
)"
  if [[ -n "${CAND:-}" ]]; then
    NEW_OBJ="${CAND#* }"
    break
  fi
  now=$(date +%s)
  (( now - t0 > NEW_TIMEOUT )) && break
  sleep 1
done

STATUS="no_bag_created"
BAG_FINAL=""
CHECK_OUT="NO_NEW_OBJECT (cooldown/filtered/timing)"

if [[ -z "${NEW_OBJ:-}" ]]; then
  echo "[ADS] No new bag object detected."
else
  STATUS="ok"
  OBJ_PATH="${RECORD_DIR%/}/${NEW_OBJ}"
  echo "[ADS] New object: $OBJ_PATH"
  if [[ -e "$OBJ_PATH" ]]; then
    BAG_FINAL="$(rename_with_id "$OBJ_PATH")"
    echo "[ADS] Renamed bag object: $BAG_FINAL"
  fi
  CHECK_OUT="$(python3 "$BAG_CHECKER" -n 1 2>&1 || true)"
fi

ACTIVE_RAW_END="$(rostopic echo -n1 /blackbox/active_record_requests 2>/dev/null || true)"

export RECORD_ID STATUS NEW_OBJ BAG_FINAL CHECK_OUT WEATHER_RAW_BEGIN LOG_JSON ACTIVE_RAW_END
export WEATHER_SAMPLES_FILE

# JSON WRITER (MINIMAL + full selected row + rainman_weather + distribution)
python3 <<'PY'
import os, json, re
from datetime import datetime, timezone
from collections import Counter

def f(pattern, txt):
    m=re.search(pattern, txt or "", re.MULTILINE)
    return float(m.group(1)) if m else None

def parse_weather(raw):
    if not raw:
        return {}
    d={
        "visibility_m": f(r"visibility_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "rain_intensity_mmph": f(r"precipitation_mean_intensity_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "temperature_c": f(r"air_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "dew_point_c": f(r"dew_point_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "humidity_percent": f(r"hygrometry_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "humidity_raw_percent": f(r"hygrometry_raw_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "wind_mean_speed_10min_ms": f(r"mean_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "wind_mean_dir_10min_deg": f(r"mean_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "wind_max_speed_10min_ms": f(r"max_instantaneous_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "wind_max_dir_10min_deg": f(r"max_instantaneous_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "rain_over_1min_mm": f(r"over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "rain_over_24h_mm": f(r"over_24h:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "snow_particles": f(r"snow_particles:\s*\[(\-?\d+(\.\d+)?)\]", raw),
        "hail_particles": f(r"hail_particles:\s*\[(\-?\d+(\.\d+)?)\]", raw),
    }

    # ADS condition (keep your current logic)
    vis=d.get("visibility_m")
    rain=d.get("rain_intensity_mmph")
    if vis is None:
        cond=None
    elif vis<200: cond="very_dense_fog"
    elif vis<500: cond="dense_fog"
    elif vis<1000: cond="fog"
    elif vis<3000: cond="mist"
    elif rain is not None and rain>0: cond="rain"
    else: cond="clear"
    d["condition"]=cond
    return d

# Rainman official classification (your table)
def classify_rainman(w: dict):
    if not w:
        return None, None
    snow = w.get("snow_particles")
    hail = w.get("hail_particles")
    vis  = w.get("visibility_m")
    rain = w.get("rain_intensity_mmph")

    if snow is not None and snow >= 2: return 0, "Snow"
    if hail is not None and hail >= 2: return 1, "Hail"

    if vis is not None:
        if vis <= 50:   return 2, "Very Dense Fog"
        if vis <= 100:  return 3, "Dense Fog"
        if vis <= 250:  return 4, "Fog"
        if vis <= 1000: return 5, "Mist"

    if rain is not None:
        if rain >= 15.0: return 6, "Heavy Rain"
        if rain >= 7.5:  return 7, "Moderate Rain"
        if rain >= 2.5:  return 8, "Light Rain"
        if rain > 0.0:   return 9, "Drizzle"
        if rain == 0.0:  return 10, "No Precipitation"
        if rain < 0.0:   return 11, "Debug"
    return None, None

def parse_selected_row_and_total(raw_table: str):
    if not raw_table:
        return None, None

    lines = [ln.rstrip("\n") for ln in raw_table.splitlines()]
    header_idx = None
    for i, ln in enumerate(lines):
        if ln.strip().startswith("Bag File") and " | " in ln:
            header_idx = i
            break
    if header_idx is None:
        return None, None

    headers = [h.strip() for h in lines[header_idx].split("|")]
    data_lines = lines[header_idx + 2:] if header_idx + 2 < len(lines) else []

    row_line = None
    for ln in data_lines:
        if ".bag" in ln and " | " in ln:
            row_line = ln
            break
    if row_line is None:
        return None, None

    parts = [p.strip() for p in row_line.split("|")]
    if len(parts) < len(headers):
        parts += [""] * (len(headers) - len(parts))
    if len(parts) > len(headers):
        parts = parts[:len(headers)]

    selected_row = dict(zip(headers, parts))

    total = 0
    for k, v in list(selected_row.items()):
        if k == "Bag File":
            continue
        vv = str(v).strip()
        try:
            iv = int(vv)
        except:
            iv = 0
        selected_row[k] = iv
        total += iv

    return selected_row, total

def read_weather_samples(path: str):
    """Read /tmp/..._weather_samples.txt separated by lines '---'."""
    if not path or not os.path.isfile(path):
        return []
    txt = open(path, "r", errors="ignore").read()
    blocks = [b.strip() for b in txt.split("---") if b.strip()]
    return blocks

record_id = os.environ.get("RECORD_ID","")
status = os.environ.get("STATUS","")
bag_original = os.environ.get("NEW_OBJ","")
bag_final = os.environ.get("BAG_FINAL","")
raw_table = os.environ.get("CHECK_OUT","")
weather_raw_begin = os.environ.get("WEATHER_RAW_BEGIN","")
active_raw = os.environ.get("ACTIVE_RAW_END","")
samples_file = os.environ.get("WEATHER_SAMPLES_FILE","")

wb = parse_weather(weather_raw_begin)
cond = wb.get("condition") if wb else None

# rainman class at begin
rainman_id, rainman_label = classify_rainman(wb)

# distribution during the recording
dist = None
dominant = None
sample_blocks = read_weather_samples(samples_file)
if sample_blocks:
    labels = []
    for b in sample_blocks:
        w = parse_weather(b)
        _, lab = classify_rainman(w)
        if lab:
            labels.append(lab)
    if labels:
        c = Counter(labels)
        total = sum(c.values())
        dist = {k: int(round(v*100/total)) for k, v in c.items()}
        dominant = max(c.items(), key=lambda kv: kv[1])[0]

selected_row, topics_total = parse_selected_row_and_total(raw_table)

log = {
  "record_id": record_id,
  "timestamp_utc": datetime.now(timezone.utc).isoformat(),
  "status": status,

  "ads_label": f"ADS {cond}" if cond else "ADS",
  "ads_condition": cond,

  # NEW: official Rainman classification
  "rainman_weather": rainman_label,
  "rainman_weather_id": rainman_id,
  "rainman_weather_distribution": dist,
  "rainman_weather_dominant": dominant,

  "bag": {
    "ads_name": record_id,
    "original_name": bag_original,
    "path": bag_final,
  },

  "weather_begin": wb,

  "bag_topics_total": topics_total,
  "bag_checker_selected_row": selected_row,
  "bag_checker_raw": raw_table,

  "active_record_requests_snippet": (active_raw or "")[:1500],
}

with open(os.environ["LOG_JSON"], "w") as f:
  json.dump(log, f, indent=2)

print("[ADS] Log written to", os.environ["LOG_JSON"])
PY

echo "[ADS] Done."








#TOUT MARCHE A REMETTRE SI BESOIN
# #!/usr/bin/env bash
# set -euo pipefail

# # ============================================
# # ads_record_once.sh (clean JSON)
# # - Trigger recording via weather_mocker only
# # - Detect new bag object created during THIS run (bags are dirs *.bag)
# # - Rename bag dir with prefix ads_<RECORD_ID>__
# # - Write a JSON log (minimal, non-redundant) with:
# #     record_id, timestamp_utc, status
# #     ads_label, ads_condition
# #     bag {ads_name, original_name, path}
# #     weather_begin (parsed from /weather_data at start)
# #     bag_topics_total + bag_checker_selected_row (full columns)
# #     bag_checker_raw
# #     active_record_requests_snippet
# # ============================================

# # ----------------------------
# # CONFIG
# # ----------------------------
# RECORD_DURATION=120
# SENSORS_STARTUP_DELAY=15
# SAFETY_MARGIN=10

# WEATHER_PUBLISH_WINDOW=30
# WEATHER_PUBLISH_PERIOD=2
# NEW_TIMEOUT=360

# TS="$(date +'%Y%m%d_%H%M%S')"
# RECORD_ID="ADS_${TS}"

# WEATHER_MOCKER="/navigator/sensorslab/resources-runtime/rainman/weather_mocker.py"
# BAG_CHECKER="/navigator/sensorslab/resources-runtime/rainman/bag_checker.py"

# EZLOGDIR="${EZLOGDIR:-/navigator/logs}"
# RECORD_DIR="${EZLOGDIR%/}/record"

# ADS_LOG_DIR="/navigator/logs/ads"
# mkdir -p "$ADS_LOG_DIR"
# LOG_JSON="${ADS_LOG_DIR}/${RECORD_ID}.json"

# echo "[ADS] Record ID = $RECORD_ID"
# echo "[ADS] RECORD_DIR = $RECORD_DIR"

# # ----------------------------
# # HELPERS
# # ----------------------------
# list_bag_objects() {
#   find "$RECORD_DIR" -maxdepth 1 \
#     \( -type d -name "*.bag" -o -type f -name "*.bag" -o -type f -name "*.bag.dir" \) \
#     -printf "%y %f\n" 2>/dev/null | sort
# }

# rename_with_id() {
#   local path="$1"
#   local dir base new_base new_path
#   dir="$(dirname "$path")"
#   base="$(basename "$path")"

#   [[ "$base" == "ads_${RECORD_ID}__"* ]] && { echo "$path"; return 0; }

#   new_base="ads_${RECORD_ID}__${base}"
#   new_path="${dir%/}/${new_base}"

#   [[ -e "$new_path" ]] && { echo "$path"; return 0; }

#   mv -- "$path" "$new_path"
#   echo "$new_path"
# }

# # ----------------------------
# # LOCK (avoid parallel runs)
# # ----------------------------
# LOCKFILE="/tmp/ads_record_once.lock"
# exec 9>"$LOCKFILE"
# if command -v flock >/dev/null 2>&1; then
#   flock -n 9 || { echo "[ADS] Already running, exit."; exit 0; }
# fi

# # ----------------------------
# # ACTIVE RECORDING CHECK (skip if any active)
# # ----------------------------
# ACTIVE_RAW="$(rostopic echo -n1 /blackbox/active_record_requests 2>/dev/null || true)"
# if echo "$ACTIVE_RAW" | grep -qE '^\s*-\s*name:'; then
#   echo "[ADS] Active recording detected -> SKIP"
#   STATUS="skipped_active_recording"
#   CHECK_OUT="SKIPPED: active recording detected"
#   WEATHER_RAW_BEGIN="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"

#   export RECORD_ID STATUS CHECK_OUT WEATHER_RAW_BEGIN LOG_JSON
#   export ACTIVE_RAW_END="$ACTIVE_RAW"
#   export NEW_OBJ="" BAG_FINAL=""

#   python3 <<'PY'
# import os, json, re
# from datetime import datetime, timezone

# def f(pattern, txt):
#     m = re.search(pattern, txt or "", re.MULTILINE)
#     return float(m.group(1)) if m else None

# def parse_weather(raw: str):
#     if not raw:
#         return {}
#     d = {
#         "visibility_m": f(r"visibility_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_intensity_mmph": f(r"precipitation_mean_intensity_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "temperature_c": f(r"air_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "dew_point_c": f(r"dew_point_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_percent": f(r"hygrometry_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_raw_percent": f(r"hygrometry_raw_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_speed_10min_ms": f(r"mean_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_dir_10min_deg": f(r"mean_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_max_speed_10min_ms": f(r"max_instantaneous_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_max_dir_10min_deg": f(r"max_instantaneous_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_over_1min_mm": f(r"over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_over_24h_mm": f(r"over_24h:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#     }
#     vis = d.get("visibility_m")
#     rain = d.get("rain_intensity_mmph")
#     if vis is None:
#         cond = None
#     elif vis < 200:
#         cond = "very_dense_fog"
#     elif vis < 500:
#         cond = "dense_fog"
#     elif vis < 1000:
#         cond = "fog"
#     elif vis < 3000:
#         cond = "mist"
#     elif rain is not None and rain > 0:
#         cond = "rain"
#     else:
#         cond = "clear"
#     d["condition"] = cond
#     return d

# wb = parse_weather(os.environ.get("WEATHER_RAW_BEGIN",""))
# cond = wb.get("condition") if wb else None

# log = {
#   "record_id": os.environ.get("RECORD_ID",""),
#   "timestamp_utc": datetime.now(timezone.utc).isoformat(),
#   "status": os.environ.get("STATUS",""),

#   "ads_label": f"ADS {cond}" if cond else "ADS",
#   "ads_condition": cond,

#   "bag": {
#     "ads_name": os.environ.get("RECORD_ID",""),
#     "original_name": "",
#     "path": "",
#   },

#   "weather_begin": wb,

#   "bag_topics_total": None,
#   "bag_checker_selected_row": None,
#   "bag_checker_raw": os.environ.get("CHECK_OUT",""),

#   "active_record_requests_snippet": (os.environ.get("ACTIVE_RAW_END","") or "")[:1500],
# }

# with open(os.environ["LOG_JSON"], "w") as f:
#   json.dump(log, f, indent=2)

# print("[ADS] Log written to", os.environ["LOG_JSON"])
# PY

#   exit 0
# fi

# # ----------------------------
# # Snapshot BEFORE + weather begin
# # ----------------------------
# BEFORE="/tmp/${RECORD_ID}_before.txt"
# AFTER="/tmp/${RECORD_ID}_after.txt"
# list_bag_objects > "$BEFORE"
# WEATHER_RAW_BEGIN="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"

# # ----------------------------
# # Publish weather mock
# # ----------------------------
# echo "[ADS] Publishing fake rain for ${WEATHER_PUBLISH_WINDOW}s..."
# END=$(( $(date +%s) + WEATHER_PUBLISH_WINDOW ))
# while (( $(date +%s) < END )); do
#   python3 "$WEATHER_MOCKER" -r -1 >/dev/null 2>&1 || true
#   sleep "$WEATHER_PUBLISH_PERIOD"
# done

# # ----------------------------
# # Wait expected
# # ----------------------------
# echo "[ADS] Waiting sensors startup (${SENSORS_STARTUP_DELAY}s)..."
# sleep "$SENSORS_STARTUP_DELAY"
# echo "[ADS] Waiting expected recording duration (${RECORD_DURATION}s)..."
# sleep "$RECORD_DURATION"
# echo "[ADS] Waiting flush margin (${SAFETY_MARGIN}s)..."
# sleep "$SAFETY_MARGIN"

# # ----------------------------
# # Detect NEW bag object by diff
# # ----------------------------
# echo "[ADS] Waiting new bag object (timeout ${NEW_TIMEOUT}s)..."
# NEW_OBJ=""
# t0=$(date +%s)

# while true; do
#   list_bag_objects > "$AFTER"
#   CAND="$(python3 - <<'PY' "$BEFORE" "$AFTER"
# import sys
# before=set(x.strip() for x in open(sys.argv[1]) if x.strip())
# after=[x.strip() for x in open(sys.argv[2]) if x.strip()]
# new=[x for x in after if x not in before]
# print(new[-1] if new else "")
# PY
# )"
#   if [[ -n "${CAND:-}" ]]; then
#     NEW_OBJ="${CAND#* }"
#     break
#   fi
#   now=$(date +%s)
#   (( now - t0 > NEW_TIMEOUT )) && break
#   sleep 1
# done

# STATUS="no_bag_created"
# BAG_FINAL=""
# CHECK_OUT="NO_NEW_OBJECT (cooldown/filtered/timing)"

# if [[ -z "${NEW_OBJ:-}" ]]; then
#   echo "[ADS] No new bag object detected."
# else
#   STATUS="ok"
#   OBJ_PATH="${RECORD_DIR%/}/${NEW_OBJ}"
#   echo "[ADS] New object: $OBJ_PATH"
#   if [[ -e "$OBJ_PATH" ]]; then
#     BAG_FINAL="$(rename_with_id "$OBJ_PATH")"
#     echo "[ADS] Renamed bag object: $BAG_FINAL"
#   fi
#   CHECK_OUT="$(python3 "$BAG_CHECKER" -n 1 2>&1 || true)"
# fi

# ACTIVE_RAW_END="$(rostopic echo -n1 /blackbox/active_record_requests 2>/dev/null || true)"

# export RECORD_ID STATUS NEW_OBJ BAG_FINAL CHECK_OUT WEATHER_RAW_BEGIN LOG_JSON ACTIVE_RAW_END

# # ----------------------------
# # JSON WRITER (MINIMAL + full selected row)
# # ----------------------------
# python3 <<'PY'
# import os, json, re
# from datetime import datetime, timezone

# def f(pattern, txt):
#     m=re.search(pattern, txt or "", re.MULTILINE)
#     return float(m.group(1)) if m else None

# def parse_weather(raw):
#     if not raw:
#         return {}
#     d={
#         "visibility_m": f(r"visibility_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_intensity_mmph": f(r"precipitation_mean_intensity_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "temperature_c": f(r"air_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "dew_point_c": f(r"dew_point_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_percent": f(r"hygrometry_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_raw_percent": f(r"hygrometry_raw_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_speed_10min_ms": f(r"mean_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_dir_10min_deg": f(r"mean_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_max_speed_10min_ms": f(r"max_instantaneous_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_max_dir_10min_deg": f(r"max_instantaneous_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_over_1min_mm": f(r"over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_over_24h_mm": f(r"over_24h:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#     }

#     vis=d.get("visibility_m")
#     rain=d.get("rain_intensity_mmph")
#     if vis is None:
#         cond=None
#     elif vis<200:
#         cond="very_dense_fog"
#     elif vis<500:
#         cond="dense_fog"
#     elif vis<1000:
#         cond="fog"
#     elif vis<3000:
#         cond="mist"
#     elif rain is not None and rain>0:
#         cond="rain"
#     else:
#         cond="clear"
#     d["condition"]=cond
#     return d

# def parse_selected_row_and_total(raw_table: str):
#     """
#     Parse bag_checker ASCII table (-n 1) and returns:
#       - selected_row dict with all columns (Bag File + topics)
#       - total messages sum
#     """
#     if not raw_table:
#         return None, None

#     lines = [ln.rstrip("\n") for ln in raw_table.splitlines()]

#     header_idx = None
#     for i, ln in enumerate(lines):
#         if ln.strip().startswith("Bag File") and " | " in ln:
#             header_idx = i
#             break
#     if header_idx is None:
#         return None, None

#     headers = [h.strip() for h in lines[header_idx].split("|")]

#     data_lines = lines[header_idx + 2:] if header_idx + 2 < len(lines) else []
#     row_line = None
#     for ln in data_lines:
#         if ".bag" in ln and " | " in ln:
#             row_line = ln
#             break
#     if row_line is None:
#         return None, None

#     parts = [p.strip() for p in row_line.split("|")]
#     if len(parts) < len(headers):
#         parts += [""] * (len(headers) - len(parts))
#     if len(parts) > len(headers):
#         parts = parts[:len(headers)]

#     selected_row = dict(zip(headers, parts))

#     total = 0
#     for k, v in list(selected_row.items()):
#         if k == "Bag File":
#             continue
#         vv = str(v).strip()
#         try:
#             iv = int(vv)
#         except:
#             iv = 0
#         selected_row[k] = iv
#         total += iv

#     return selected_row, total

# record_id = os.environ.get("RECORD_ID","")
# status = os.environ.get("STATUS","")
# bag_original = os.environ.get("NEW_OBJ","")
# bag_final = os.environ.get("BAG_FINAL","")
# raw_table = os.environ.get("CHECK_OUT","")
# weather_raw_begin = os.environ.get("WEATHER_RAW_BEGIN","")
# active_raw = os.environ.get("ACTIVE_RAW_END","")

# wb = parse_weather(weather_raw_begin)
# cond = wb.get("condition") if wb else None

# selected_row, topics_total = parse_selected_row_and_total(raw_table)

# log = {
#   "record_id": record_id,
#   "timestamp_utc": datetime.now(timezone.utc).isoformat(),
#   "status": status,

#   "ads_label": f"ADS {cond}" if cond else "ADS",
#   "ads_condition": cond,

#   "bag": {
#     "ads_name": record_id,
#     "original_name": bag_original,
#     "path": bag_final,
#   },

#   "weather_begin": wb,

#   "bag_topics_total": topics_total,
#   "bag_checker_selected_row": selected_row,
#   "bag_checker_raw": raw_table,

#   "active_record_requests_snippet": (active_raw or "")[:1500],
# }

# with open(os.environ["LOG_JSON"], "w") as f:
#   json.dump(log, f, indent=2)

# print("[ADS] Log written to", os.environ["LOG_JSON"])
# PY

# echo "[ADS] Done."









# #!/usr/bin/env bash
# set -euo pipefail

# # ============================================
# # ads_record_once.sh
# # - Trigger a recording via weather_mocker only
# # - Detect the bag created during THIS run (bags are directories *.bag)
# # - Rename the bag directory with prefix ads_<RECORD_ID>__
# # - Write a JSON log with:
# #     * bag info (original + renamed)
# #     * weather (begin/end + summary)
# #     * weather_like_dashboard (labels close to your UI)
# #     * bag topics message counts (parsed from bag_checker output)
# # ============================================

# # ----------------------------
# # CONFIG
# # ----------------------------
# RECORD_DURATION=120
# SENSORS_STARTUP_DELAY=15
# SAFETY_MARGIN=10

# WEATHER_PUBLISH_WINDOW=30
# WEATHER_PUBLISH_PERIOD=2
# NEW_TIMEOUT=360

# TS="$(date +'%Y%m%d_%H%M%S')"
# RECORD_ID="ADS_${TS}"

# WEATHER_MOCKER="/navigator/sensorslab/resources-runtime/rainman/weather_mocker.py"
# BAG_CHECKER="/navigator/sensorslab/resources-runtime/rainman/bag_checker.py"

# EZLOGDIR="${EZLOGDIR:-/navigator/logs}"
# RECORD_DIR="${EZLOGDIR%/}/record"

# ADS_LOG_DIR="/navigator/logs/ads"
# mkdir -p "$ADS_LOG_DIR"
# LOG_JSON="${ADS_LOG_DIR}/${RECORD_ID}.json"

# echo "[ADS] Record ID = $RECORD_ID"
# echo "[ADS] RECORD_DIR = $RECORD_DIR"

# # ----------------------------
# # HELPERS
# # ----------------------------
# list_bag_objects() {
#   # Bags on your system are directories (*.bag). Keep support for files too.
#   find "$RECORD_DIR" -maxdepth 1 \
#     \( -type d -name "*.bag" -o -type f -name "*.bag" -o -type f -name "*.bag.dir" \) \
#     -printf "%y %f\n" 2>/dev/null | sort
# }

# rename_with_id() {
#   local path="$1"
#   local dir base new_base new_path
#   dir="$(dirname "$path")"
#   base="$(basename "$path")"

#   [[ "$base" == "ads_${RECORD_ID}__"* ]] && { echo "$path"; return 0; }

#   new_base="ads_${RECORD_ID}__${base}"
#   new_path="${dir%/}/${new_base}"

#   [[ -e "$new_path" ]] && { echo "$path"; return 0; }

#   mv -- "$path" "$new_path"
#   echo "$new_path"
# }

# # ----------------------------
# # LOCK (avoid parallel runs)
# # ----------------------------
# LOCKFILE="/tmp/ads_record_once.lock"
# exec 9>"$LOCKFILE"
# if command -v flock >/dev/null 2>&1; then
#   flock -n 9 || { echo "[ADS] Already running, exit."; exit 0; }
# fi

# # ----------------------------
# # ACTIVE RECORDING CHECK (skip if any active)
# # ----------------------------
# ACTIVE_RAW="$(rostopic echo -n1 /blackbox/active_record_requests 2>/dev/null || true)"
# if echo "$ACTIVE_RAW" | grep -qE '^\s*-\s*name:'; then
#   echo "[ADS] Active recording detected -> SKIP"
#   STATUS="skipped_active_recording"
#   CHECK_OUT="SKIPPED: active recording detected"
#   WEATHER_RAW_BEGIN="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"
#   WEATHER_RAW_END="$WEATHER_RAW_BEGIN"

#   export STATUS CHECK_OUT WEATHER_RAW_BEGIN WEATHER_RAW_END
#   export ACTIVE_RAW_END="$ACTIVE_RAW"
#   export RECORD_ID RECORD_DURATION SENSORS_STARTUP_DELAY EZLOGDIR LOG_JSON
#   export NEW_OBJ="" BAG_FINAL=""

#   python3 <<'PY'
# import os, json, re
# from datetime import datetime, timezone

# def ef(pattern, txt):
#     m = re.search(pattern, txt or "", re.MULTILINE)
#     return float(m.group(1)) if m else None

# def parse_weather(raw: str):
#     if not raw:
#         return {}
#     d = {
#         "visibility_m": ef(r"visibility_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_intensity_mmph": ef(r"precipitation_mean_intensity_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "temperature_c": ef(r"air_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "dew_point_c": ef(r"dew_point_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_percent": ef(r"hygrometry_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_raw_percent": ef(r"hygrometry_raw_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_speed_10min_ms": ef(r"mean_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_dir_10min_deg": ef(r"mean_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         # optional (may be absent)
#         "wind_max_speed_10min_ms": ef(r"max_instantaneous_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_max_dir_10min_deg": ef(r"max_instantaneous_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_24h_mm": ef(r"over_24h:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_1min_mm": ef(r"over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#     }
#     vis = d.get("visibility_m")
#     rain = d.get("rain_intensity_mmph")
#     if vis is None:
#         cond = None
#     elif vis < 200: cond = "very_dense_fog"
#     elif vis < 500: cond = "dense_fog"
#     elif vis < 1000: cond = "fog"
#     elif vis < 3000: cond = "mist"
#     elif rain is not None and rain > 0: cond = "rain"
#     else: cond = "clear"
#     d["condition"] = cond
#     return d

# def dashboard_like(w):
#     if not w:
#         return {}
#     return {
#         "temperature_air_c": w.get("temperature_c"),
#         "humidity_percent": w.get("humidity_percent"),
#         "dew_point_c": w.get("dew_point_c"),
#         "precip_24h_mm": w.get("rain_24h_mm"),
#         "precip_intensity_mmph": w.get("rain_intensity_mmph"),
#         "precip_type": w.get("condition"),
#         "visibility_m": w.get("visibility_m"),
#         "wind_speed_10min_ms": w.get("wind_mean_speed_10min_ms"),
#         "wind_direction_10min_deg": w.get("wind_mean_dir_10min_deg"),
#         "wind_max_10min_ms": w.get("wind_max_speed_10min_ms"),
#         "wind_max_dir_10min_deg": w.get("wind_max_dir_10min_deg"),
#     }

# wb = parse_weather(os.environ.get("WEATHER_RAW_BEGIN",""))
# we = parse_weather(os.environ.get("WEATHER_RAW_END",""))
# ws = we or wb
# cond = ws.get("condition") if ws else None

# log = {
#   "record_id": record_id,
#   "timestamp_utc": datetime.now(timezone.utc).isoformat(),
#   "status": status,

#   "ads_label": f"ADS {cond}" if cond else "ADS",
#   "ads_condition": cond,

#   "bag": {
#     "ads_name": record_id,
#     "original_name": bag_original,
#     "path": bag_final,
#   },

#   # 👉 météo début uniquement (comme tu veux)
#   "weather_begin": wb,

#   # 👉 stats bag utiles
#   "bag_topics_total": topics_total,
#   "bag_checker_selected_row": selected_row,

#   # 👉 tableau lisible
#   "bag_checker_raw": raw_table,

#   "active_record_requests_snippet": (os.environ.get("ACTIVE_RAW_END","") or "")[:1500],
# }

# with open(os.environ["LOG_JSON"], "w") as f:
#   json.dump(log, f, indent=2)

# print("[ADS] Log written to", os.environ["LOG_JSON"])
# PY
#   exit 0
# fi

# # ----------------------------
# # Snapshot BEFORE + weather begin
# # ----------------------------
# BEFORE="/tmp/${RECORD_ID}_before.txt"
# AFTER="/tmp/${RECORD_ID}_after.txt"
# list_bag_objects > "$BEFORE"
# WEATHER_RAW_BEGIN="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"

# # ----------------------------
# # Publish weather mock to trigger
# # ----------------------------
# echo "[ADS] Publishing fake rain for ${WEATHER_PUBLISH_WINDOW}s..."
# END=$(( $(date +%s) + WEATHER_PUBLISH_WINDOW ))
# while (( $(date +%s) < END )); do
#   python3 "$WEATHER_MOCKER" -r -1 >/dev/null 2>&1 || true
#   sleep "$WEATHER_PUBLISH_PERIOD"
# done

# # ----------------------------
# # Wait (expected)
# # ----------------------------
# echo "[ADS] Waiting sensors startup (${SENSORS_STARTUP_DELAY}s)..."
# sleep "$SENSORS_STARTUP_DELAY"

# echo "[ADS] Waiting expected recording duration (${RECORD_DURATION}s)..."
# sleep "$RECORD_DURATION"

# echo "[ADS] Waiting flush margin (${SAFETY_MARGIN}s)..."
# sleep "$SAFETY_MARGIN"

# # ----------------------------
# # Detect NEW bag object by diff
# # ----------------------------
# echo "[ADS] Waiting new bag object (timeout ${NEW_TIMEOUT}s)..."
# NEW_OBJ=""
# t0=$(date +%s)
# while true; do
#   list_bag_objects > "$AFTER"
#   CAND="$(python3 - <<'PY' "$BEFORE" "$AFTER"
# import sys
# before=set(x.strip() for x in open(sys.argv[1]) if x.strip())
# after=[x.strip() for x in open(sys.argv[2]) if x.strip()]
# new=[x for x in after if x not in before]
# print(new[-1] if new else "")
# PY
# )"
#   if [[ -n "${CAND:-}" ]]; then
#     NEW_OBJ="${CAND#* }"
#     break
#   fi
#   now=$(date +%s)
#   (( now - t0 > NEW_TIMEOUT )) && break
#   sleep 1
# done

# WEATHER_RAW_END="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"

# STATUS="no_bag_created"
# BAG_FINAL=""
# CHECK_OUT="NO_NEW_OBJECT (cooldown/filtered/timing)"

# if [[ -z "${NEW_OBJ:-}" ]]; then
#   echo "[ADS] No new bag object detected."
# else
#   STATUS="ok"
#   OBJ_PATH="${RECORD_DIR%/}/${NEW_OBJ}"
#   echo "[ADS] New object: $OBJ_PATH"
#   if [[ -e "$OBJ_PATH" ]]; then
#     BAG_FINAL="$(rename_with_id "$OBJ_PATH")"
#     echo "[ADS] Renamed bag object: $BAG_FINAL"
#   fi

#   # Info-only (we will PARSE it to get per-topic counts)
#   CHECK_OUT="$(python3 "$BAG_CHECKER" -n 1 2>&1 || true)"
# fi

# ACTIVE_RAW_END="$(rostopic echo -n1 /blackbox/active_record_requests 2>/dev/null || true)"

# export RECORD_ID STATUS NEW_OBJ BAG_FINAL CHECK_OUT
# export WEATHER_RAW_BEGIN WEATHER_RAW_END
# export ACTIVE_RAW_END
# export RECORD_DURATION SENSORS_STARTUP_DELAY EZLOGDIR LOG_JSON

# # ----------------------------
# # JSON writer (weather + dashboard-like + topics)
# # ----------------------------
# python3 <<'PY'
# import os, json, re
# from datetime import datetime, timezone

# def ef(pattern, txt):
#     m = re.search(pattern, txt or "", re.MULTILINE)
#     return float(m.group(1)) if m else None

# def parse_weather(raw: str):
#     if not raw:
#         return {}
#     d = {
#         "visibility_m": ef(r"visibility_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_intensity_mmph": ef(r"precipitation_mean_intensity_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "temperature_c": ef(r"air_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "dew_point_c": ef(r"dew_point_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_percent": ef(r"hygrometry_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_raw_percent": ef(r"hygrometry_raw_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_speed_10min_ms": ef(r"mean_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_dir_10min_deg": ef(r"mean_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         # these exist in your message (wind max instantaneous)
#         "wind_max_speed_10min_ms": ef(r"max_instantaneous_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_max_dir_10min_deg": ef(r"max_instantaneous_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         # rain accumulation: only over_1min is present in your sample; 24h may be absent
#         "rain_over_1min_mm": ef(r"over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "rain_over_24h_mm": ef(r"over_24h:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#     }
#     vis = d.get("visibility_m")
#     rain = d.get("rain_intensity_mmph")
#     if vis is None:
#         cond = None
#     elif vis < 200: cond = "very_dense_fog"
#     elif vis < 500: cond = "dense_fog"
#     elif vis < 1000: cond = "fog"
#     elif vis < 3000: cond = "mist"
#     elif rain is not None and rain > 0: cond = "rain"
#     else: cond = "clear"
#     d["condition"] = cond
#     return d

# def weather_like_dashboard(w):
#     """Keys match what you see on the Sterela UI."""
#     if not w:
#         return {}
#     return {
#         "temperature_air_c": w.get("temperature_c"),
#         "humidity_percent": w.get("humidity_percent"),
#         "dew_point_c": w.get("dew_point_c"),

#         "precip_cumul_24h_mm": w.get("rain_over_24h_mm"),          # may be None if not provided
#         "precip_intensity_mmph": w.get("rain_intensity_mmph"),
#         "precip_type": w.get("condition"),                         # as a friendly "type"
#         "visibility_m": w.get("visibility_m"),

#         "wind_speed_10min_ms": w.get("wind_mean_speed_10min_ms"),
#         "wind_direction_10min_deg": w.get("wind_mean_dir_10min_deg"),
#         "wind_max_10min_ms": w.get("wind_max_speed_10min_ms"),
#         "wind_max_dir_10min_deg": w.get("wind_max_dir_10min_deg"),
#     }

# def parse_bag_checker_table(raw: str, target_bag: str | None):
#     if not raw:
#         return None, {}
#     lines = [ln.rstrip("\n") for ln in raw.splitlines()]
#     header_idx = None
#     for i, ln in enumerate(lines):
#         if ln.strip().startswith("Bag File") and " | " in ln:
#             header_idx = i
#             break
#     if header_idx is None:
#         return None, {}

#     headers = [h.strip() for h in lines[header_idx].split("|")]
#     data_lines = lines[header_idx + 2:] if header_idx + 2 < len(lines) else []

#     rows = []
#     for ln in data_lines:
#         if " | " not in ln:
#             continue
#         parts = [p.strip() for p in ln.split("|")]
#         if len(parts) < len(headers):
#             parts += [""] * (len(headers) - len(parts))
#         if len(parts) > len(headers):
#             parts = parts[:len(headers)]
#         row = dict(zip(headers, parts))
#         for k, v in list(row.items()):
#             if k == "Bag File":
#                 continue
#             vv = v.strip()
#             if vv == "":
#                 row[k] = 0
#                 continue
#             try:
#                 row[k] = int(vv)
#             except Exception:
#                 row[k] = v
#         rows.append(row)

#     selected = None
#     if target_bag:
#         for r in rows:
#             if r.get("Bag File") == target_bag:
#                 selected = r
#                 break
#     if selected is None and rows:
#         selected = rows[0]

#     topics = {}
#     if selected:
#         for k, v in selected.items():
#             if k == "Bag File":
#                 continue
#             if isinstance(v, int):
#                 topics[k] = v
#             else:
#                 try:
#                     topics[k] = int(str(v).strip())
#                 except Exception:
#                     pass
#     return selected, topics

# record_id = os.environ.get("RECORD_ID","")
# status = os.environ.get("STATUS","")
# bag_original = os.environ.get("NEW_OBJ","")
# bag_final = os.environ.get("BAG_FINAL","")
# raw_table = os.environ.get("CHECK_OUT","")

# wb = parse_weather(os.environ.get("WEATHER_RAW_BEGIN",""))
# we = parse_weather(os.environ.get("WEATHER_RAW_END",""))
# ws = we or wb
# cond = ws.get("condition") if ws else None

# selected_row, topics = parse_bag_checker_table(raw_table, bag_original if bag_original else None)

# log = {
#   "record_id": record_id,
#   "timestamp_utc": datetime.now(timezone.utc).isoformat(),
#   "status": status,

#   "ads_label": f"ADS {cond}" if cond else "ADS",
#   "ads_condition": cond,

#   "bag": {
#     "ads_name": record_id,
#     "original_name": bag_original,
#     "path": bag_final,
#   },

#   "weather": ws,
#   "weather_begin": wb,
#   "weather_end": we,

#   # Dashboard-like view (close to your Sterela UI)
#   "weather_like_dashboard": weather_like_dashboard(ws),

#   # Bag topics counts (clean)
#   "bag_topics": topics,
#   "bag_topics_total": int(sum(topics.values())) if topics else 0,

#   # Optional debug
#   "bag_checker_selected_row": selected_row,
#   "bag_checker_raw": raw_table,
#   "active_record_requests_snippet": (os.environ.get("ACTIVE_RAW_END","") or "")[:1500],
# }

# with open(os.environ["LOG_JSON"], "w") as f:
#   json.dump(log, f, indent=2)

# print("[ADS] Log written to", os.environ["LOG_JSON"])
# PY

# echo "[ADS] Done."








# Parfait tout marche manque données meteo
# #!/usr/bin/env bash
# set -euo pipefail

# # ============================================
# # ADS record once (weather trigger only)
# # - Publish weather (via weather_mocker)
# # - Wait expected record duration
# # - Detect new bag object created during THIS run (your bags are directories *.bag)
# # - Rename the bag directory with ads_<RECORD_ID>__ prefix
# # - Write JSON log including real weather values (temp/humidity/rain/visibility/wind)
# # ============================================

# # ----------------------------
# # CONFIG
# # ----------------------------
# RECORD_DURATION=120
# SENSORS_STARTUP_DELAY=15
# SAFETY_MARGIN=10

# WEATHER_PUBLISH_WINDOW=30
# WEATHER_PUBLISH_PERIOD=2
# NEW_TIMEOUT=360

# TS="$(date +'%Y%m%d_%H%M%S')"
# RECORD_ID="ADS_${TS}"

# WEATHER_MOCKER="/navigator/sensorslab/resources-runtime/rainman/weather_mocker.py"
# BAG_CHECKER="/navigator/sensorslab/resources-runtime/rainman/bag_checker.py"

# EZLOGDIR="${EZLOGDIR:-/navigator/logs}"
# RECORD_DIR="${EZLOGDIR%/}/record"

# ADS_LOG_DIR="/navigator/logs/ads"
# mkdir -p "$ADS_LOG_DIR"
# LOG_JSON="${ADS_LOG_DIR}/${RECORD_ID}.json"

# echo "[ADS] Record ID = $RECORD_ID"
# echo "[ADS] RECORD_DIR = $RECORD_DIR"

# # ----------------------------
# # HELPERS
# # ----------------------------
# list_bag_objects() {
#   # On your system, bags are directories (*.bag). Also keep support for files (*.bag) and markers (*.bag.dir)
#   find "$RECORD_DIR" -maxdepth 1 \
#     \( -type d -name "*.bag" -o -type f -name "*.bag" -o -type f -name "*.bag.dir" \) \
#     -printf "%y %f\n" 2>/dev/null | sort
# }

# rename_with_id() {
#   local path="$1"
#   local dir base new_base new_path
#   dir="$(dirname "$path")"
#   base="$(basename "$path")"

#   [[ "$base" == "ads_${RECORD_ID}__"* ]] && { echo "$path"; return 0; }

#   new_base="ads_${RECORD_ID}__${base}"
#   new_path="${dir%/}/${new_base}"

#   [[ -e "$new_path" ]] && { echo "$path"; return 0; }

#   mv -- "$path" "$new_path"
#   echo "$new_path"
# }

# # ----------------------------
# # LOCK (avoid double run)
# # ----------------------------
# LOCKFILE="/tmp/ads_record_once.lock"
# exec 9>"$LOCKFILE"
# if command -v flock >/dev/null 2>&1; then
#   flock -n 9 || { echo "[ADS] Already running, exit."; exit 0; }
# fi

# # ----------------------------
# # ACTIVE RECORDING CHECK (correct)
# # ----------------------------
# ACTIVE_RAW="$(rostopic echo -n1 /blackbox/active_record_requests 2>/dev/null || true)"

# # Active if it contains at least one item "- name:"
# if echo "$ACTIVE_RAW" | grep -qE '^\s*-\s*name:'; then
#   echo "[ADS] Active recording detected -> SKIP"
#   STATUS="skipped_active_recording"
#   CHECK_OUT="SKIPPED: active recording detected"
#   WEATHER_RAW_BEGIN="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"
#   WEATHER_RAW_END="$WEATHER_RAW_BEGIN"
#   export STATUS CHECK_OUT WEATHER_RAW_BEGIN WEATHER_RAW_END ACTIVE_RAW
#   export RECORD_ID RECORD_DURATION SENSORS_STARTUP_DELAY EZLOGDIR LOG_JSON
#   python3 <<'PY'
# import os, json, re
# from datetime import datetime, timezone

# def extract_float(pattern, text):
#     m = re.search(pattern, text, re.MULTILINE)
#     return float(m.group(1)) if m else None

# def parse_weather(raw: str):
#     if not raw:
#         return {}
#     return {
#         "visibility_m": extract_float(r"visibility_over_1min:\s*\[(\d+(\.\d+)?)\]", raw),
#         "rain_intensity_mmph": extract_float(r"precipitation_mean_intensity_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "air_temp_c": extract_float(r"air_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "dew_point_c": extract_float(r"dew_point_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_percent": extract_float(r"hygrometry_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_raw_percent": extract_float(r"hygrometry_raw_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_speed_10min_ms": extract_float(r"mean_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_dir_10min_deg": extract_float(r"mean_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#     }

# log = {
#   "record_id": os.environ.get("RECORD_ID"),
#   "timestamp_utc": datetime.now(timezone.utc).isoformat(),
#   "status": os.environ.get("STATUS",""),
#   "record_duration_s": int(os.environ.get("RECORD_DURATION","0")),
#   "sensors_startup_delay_s": int(os.environ.get("SENSORS_STARTUP_DELAY","0")),
#   "record_dir": os.environ.get("EZLOGDIR","/navigator/logs") + "/record",
#   "new_record_object": "",
#   "bag_final": "",
#   "bag_checker_output": os.environ.get("CHECK_OUT",""),
#   "active_record_requests_snippet": (os.environ.get("ACTIVE_RAW","") or "")[:1500],
#   "weather_begin": parse_weather(os.environ.get("WEATHER_RAW_BEGIN","")),
#   "weather_end": parse_weather(os.environ.get("WEATHER_RAW_END","")),
# }

# with open(os.environ["LOG_JSON"], "w") as f:
#   json.dump(log, f, indent=2)

# print("[ADS] Log written to", os.environ["LOG_JSON"])
# PY
#   exit 0
# fi

# # ----------------------------
# # Snapshot BEFORE
# # ----------------------------
# BEFORE="/tmp/${RECORD_ID}_before.txt"
# AFTER="/tmp/${RECORD_ID}_after.txt"
# list_bag_objects > "$BEFORE"

# # Weather snapshot begin (real station)
# WEATHER_RAW_BEGIN="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"

# # ----------------------------
# # Publish weather mock (to trigger recording)
# # ----------------------------
# echo "[ADS] Publishing fake rain for ${WEATHER_PUBLISH_WINDOW}s..."
# END=$(( $(date +%s) + WEATHER_PUBLISH_WINDOW ))
# while (( $(date +%s) < END )); do
#   python3 "$WEATHER_MOCKER" -r -1 >/dev/null 2>&1 || true
#   sleep "$WEATHER_PUBLISH_PERIOD"
# done

# # ----------------------------
# # Wait expected times
# # ----------------------------
# echo "[ADS] Waiting sensors startup (${SENSORS_STARTUP_DELAY}s)..."
# sleep "$SENSORS_STARTUP_DELAY"

# echo "[ADS] Waiting expected recording duration (${RECORD_DURATION}s)..."
# sleep "$RECORD_DURATION"

# echo "[ADS] Waiting flush margin (${SAFETY_MARGIN}s)..."
# sleep "$SAFETY_MARGIN"

# # ----------------------------
# # Detect NEW bag object by diff
# # ----------------------------
# echo "[ADS] Waiting new bag object (timeout ${NEW_TIMEOUT}s)..."
# NEW_OBJ=""
# t0=$(date +%s)
# while true; do
#   list_bag_objects > "$AFTER"
#   CAND="$(python3 - <<'PY' "$BEFORE" "$AFTER"
# import sys
# before=set(x.strip() for x in open(sys.argv[1]) if x.strip())
# after=[x.strip() for x in open(sys.argv[2]) if x.strip()]
# new=[x for x in after if x not in before]
# print(new[-1] if new else "")
# PY
# )"
#   if [[ -n "${CAND:-}" ]]; then
#     NEW_OBJ="${CAND#* }" # drop leading "d " or "f "
#     break
#   fi
#   now=$(date +%s)
#   (( now - t0 > NEW_TIMEOUT )) && break
#   sleep 1
# done

# # Weather snapshot end (real station)
# WEATHER_RAW_END="$(rostopic echo -n1 /weather_data 2>/dev/null || true)"

# STATUS="no_bag_created"
# BAG_FINAL=""
# CHECK_OUT="NO_NEW_OBJECT (cooldown/filtered/timing)"

# if [[ -z "${NEW_OBJ:-}" ]]; then
#   echo "[ADS] No new bag object detected."
# else
#   STATUS="ok"
#   OBJ_PATH="${RECORD_DIR%/}/${NEW_OBJ}"
#   echo "[ADS] New object: $OBJ_PATH"

#   if [[ -e "$OBJ_PATH" ]]; then
#     BAG_FINAL="$(rename_with_id "$OBJ_PATH")"
#     echo "[ADS] Renamed bag object: $BAG_FINAL"
#   fi

#   # Info only (not source of truth)
#   CHECK_OUT="$(python3 "$BAG_CHECKER" -n 1 2>&1 || true)"
# fi

# # Refresh active requests snippet for logs
# ACTIVE_RAW_END="$(rostopic echo -n1 /blackbox/active_record_requests 2>/dev/null || true)"

# export STATUS NEW_OBJ BAG_FINAL CHECK_OUT
# export WEATHER_RAW_BEGIN WEATHER_RAW_END ACTIVE_RAW_END
# export RECORD_ID RECORD_DURATION SENSORS_STARTUP_DELAY EZLOGDIR LOG_JSON

# # ----------------------------
# # JSON (with weather parsed)
# # ----------------------------
# python3 <<'PY'
# import os, json, re
# from datetime import datetime, timezone

# def extract_float(pattern, text):
#     m = re.search(pattern, text, re.MULTILINE)
#     return float(m.group(1)) if m else None

# def parse_weather(raw: str):
#     if not raw:
#         return {}
#     return {
#         "visibility_m": extract_float(r"visibility_over_1min:\s*\[(\d+(\.\d+)?)\]", raw),
#         "rain_intensity_mmph": extract_float(r"precipitation_mean_intensity_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "air_temp_c": extract_float(r"air_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "dew_point_c": extract_float(r"dew_point_temperature_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_percent": extract_float(r"hygrometry_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "humidity_raw_percent": extract_float(r"hygrometry_raw_over_1min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_speed_10min_ms": extract_float(r"mean_speed_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#         "wind_mean_dir_10min_deg": extract_float(r"mean_direction_over_10min:\s*\[(\-?\d+(\.\d+)?)\]", raw),
#     }

# log = {
#   "record_id": os.environ.get("RECORD_ID"),
#   "timestamp_utc": datetime.now(timezone.utc).isoformat(),
#   "status": os.environ.get("STATUS",""),
#   "record_duration_s": int(os.environ.get("RECORD_DURATION","0")),
#   "sensors_startup_delay_s": int(os.environ.get("SENSORS_STARTUP_DELAY","0")),
#   "record_dir": os.environ.get("EZLOGDIR","/navigator/logs") + "/record",

#   "new_record_object": os.environ.get("NEW_OBJ",""),
#   "bag_final": os.environ.get("BAG_FINAL",""),

#   "bag_checker_output": os.environ.get("CHECK_OUT",""),
#   "active_record_requests_snippet": (os.environ.get("ACTIVE_RAW_END","") or "")[:1500],

#   "weather_begin": parse_weather(os.environ.get("WEATHER_RAW_BEGIN","")),
#   "weather_end": parse_weather(os.environ.get("WEATHER_RAW_END","")),
# }

# with open(os.environ["LOG_JSON"], "w") as f:
#   json.dump(log, f, indent=2)

# print("[ADS] Log written to", os.environ["LOG_JSON"])
# PY

# echo "[ADS] Done."














#MARCHE BIEN
# #!/usr/bin/env bash
# set -euo pipefail

# # ----------------------------
# # CONFIG
# # ----------------------------
# RECORD_DURATION=120
# SENSORS_STARTUP_DELAY=15
# SAFETY_MARGIN=10

# WEATHER_PUBLISH_WINDOW=30
# WEATHER_PUBLISH_PERIOD=2
# NEW_TIMEOUT=360   # 6 min (robuste sans être trop long)

# TS="$(date +'%Y%m%d_%H%M%S')"
# RECORD_ID="ADS_${TS}"

# WEATHER_MOCKER="/navigator/sensorslab/resources-runtime/rainman/weather_mocker.py"
# BAG_CHECKER="/navigator/sensorslab/resources-runtime/rainman/bag_checker.py"

# EZLOGDIR="${EZLOGDIR:-/navigator/logs}"
# RECORD_DIR="${EZLOGDIR%/}/record"

# ADS_LOG_DIR="/navigator/logs/ads"
# mkdir -p "$ADS_LOG_DIR"
# LOG_JSON="${ADS_LOG_DIR}/${RECORD_ID}.json"

# echo "[ADS] Record ID = $RECORD_ID"
# echo "[ADS] RECORD_DIR = $RECORD_DIR"

# # ----------------------------
# # Helpers
# # ----------------------------
# list_bag_objects() {
#   # bag can be a directory (*.bag) on your system
#   # include: directories *.bag + files *.bag + files *.bag.dir
#   find "$RECORD_DIR" -maxdepth 1 \
#     \( -type d -name "*.bag" -o -type f -name "*.bag" -o -type f -name "*.bag.dir" \) \
#     -printf "%y %f\n" 2>/dev/null | sort
# }

# rename_with_id() {
#   local path="$1"
#   local dir base new_base new_path
#   dir="$(dirname "$path")"
#   base="$(basename "$path")"
#   [[ "$base" == "ads_${RECORD_ID}__"* ]] && { echo "$path"; return 0; }
#   new_base="ads_${RECORD_ID}__${base}"
#   new_path="${dir%/}/${new_base}"
#   [[ -e "$new_path" ]] && { echo "$path"; return 0; }
#   mv -- "$path" "$new_path"
#   echo "$new_path"
# }

# write_json() {
#   local status="$1" new_obj="$2" bag_final="$3" pcap_final="$4" meta_final="$5" check_out="$6" active_raw="$7"
#   RECORD_ID="$RECORD_ID" STATUS="$status" NEW_OBJ="$new_obj" BAG_FINAL="$bag_final" \
#   PCAP_FINAL="$pcap_final" META_FINAL="$meta_final" CHECK_OUT="$check_out" ACTIVE_RAW="$active_raw" \
#   LOG_JSON="$LOG_JSON" EZLOGDIR="$EZLOGDIR" RECORD_DURATION="$RECORD_DURATION" SENSORS_STARTUP_DELAY="$SENSORS_STARTUP_DELAY" \
#   python3 <<'PY'
# import os, json
# from datetime import datetime, timezone
# log = {
#   "record_id": os.environ.get("RECORD_ID"),
#   "timestamp_utc": datetime.now(timezone.utc).isoformat(),
#   "status": os.environ.get("STATUS",""),
#   "record_duration_s": int(os.environ.get("RECORD_DURATION","0")),
#   "sensors_startup_delay_s": int(os.environ.get("SENSORS_STARTUP_DELAY","0")),
#   "record_dir": os.environ.get("EZLOGDIR","/navigator/logs") + "/record",
#   "new_record_object": os.environ.get("NEW_OBJ",""),
#   "bag_final": os.environ.get("BAG_FINAL",""),
#   "pcap_final": os.environ.get("PCAP_FINAL",""),
#   "metadata_final": os.environ.get("META_FINAL",""),
#   "bag_checker_output": os.environ.get("CHECK_OUT",""),
#   "active_record_requests_snippet": (os.environ.get("ACTIVE_RAW","") or "")[:1500],
# }
# with open(os.environ["LOG_JSON"], "w") as f:
#   json.dump(log, f, indent=2)
# print("[ADS] Log written to", os.environ["LOG_JSON"])
# PY
# }

# # ----------------------------
# # Correct active recording detection
# # ----------------------------
# ACTIVE_RAW="$(rostopic echo -n1 /blackbox/active_record_requests 2>/dev/null || true)"

# # Active if it contains a list item "- name:"
# if echo "$ACTIVE_RAW" | grep -qE '^\s*-\s*name:'; then
#   echo "[ADS] Active recording detected -> SKIP"
#   write_json "skipped_active_recording" "" "" "" "" "SKIPPED: active recording detected" "$ACTIVE_RAW"
#   exit 0
# fi

# # ----------------------------
# # BEFORE snapshot
# # ----------------------------
# BEFORE="/tmp/${RECORD_ID}_before.txt"
# AFTER="/tmp/${RECORD_ID}_after.txt"
# list_bag_objects > "$BEFORE"

# # ----------------------------
# # Publish weather
# # ----------------------------
# echo "[ADS] Publishing fake rain for ${WEATHER_PUBLISH_WINDOW}s..."
# END=$(( $(date +%s) + WEATHER_PUBLISH_WINDOW ))
# while (( $(date +%s) < END )); do
#   python3 "$WEATHER_MOCKER" -r -1 >/dev/null 2>&1 || true
#   sleep "$WEATHER_PUBLISH_PERIOD"
# done

# # ----------------------------
# # Wait
# # ----------------------------
# sleep "$SENSORS_STARTUP_DELAY"
# sleep "$RECORD_DURATION"
# sleep "$SAFETY_MARGIN"

# # ----------------------------
# # Find NEW bag object by diff
# # ----------------------------
# echo "[ADS] Waiting new bag object (timeout ${NEW_TIMEOUT}s)..."
# NEW_OBJ=""
# t0=$(date +%s)
# while true; do
#   list_bag_objects > "$AFTER"
#   CAND="$(python3 - <<'PY' "$BEFORE" "$AFTER"
# import sys
# before=set(x.strip() for x in open(sys.argv[1]) if x.strip())
# after=[x.strip() for x in open(sys.argv[2]) if x.strip()]
# new=[x for x in after if x not in before]
# print(new[-1] if new else "")
# PY
# )"
#   if [[ -n "${CAND:-}" ]]; then
#     NEW_OBJ="${CAND#* }"   # remove leading "d " or "f "
#     break
#   fi
#   now=$(date +%s)
#   (( now - t0 > NEW_TIMEOUT )) && break
#   sleep 1
# done

# if [[ -z "${NEW_OBJ:-}" ]]; then
#   echo "[ADS] No new bag object detected."
#   write_json "no_bag_created" "" "" "" "" "NO_NEW_OBJECT (cooldown/filtered/timing)" "$ACTIVE_RAW"
#   exit 0
# fi

# OBJ_PATH="${RECORD_DIR%/}/${NEW_OBJ}"
# echo "[ADS] New object: $OBJ_PATH"

# # ----------------------------
# # Rename: directory .bag + sibling files
# # ----------------------------
# BAG_FINAL=""
# PCAP_FINAL=""
# META_FINAL=""

# # If the object is a directory ending with .bag (your case)
# if [[ -d "$OBJ_PATH" && "$OBJ_PATH" == *.bag ]]; then
#   BAG_FINAL="$(rename_with_id "$OBJ_PATH")"
#   base_noext="${OBJ_PATH%.bag}"
# # If it is a file .bag
# elif [[ -f "$OBJ_PATH" && "$OBJ_PATH" == *.bag ]]; then
#   BAG_FINAL="$(rename_with_id "$OBJ_PATH")"
#   base_noext="${OBJ_PATH%.bag}"
# # If it is .bag.dir marker
# elif [[ -f "$OBJ_PATH" && "$OBJ_PATH" == *.bag.dir ]]; then
#   base_noext="${OBJ_PATH%.bag.dir}"
#   [[ -d "${base_noext}.bag" ]] && BAG_FINAL="$(rename_with_id "${base_noext}.bag")"
#   [[ -f "${base_noext}.bag" ]] && BAG_FINAL="$(rename_with_id "${base_noext}.bag")"
# else
#   base_noext="${OBJ_PATH%.*}"
# fi

# [[ -f "${base_noext}.pcap" ]] && PCAP_FINAL="$(rename_with_id "${base_noext}.pcap")"
# [[ -f "${base_noext}.metadata" ]] && META_FINAL="$(rename_with_id "${base_noext}.metadata")"

# CHECK_OUT="$(python3 "$BAG_CHECKER" -n 1 2>&1 || true)"

# echo "[ADS] Renamed bag object: $BAG_FINAL"
# [[ -n "$PCAP_FINAL" ]] && echo "[ADS] Renamed pcap: $PCAP_FINAL"
# [[ -n "$META_FINAL" ]] && echo "[ADS] Renamed metadata: $META_FINAL"

# write_json "ok" "$NEW_OBJ" "$BAG_FINAL" "$PCAP_FINAL" "$META_FINAL" "$CHECK_OUT" "$ACTIVE_RAW"
# echo "[ADS] Done."
















# # Enregistrement qu'avec weather_mocker donc que capteurs

# #!/usr/bin/env bash
# set -euo pipefail

# # CONFIGURATION
# export RECORD_DURATION=120          # durée d'enregistrement en secondes
# export SENSORS_STARTUP_DELAY=15    # attente avant que les capteurs soient prêts
# export SAFETY_MARGIN=5             # attente supplémentaire pour flush bag
# TS="$(date +'%Y%m%d_%H%M%S')"
# export RECORD_ID="ADS_${TS}"

# WEATHER_MOCKER="/navigator/sensorslab/resources-runtime/rainman/weather_mocker.py"
# BAG_CHECKER="/navigator/sensorslab/resources-runtime/rainman/bag_checker.py"
# ADS_LOG_DIR="/navigator/logs/ads"
# mkdir -p "$ADS_LOG_DIR"
# export LOG_JSON="${ADS_LOG_DIR}/${RECORD_ID}.json"

# echo "[ADS] Record ID = $RECORD_ID"

# # 1) START WEATHER MOCKER (simulate rain, only sensors)
# echo "[ADS] Starting fake rain simulation..."
# python3 "$WEATHER_MOCKER" -r -1 &
# WEATHER_PID=$!

# # 2) WAIT FOR SENSORS TO START
# echo "[ADS] Waiting sensors startup (${SENSORS_STARTUP_DELAY}s)..."
# sleep "$SENSORS_STARTUP_DELAY"

# # 3) RECORD DURATION
# echo "[ADS] Recording sensors for ${RECORD_DURATION}s..."
# sleep "$RECORD_DURATION"

# # 4) STOP WEATHER MOCKER
# echo "[ADS] Stopping fake rain..."
# kill "$WEATHER_PID" || true

# # 5) SAFETY WAIT (bag flush)
# sleep "$SAFETY_MARGIN"

# # 6) BAG CHECKER
# CHECK_OUT="$(python3 "$BAG_CHECKER" -n 1 2>&1 || true)"
# export CHECK_OUT

# # 7) LOG JSON
# python3 <<'PY'
# import json, datetime, os

# log = {
#     "record_id": os.environ.get("RECORD_ID"),
#     "timestamp": datetime.datetime.now().isoformat(),
#     "record_duration_s": int(os.environ.get("RECORD_DURATION")),
#     "sensors_startup_delay_s": int(os.environ.get("SENSORS_STARTUP_DELAY")),
#     "bag_checker_last_1": os.environ.get("CHECK_OUT", "")
# }

# with open(os.environ.get("LOG_JSON"), "w") as f:
#     json.dump(log, f, indent=2)

# print("[ADS] Log written to", os.environ.get("LOG_JSON"))
# PY

# echo "[ADS] Done."










#enregistrement avec weather + trigger donc capteurs+systeme

# #!/usr/bin/env bash
# set -euo pipefail

# # CONFIG
# export RECORD_DURATION=120
# export SENSORS_STARTUP_DELAY=15
# export SAFETY_MARGIN=5
# export TS="$(date +'%Y%m%d_%H%M%S')"
# export RECORD_ID="ADS_${TS}"

# TRIGGER_CLI="/navigator/sensorslab/resources-runtime/rainman/trigger_manager.py"
# WEATHER_MOCKER="/navigator/sensorslab/resources-runtime/rainman/weather_mocker.py"
# BAG_CHECKER="/navigator/sensorslab/resources-runtime/rainman/bag_checker.py"

# ADS_LOG_DIR="/navigator/logs/ads"
# mkdir -p "$ADS_LOG_DIR"
# export LOG_JSON="${ADS_LOG_DIR}/${RECORD_ID}.json"

# echo "[ADS] Record ID = $RECORD_ID"

# # 1) START WEATHER
# echo "[ADS] Starting fake rain..."
# python3 "$WEATHER_MOCKER" -r -1 &
# WEATHER_PID=$!

# # 2) Wait sensors startup
# echo "[ADS] Waiting sensors startup (${SENSORS_STARTUP_DELAY}s)..."
# sleep "$SENSORS_STARTUP_DELAY"

# # 3) START RECORD
# echo "[ADS] Starting record..."
# python3 "$TRIGGER_CLI" start -i "$RECORD_ID"

# # 4) Wait record duration
# echo "[ADS] Simulating rain during ${RECORD_DURATION}s..."
# sleep "$RECORD_DURATION"

# # 5) STOP RECORD
# echo "[ADS] Stopping record..."
# python3 "$TRIGGER_CLI" stop -i "$RECORD_ID"

# # 6) WAIT REAL END (blackbox)
# echo "[ADS] Waiting for recording to finish..."
# while rostopic echo -n1 /blackbox/active_record_requests | grep -q "$RECORD_ID"; do
#     echo "[ADS] Still recording..."
#     sleep 1
# done
# echo "[ADS] Recording finished."

# # 7) Stop weather mocker
# echo "[ADS] Stopping fake rain..."
# kill "$WEATHER_PID" || true

# # 8) Safety wait (bag flush)
# sleep "$SAFETY_MARGIN"

# # 9) BAG CHECKER
# CHECK_OUT="$(python3 "$BAG_CHECKER" -n 1 2>&1 || true)"

# # 10) LOG JSON
# python3 <<'PY'
# import json, datetime, os

# log = {
#     "record_id": os.environ.get("RECORD_ID"),
#     "timestamp": datetime.datetime.now().isoformat(),
#     "record_duration_s": int(os.environ.get("RECORD_DURATION")),
#     "sensors_startup_delay_s": int(os.environ.get("SENSORS_STARTUP_DELAY")),
#     "bag_checker_last_1": os.environ.get("CHECK_OUT", "")
# }

# with open(os.environ.get("LOG_JSON"), "w") as f:
#     json.dump(log, f, indent=2)

# print("[ADS] Log written to", os.environ.get("LOG_JSON"))
# PY

# echo "[ADS] Done."












# La base, enregistrement avec trigger donc tout le systeme

# #!/usr/bin/env bash
# set -euo pipefail

# # Variables pour Python
# export RECORD_DURATION=120
# export SENSORS_STARTUP_DELAY=15
# export SAFETY_MARGIN=10
# export RECORD_ID="ADS_$(date +'%Y%m%d_%H%M%S')"
# export CHECK_OUT="test output"
# export LOG_JSON="/navigator/logs/ads/${RECORD_ID}.json"

# TRIGGER_CLI="/navigator/sensorslab/resources-runtime/rainman/trigger_manager.py"
# BAG_CHECKER="/navigator/sensorslab/resources-runtime/rainman/bag_checker.py"

# ADS_LOG_DIR="/navigator/logs/ads"
# mkdir -p "$ADS_LOG_DIR"

# TS="$(date +'%Y%m%d_%H%M%S')"
# RECORD_ID="ADS_${TS}"
# LOG_JSON="${ADS_LOG_DIR}/${RECORD_ID}.json"

# echo "[ADS] Starting record id=${RECORD_ID}"

# # 1) START record (Rainman applique record_profile=acquisition + exclude=default + durée 120s etc.)
# python3 "$TRIGGER_CLI" start -i "$RECORD_ID"

# # 2) Attendre : startup + record + marge
# sleep $((SENSORS_STARTUP_DELAY + RECORD_DURATION + SAFETY_MARGIN))

# # 3) STOP record (sécurité)
# python3 "$TRIGGER_CLI" stop -i "$RECORD_ID"

# # 4) Vérif du dernier bag
# CHECK_OUT="$(python3 "$BAG_CHECKER" -n 1 2>&1 || true)"

# # 5) Log JSON
# python3 <<'PY'
# import json, datetime, os

# RECORD_ID = os.environ.get("RECORD_ID")
# CHECK_OUT = os.environ.get("CHECK_OUT")
# LOG_JSON = os.environ.get("LOG_JSON")
# RECORD_DURATION = int(os.environ.get("RECORD_DURATION"))
# SENSORS_STARTUP_DELAY = int(os.environ.get("SENSORS_STARTUP_DELAY"))

# log = {
#     "record_id": RECORD_ID,
#     "timestamp": datetime.datetime.now().isoformat(),
#     "recording_duration_s": RECORD_DURATION,
#     "sensors_startup_delay_s": SENSORS_STARTUP_DELAY,
#     "bag_checker_last_1": CHECK_OUT
# }

# with open(LOG_JSON, "w") as f:
#     json.dump(log, f, indent=2)

# print("[ADS] Wrote log:", LOG_JSON)
# PY


# echo "[ADS] Done."

