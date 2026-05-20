#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="${RUN_ID:-$(date '+%Y%m%d_%H%M%S')}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-"${SCRIPT_DIR}/captures"}"
PHASE_LOG="${PHASE_LOG:-"${DOWNLOAD_DIR}/${RUN_ID}_phase-log.tsv"}"

C2_TIME="${C2_TIME:-}"
C3_TIME="${C3_TIME:-}"
C2_PRE_LEAD_SECONDS="${C2_PRE_LEAD_SECONDS:-3}"
C3_POST_DELAY_SECONDS="${C3_POST_DELAY_SECONDS:-3}"
WAIT_LOG_INTERVAL_SECONDS="${WAIT_LOG_INTERVAL_SECONDS:-10}"

CAPTURE_TARGET_CONFIG="${CAPTURE_TARGET_CONFIG:-/main/settings/capturetarget}"
CAPTURE_MODE_CONFIG="${CAPTURE_MODE_CONFIG:-/main/capturesettings/capturemode}"
SHUTTER_CONFIG="${SHUTTER_CONFIG:-/main/capturesettings/shutterspeed}"
CAPTURE_ACTION_CONFIG="${CAPTURE_ACTION_CONFIG:-/main/actions/capture}"
ISO="${ISO:-100}"

PRE_SHUTTER="${PRE_SHUTTER:-1/4000}"
PRE_FRAME_COUNT="${PRE_FRAME_COUNT:-${PRE_SHOTS:-6}}"
TOTALITY_SHUTTERS="${TOTALITY_SHUTTERS:-1/2000 1/1000 1/500 1/250 1/125 1/60 1/30 1/15 1/8 1/4}"
TOTALITY_FRAMES_PER_SHUTTER="${TOTALITY_FRAMES_PER_SHUTTER:-${TOTALITY_SHOTS_PER_SHUTTER:-3}}"
POST_SHUTTER="${POST_SHUTTER:-1/200}"

# Default exposure timing at SHOT_INTERVAL=1:
# Pre: 6 frames, about 6s. With C2_TIME set, the first Pre frame is at C2 - 3s.
# Totality: 10 shutter speeds * 3 frames, about 30s plus shutter confirmation time.
# Post: 1 frame/s until Ctrl-C or C3_TIME + 3s.
# Nominal elapsed before the first download is Pre +00:00:06 plus Totality +00:00:30.
SHOT_INTERVAL="${SHOT_INTERVAL:-1}"
SHUTTER_PRESS_SECONDS="${SHUTTER_PRESS_SECONDS:-0.2}"
# ILCE-7RM3A SDRAM holds 36 RAW frames. A RAW download is measured at about 2.2s/frame.
# For a 1m20s totality, POST_START_AFTER_DOWNLOAD_FRAMES should be 6;
# for a 1m30s totality, POST_START_AFTER_DOWNLOAD_FRAMES should be 10;
# for a 1m40s totality, POST_START_AFTER_DOWNLOAD_FRAMES should be 14.
POST_START_AFTER_DOWNLOAD_FRAMES="${POST_START_AFTER_DOWNLOAD_FRAMES:-${POST_START_AFTER_DOWNLOADS:-6}}"
DOWNLOAD_WAIT_MILLISECONDS="${DOWNLOAD_WAIT_MILLISECONDS:-${DOWNLOAD_WAIT_MS:-10000}}"
DOWNLOAD_IDLE_CHUNK_LIMIT="${DOWNLOAD_IDLE_CHUNK_LIMIT:-${DOWNLOAD_IDLE_CHUNKS:-2}}"
SHOW_GPHOTO2_DOWNLOAD_OUTPUT="${SHOW_GPHOTO2_DOWNLOAD_OUTPUT:-0}"
SHOW_UNKNOWN_PTP_EVENTS="${SHOW_UNKNOWN_PTP_EVENTS:-0}"
SHOW_DOWNLOAD_PROGRESS="${SHOW_DOWNLOAD_PROGRESS:-0}"

RECOVER_ONLY="${RECOVER_ONLY:-0}"
DOWNLOAD_ON_EXIT="${DOWNLOAD_ON_EXIT:-1}"
VERIFY_SHUTTER="${VERIFY_SHUTTER:-1}"
STRICT_SHUTTER="${STRICT_SHUTTER:-1}"
SHUTTER_VERIFY_ATTEMPTS="${SHUTTER_VERIFY_ATTEMPTS:-10}"
SHUTTER_VERIFY_SLEEP="${SHUTTER_VERIFY_SLEEP:-0.5}"
RENAME_BY_EXPOSURE="${RENAME_BY_EXPOSURE:-1}"
# Fixed camera-side SDRAM capacity, not an estimate.
SDRAM_FRAME_CAPACITY="${SDRAM_FRAME_CAPACITY:-36}"

phase_index=0
captured_any=0
pending_download=0
safe_exit_requested=0
current_file_prefix="${RUN_ID}_capture"
download_chunk_before=0
download_chunk_after=0
c2_epoch=""
c3_epoch=""
pre_first_shot_epoch=""
post_stop_epoch=""

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

now_seconds() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.3f\n", time'
  else
    date '+%s'
  fi
}

add_seconds() {
  awk -v left="$1" -v right="$2" 'BEGIN { printf "%.3f", left + right }'
}

subtract_seconds() {
  awk -v left="$1" -v right="$2" 'BEGIN { printf "%.3f", left - right }'
}

floor_seconds() {
  awk -v value="$1" 'BEGIN { printf "%d", value }'
}

time_ge() {
  awk -v left="$1" -v right="$2" 'BEGIN { exit(left >= right ? 0 : 1) }'
}

time_gt() {
  awk -v left="$1" -v right="$2" 'BEGIN { exit(left > right ? 0 : 1) }'
}

format_epoch() {
  local epoch="$1"

  date -r "${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
    date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null ||
    printf '%s' "${epoch}"
}

parse_schedule_time() {
  local variable_name="$1"
  local value="$2"
  local normalized
  local epoch

  normalized="${value/T/ }"
  if [[ "${normalized}" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    normalized="$(date '+%Y-%m-%d') ${normalized}"
  fi

  if epoch="$(date -j -f '%Y-%m-%d %H:%M:%S' "${normalized}" '+%s' 2>/dev/null)"; then
    printf '%s' "${epoch}"
    return 0
  fi

  if epoch="$(date -d "${normalized}" '+%s' 2>/dev/null)"; then
    printf '%s' "${epoch}"
    return 0
  fi

  echo "[ERROR] Cannot parse ${variable_name}: ${value}. Use 'YYYY-MM-DD HH:MM:SS' or 'HH:MM:SS'." >&2
  exit 1
}

sleep_until() {
  local target="$1"
  local now
  local delay

  now="$(now_seconds)"
  delay="$(awk -v target="${target}" -v now="${now}" 'BEGIN {
    delay = target - now
    if (delay > 0) printf "%.3f", delay
    else printf "0"
  }')"

  if awk -v delay="${delay}" 'BEGIN { exit(delay > 0 ? 0 : 1) }'; then
    sleep "${delay}"
  fi
}

wait_until_epoch() {
  local target_epoch="$1"
  local label="$2"
  local now
  local delay
  local remaining
  local late_by
  local sleep_seconds

  while true; do
    now="$(now_seconds)"
    delay="$(awk -v target="${target_epoch}" -v now="${now}" 'BEGIN {
      delay = target - now
      if (delay > 0) printf "%.3f", delay
      else printf "0"
    }')"

    if ! awk -v delay="${delay}" 'BEGIN { exit(delay > 0 ? 0 : 1) }'; then
      late_by="$(awk -v target="${target_epoch}" -v now="${now}" 'BEGIN {
        late = int(now - target)
        if (late < 0) late = 0
        print late
      }')"
      if (( late_by > 0 )); then
        echo "[WARN] ${label} target passed ${late_by}s ago; starting immediately." >&2
      fi
      return 0
    fi

    remaining="$(awk -v delay="${delay}" 'BEGIN {
      remaining = int(delay)
      if (delay > remaining) remaining += 1
      print remaining
    }')"
    echo "[INFO] waiting for ${label}: ${remaining}s remaining, target $(format_epoch "${target_epoch}")"
    if awk -v delay="${delay}" -v interval="${WAIT_LOG_INTERVAL_SECONDS}" 'BEGIN { exit(delay < interval ? 0 : 1) }'; then
      sleep_seconds="${delay}"
    else
      sleep_seconds="${WAIT_LOG_INTERVAL_SECONDS}"
    fi
    sleep "${sleep_seconds}"
  done
}

word_count() {
  wc -w <<<"$1" | tr -d ' '
}

release_capture() {
  gphoto2 --set-config "${CAPTURE_ACTION_CONFIG}=0" >/dev/null 2>&1 || true
}

shutter_seconds() {
  local value="$1"

  awk -v value="${value}" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    BEGIN {
      value = trim(value)
      if (value == "Bulb" || value == "" || value == "unknown" || value == "unchecked") {
        print "nan"
        exit
      }
      if (index(value, "/")) {
        split(value, parts, "/")
        if (parts[2] == 0) {
          print "nan"
          exit
        }
        printf "%.10f\n", parts[1] / parts[2]
        exit
      }
      printf "%.10f\n", value + 0
    }
  '
}

shutters_equal() {
  local requested
  local current

  requested="$(shutter_seconds "$1")"
  current="$(shutter_seconds "$2")"

  awk -v requested="${requested}" -v current="${current}" 'BEGIN {
    if (requested == "nan" || current == "nan") exit 1
    diff = requested - current
    if (diff < 0) diff = -diff
    exit(diff <= 0.000001 ? 0 : 1)
  }'
}

get_config_current() {
  local config_path="$1"

  LANG=C gphoto2 --get-config "${config_path}" 2>/dev/null |
    awk -F': ' '/^Current:/ { print $2; exit }'
}

find_config_choice_index() {
  local config="$1"
  shift
  local label
  local target_index

  for label in "$@"; do
    target_index="$(
      awk -v label="${label}" '
        /^Choice:[[:space:]]+[0-9]+[[:space:]]+/ {
          idx = $2
          value = $0
          sub(/^Choice:[[:space:]]+[0-9]+[[:space:]]+/, "", value)
          if (tolower(value) == tolower(label)) {
            print idx
            exit
          }
        }
      ' <<<"${config}"
    )"

    if [[ -n "${target_index}" ]]; then
      printf '%s\t%s\n' "${target_index}" "${label}"
      return 0
    fi
  done

  return 1
}

set_config_choice_by_label() {
  local config_path="$1"
  shift
  local config
  local current
  local target_index
  local target_label
  local target_match

  if ! config="$(LANG=C gphoto2 --get-config "${config_path}" 2>/dev/null)"; then
    echo "[ERROR] Cannot read ${config_path}." >&2
    exit 1
  fi

  if ! target_match="$(find_config_choice_index "${config}" "$@")"; then
    echo "[ERROR] Cannot find requested value for ${config_path}. Available choices:" >&2
    awk '/^(Current|Choice):/ { print "  " $0 }' <<<"${config}" >&2
    exit 1
  fi

  target_index="${target_match%%$'\t'*}"
  target_label="${target_match#*$'\t'}"

  if ! gphoto2 --set-config-index "${config_path}=${target_index}" >/dev/null 2>&1; then
    echo "[ERROR] Cannot set ${config_path} to ${target_label}." >&2
    exit 1
  fi
  sleep 0.5
  current="$(get_config_current "${config_path}" || true)"
  echo "[INFO] ${config_path}: ${target_label}; current: ${current:-unknown}"
}

set_computer_only_capture_target() {
  local config
  local target_index

  if ! config="$(LANG=C gphoto2 --get-config "${CAPTURE_TARGET_CONFIG}" 2>/dev/null)"; then
    echo "[ERROR] Cannot read ${CAPTURE_TARGET_CONFIG}; this camera may not expose a capture target setting." >&2
    exit 1
  fi

  target_index="$(
    awk '/^Choice:[[:space:]]+[0-9]+[[:space:]]+(Internal RAM|sdram)$/ { print $2; exit }' <<<"${config}"
  )"

  if [[ -z "${target_index}" ]]; then
    echo "[ERROR] No computer-only capture target found. Available capture targets:" >&2
    awk '/^(Current|Choice):/ { print "  " $0 }' <<<"${config}" >&2
    echo "[ERROR] This script expects ILCE-7RM3A SDRAM/computer-only capture." >&2
    exit 1
  fi

  if ! gphoto2 --set-config-index "${CAPTURE_TARGET_CONFIG}=${target_index}" >/dev/null 2>&1; then
    echo "[ERROR] Cannot set ${CAPTURE_TARGET_CONFIG} to computer-only capture." >&2
    exit 1
  fi
}

set_single_shot_capture_mode() {
  set_config_choice_by_label "${CAPTURE_MODE_CONFIG}" \
    "Single Shot" \
    "Single frame" \
    "Single"
}

set_and_confirm_shutterspeed() {
  local requested="$1"
  local current=""
  local attempt

  if [[ "${VERIFY_SHUTTER}" == "0" ]]; then
    if ! gphoto2 --set-config "${SHUTTER_CONFIG}=${requested}" >/dev/null 2>&1; then
      echo "[ERROR] Cannot set shutter speed to ${requested} s." >&2
      exit 1
    fi
    printf '%s' "unchecked"
    return 0
  fi

  for ((attempt = 1; attempt <= SHUTTER_VERIFY_ATTEMPTS; attempt++)); do
    if ! gphoto2 --set-config "${SHUTTER_CONFIG}=${requested}" >/dev/null 2>&1; then
      echo "[WARN] shutter speed set ${attempt}/${SHUTTER_VERIFY_ATTEMPTS} failed for ${requested} s." >&2
    fi

    sleep "${SHUTTER_VERIFY_SLEEP}"
    current="$(get_config_current "${SHUTTER_CONFIG}" || true)"
    if [[ "${current}" == "${requested}" ]] || shutters_equal "${requested}" "${current}"; then
      echo "[INFO] shutter speed confirmed: ${current} s (requested ${requested} s)" >&2
      printf '%s' "${current}"
      return 0
    fi

    echo "[WARN] shutter speed readback ${attempt}/${SHUTTER_VERIFY_ATTEMPTS}: requested ${requested} s, current ${current:-unknown} s" >&2
    sleep "${SHUTTER_VERIFY_SLEEP}"
  done

  if [[ "${STRICT_SHUTTER}" != "0" ]]; then
    echo "[ERROR] shutter speed did not settle to ${requested} s; refusing to continue." >&2
    exit 1
  fi

  printf '%s' "${current:-unknown}"
}

downloaded_file_count() {
  local file_prefix="$1"

  find "${DOWNLOAD_DIR}" -maxdepth 1 -type f -name "${file_prefix}_*" | wc -l | tr -d ' '
}

exposure_name_from_value() {
  local exposure="$1"

  awk -v exposure="${exposure}" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    BEGIN {
      exposure = trim(exposure)
      if (exposure ~ /^1\/[0-9.]+$/) {
        split(exposure, parts, "/")
        gsub(/\..*$/, "", parts[2])
        print parts[2]
        exit
      }
      gsub(/\./, "_", exposure)
      gsub(/[^[:alnum:]_]/, "", exposure)
      print exposure
    }
  '
}

next_exposure_filename() {
  local exposure_name="$1"
  local extension="$2"
  local index=1
  local candidate

  while true; do
    candidate="${DOWNLOAD_DIR}/${exposure_name}.${index}.${extension}"
    if [[ ! -e "${candidate}" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
    index=$((index + 1))
  done
}

rename_downloaded_captures_by_exposure() {
  local file_prefix="$1"
  local file
  local exposure
  local exposure_name
  local extension
  local target

  if [[ "${RENAME_BY_EXPOSURE}" == "0" ]]; then
    return 0
  fi

  if ! command -v exiftool >/dev/null 2>&1; then
    echo "[WARN] exiftool not found; keeping downloaded filenames." >&2
    return 0
  fi

  find "${DOWNLOAD_DIR}" -maxdepth 1 -type f -name "${file_prefix}_*.*" | LC_ALL=C sort |
    while IFS= read -r file; do
      exposure="$(exiftool -s3 -ExposureTime "${file}" 2>/dev/null || true)"
      if [[ -z "${exposure}" ]]; then
        echo "[WARN] cannot read ExposureTime from ${file}; keeping filename." >&2
        continue
      fi

      exposure_name="$(exposure_name_from_value "${exposure}")"
      extension="${file##*.}"
      target="$(next_exposure_filename "${exposure_name}" "${extension}")"
      mv "${file}" "${target}"
    done
}

download_event_chunk() {
  local file_prefix="$1"
  local wait_ms="$2"
  local before
  local after
  local next_number
  local gphoto_status
  local restore_errexit=0

  before="$(downloaded_file_count "${file_prefix}")"
  next_number=$((before + 1))

  if [[ $- == *e* ]]; then
    restore_errexit=1
  fi

  set +e
  if [[ "${SHOW_GPHOTO2_DOWNLOAD_OUTPUT}" == "0" ]]; then
    gphoto2 \
      --no-keep \
      --filenumber "${next_number}" \
      --filename "${DOWNLOAD_DIR}/${file_prefix}_%04n.%C" \
      --wait-event-and-download="${wait_ms}ms" >/dev/null 2>&1
    gphoto_status=$?
  elif [[ "${SHOW_UNKNOWN_PTP_EVENTS}" != "0" ]]; then
    gphoto2 \
      --no-keep \
      --filenumber "${next_number}" \
      --filename "${DOWNLOAD_DIR}/${file_prefix}_%04n.%C" \
      --wait-event-and-download="${wait_ms}ms"
    gphoto_status=$?
  else
    gphoto2 \
      --no-keep \
      --filenumber "${next_number}" \
      --filename "${DOWNLOAD_DIR}/${file_prefix}_%04n.%C" \
      --wait-event-and-download="${wait_ms}ms" 2>&1 |
      awk '
        /^UNKNOWN PTP / { next }
        { print; fflush() }
      '
    gphoto_status=${PIPESTATUS[0]}
  fi
  if (( restore_errexit == 1 )); then
    set -e
  fi

  if (( gphoto_status != 0 )); then
    echo "[ERROR] gphoto2 download event failed with exit status ${gphoto_status}." >&2
    return "${gphoto_status}"
  fi

  after="$(downloaded_file_count "${file_prefix}")"
  download_chunk_before="${before}"
  download_chunk_after="${after}"
}

download_until_count() {
  local target_count="$1"
  local file_prefix="${2:-${current_file_prefix}}"
  local idle_chunks=0
  local before
  local after
  local start_time
  local end_time
  local elapsed

  if (( target_count <= 0 )); then
    return 0
  fi

  # This is the measured gap between Totality and Post. It should be planned
  # as roughly target_count * 2.2s for RAW files on this camera.
  start_time="$(now_seconds)"
  echo "[INFO] partial download begin, target ${target_count} frame(s): $(timestamp)"

  while (( "$(downloaded_file_count "${file_prefix}")" < target_count )) && (( idle_chunks < DOWNLOAD_IDLE_CHUNK_LIMIT )); do
    download_event_chunk "${file_prefix}" "${DOWNLOAD_WAIT_MILLISECONDS}"
    before="${download_chunk_before}"
    after="${download_chunk_after}"

    if (( after > before )); then
      if [[ "${SHOW_DOWNLOAD_PROGRESS}" != "0" ]]; then
        echo "[INFO] downloaded $((after - before)) frame(s), total ${after}"
      fi
      idle_chunks=0
    else
      idle_chunks=$((idle_chunks + 1))
      if [[ "${SHOW_DOWNLOAD_PROGRESS}" != "0" ]]; then
        echo "[INFO] partial download idle ${idle_chunks}/${DOWNLOAD_IDLE_CHUNK_LIMIT}"
      fi
    fi
  done

  after="$(downloaded_file_count "${file_prefix}")"
  if (( after < target_count )); then
    echo "[WARN] partial download stopped at ${after}/${target_count}; continuing to Post anyway." >&2
  fi

  echo "[INFO] partial download end: $(timestamp)"
  end_time="$(now_seconds)"
  elapsed="$(awk -v start="${start_time}" -v end="${end_time}" 'BEGIN { printf "%.3f", end - start }')"
  echo "[INFO] partial download elapsed: ${elapsed}s, downloaded ${after}/${target_count} frame(s)"
}

download_pending_captures() {
  local file_prefix="${1:-${current_file_prefix}}"
  local idle_chunks=0
  local before
  local after

  echo "[INFO] final download begin: $(timestamp)"

  while (( idle_chunks < DOWNLOAD_IDLE_CHUNK_LIMIT )); do
    download_event_chunk "${file_prefix}" "${DOWNLOAD_WAIT_MILLISECONDS}"
    before="${download_chunk_before}"
    after="${download_chunk_after}"

    if (( after > before )); then
      if [[ "${SHOW_DOWNLOAD_PROGRESS}" != "0" ]]; then
        echo "[INFO] downloaded $((after - before)) frame(s), total ${after}"
      fi
      idle_chunks=0
    else
      idle_chunks=$((idle_chunks + 1))
      if [[ "${SHOW_DOWNLOAD_PROGRESS}" != "0" ]]; then
        echo "[INFO] final download idle ${idle_chunks}/${DOWNLOAD_IDLE_CHUNK_LIMIT}"
      fi
    fi
  done

  echo "[INFO] final download end: $(timestamp)"
  rename_downloaded_captures_by_exposure "${file_prefix}"
  pending_download=0
}

log_event() {
  local stage="$1"
  local requested="$2"
  local confirmed="$3"
  local shot_or_count="$4"
  local event="$5"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${phase_index}" "${stage}" "${requested}" "${confirmed}" "${shot_or_count}" "${event}" "$(timestamp)" >>"${PHASE_LOG}"
}

trigger_single_shot() {
  local stage="$1"
  local requested="$2"
  local confirmed="$3"
  local shot="$4"
  local shot_time

  shot_time="$(timestamp)"
  echo "[INFO] ${stage} ${requested} shot ${shot}: ${shot_time}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${phase_index}" "${stage}" "${requested}" "${confirmed}" "${shot}" "shot" "${shot_time}" >>"${PHASE_LOG}"

  if ! gphoto2 --set-config "${CAPTURE_ACTION_CONFIG}=1" >/dev/null 2>&1; then
    echo "[ERROR] Cannot trigger capture." >&2
    exit 1
  fi
  captured_any=1
  pending_download=1
  sleep "${SHUTTER_PRESS_SECONDS}"
  release_capture
}

run_shutter_series() {
  local stage="$1"
  local shutterspeed="$2"
  local shots="$3"
  local first_shot_epoch="${4:-}"
  local confirmed_shutterspeed
  local next_shot_time
  local shot

  phase_index=$((phase_index + 1))
  confirmed_shutterspeed="$(set_and_confirm_shutterspeed "${shutterspeed}")"

  if [[ -n "${first_shot_epoch}" ]]; then
    wait_until_epoch "${first_shot_epoch}" "${stage} ${shutterspeed} first shot"
  fi

  echo "[INFO] ${stage} ${shutterspeed} begin: $(timestamp)"
  log_event "${stage}" "${shutterspeed}" "${confirmed_shutterspeed}" "${shots}" "begin"

  next_shot_time="$(now_seconds)"
  for ((shot = 1; shot <= shots; shot++)); do
    sleep_until "${next_shot_time}"
    trigger_single_shot "${stage}" "${shutterspeed}" "${confirmed_shutterspeed}" "${shot}"
    # SHOT_INTERVAL controls the one-shot-per-second cadence.
    next_shot_time="$(add_seconds "${next_shot_time}" "${SHOT_INTERVAL}")"
  done

  echo "[INFO] ${stage} ${shutterspeed} end: $(timestamp)"
  log_event "${stage}" "${shutterspeed}" "${confirmed_shutterspeed}" "${shots}" "end"
}

run_pre_stage() {
  run_shutter_series "Pre" "${PRE_SHUTTER}" "${PRE_FRAME_COUNT}" "${pre_first_shot_epoch}"
}

run_totality_stage() {
  local shutterspeed

  for shutterspeed in ${TOTALITY_SHUTTERS}; do
    run_shutter_series "Totality" "${shutterspeed}" "${TOTALITY_FRAMES_PER_SHUTTER}"
  done
}

configure_schedule() {
  if [[ -n "${C2_TIME}" ]]; then
    c2_epoch="$(parse_schedule_time "C2_TIME" "${C2_TIME}")"
    pre_first_shot_epoch="$(floor_seconds "$(subtract_seconds "${c2_epoch}" "${C2_PRE_LEAD_SECONDS}")")"
    echo "[INFO] C2 time: $(format_epoch "${c2_epoch}")"
    echo "[INFO] scheduled Pre first shot: $(format_epoch "${pre_first_shot_epoch}") (C2 - ${C2_PRE_LEAD_SECONDS}s)"
  fi

  if [[ -n "${C3_TIME}" ]]; then
    c3_epoch="$(parse_schedule_time "C3_TIME" "${C3_TIME}")"
    post_stop_epoch="$(floor_seconds "$(add_seconds "${c3_epoch}" "${C3_POST_DELAY_SECONDS}")")"
    echo "[INFO] C3 time: $(format_epoch "${c3_epoch}")"
    echo "[INFO] scheduled Post stop: $(format_epoch "${post_stop_epoch}") (C3 + ${C3_POST_DELAY_SECONDS}s)"
  fi
}

run_post_stage() {
  local confirmed_shutterspeed
  local next_shot_time
  local shot=0
  local now

  phase_index=$((phase_index + 1))
  confirmed_shutterspeed="$(set_and_confirm_shutterspeed "${POST_SHUTTER}")"

  echo "[INFO] Post ${POST_SHUTTER} begin; press Ctrl-C to stop Post and download all pending captures: $(timestamp)"
  log_event "Post" "${POST_SHUTTER}" "${confirmed_shutterspeed}" "until-ctrl-c" "begin"

  next_shot_time="$(now_seconds)"
  while true; do
    if [[ -n "${post_stop_epoch}" ]] && time_gt "${next_shot_time}" "${post_stop_epoch}"; then
      sleep_until "${post_stop_epoch}"
      echo "[INFO] Post stop time reached: $(timestamp)"
      break
    fi

    now="$(now_seconds)"
    if [[ -n "${post_stop_epoch}" ]] && time_ge "${now}" "${post_stop_epoch}"; then
      echo "[INFO] Post stop time reached: $(timestamp)"
      break
    fi

    shot=$((shot + 1))
    sleep_until "${next_shot_time}"

    now="$(now_seconds)"
    if [[ -n "${post_stop_epoch}" ]] && time_ge "${now}" "${post_stop_epoch}"; then
      echo "[INFO] Post stop time reached: $(timestamp)"
      break
    fi

    trigger_single_shot "Post" "${POST_SHUTTER}" "${confirmed_shutterspeed}" "${shot}"
    # Post uses the same one-shot-per-second cadence until Ctrl-C.
    next_shot_time="$(add_seconds "${next_shot_time}" "${SHOT_INTERVAL}")"
  done
}

warn_sdram_capacity_if_needed() {
  local totality_count
  local frames_before_first_download

  if (( SDRAM_FRAME_CAPACITY <= 0 )); then
    return 0
  fi

  totality_count="$(word_count "${TOTALITY_SHUTTERS}")"
  frames_before_first_download=$((PRE_FRAME_COUNT + totality_count * TOTALITY_FRAMES_PER_SHUTTER))

  if (( frames_before_first_download > SDRAM_FRAME_CAPACITY )); then
    echo "[WARN] ${frames_before_first_download} frame(s) are planned before the first download, above SDRAM capacity ${SDRAM_FRAME_CAPACITY}." >&2
    echo "[WARN] Reduce Pre/Totality shots or download earlier before starting Post." >&2
  fi
}

cleanup() {
  local status=$?

  trap - EXIT INT TERM
  set +e
  release_capture

  if (( captured_any == 1 )) && (( pending_download == 1 )) && [[ "${DOWNLOAD_ON_EXIT}" != "0" ]]; then
    if (( safe_exit_requested == 1 )); then
      echo "[INFO] safe exit requested; downloading all pending SDRAM captures: $(timestamp)" >&2
    else
      echo "[INFO] exiting before normal completion; downloading all pending SDRAM captures: $(timestamp)" >&2
    fi
    download_pending_captures "${current_file_prefix}"
  fi

  exit "${status}"
}

safe_exit() {
  local status="$1"

  if (( safe_exit_requested == 1 )); then
    trap - EXIT INT TERM
    set +e
    release_capture
    exit "${status}"
  fi

  safe_exit_requested=1
  trap - INT TERM
  set +e
  echo "[INFO] safe exit requested; releasing shutter and stopping shooting: $(timestamp)" >&2
  release_capture
  exit "${status}"
}

trap cleanup EXIT
trap 'safe_exit 130' INT
trap 'safe_exit 143' TERM

echo "[INFO] download directory: ${DOWNLOAD_DIR}"
mkdir -p "${DOWNLOAD_DIR}"

if [[ "${RECOVER_ONLY}" != "0" ]]; then
  download_pending_captures "${current_file_prefix}"
  exit 0
fi

printf 'phase\tstage\trequested_shutterspeed\tconfirmed_shutterspeed\tshot_or_count\tevent\tcomputer_time\n' >"${PHASE_LOG}"

configure_schedule
warn_sdram_capacity_if_needed
set_computer_only_capture_target
set_single_shot_capture_mode
if ! gphoto2 --set-config /main/imgsettings/iso="${ISO}" >/dev/null 2>&1; then
  echo "[ERROR] Cannot set ISO to ${ISO}." >&2
  exit 1
fi

run_pre_stage
run_totality_stage
download_until_count "${POST_START_AFTER_DOWNLOAD_FRAMES}" "${current_file_prefix}"
set_single_shot_capture_mode
run_post_stage

if (( pending_download == 1 )) && [[ "${DOWNLOAD_ON_EXIT}" != "0" ]]; then
  echo "[INFO] shooting complete; downloading all pending SDRAM captures: $(timestamp)"
  download_pending_captures "${current_file_prefix}"
fi
