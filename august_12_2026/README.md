# August 12 2026 Eclipse Capture Script

This directory contains the `gphoto2.sh` capture script for an ILCE-7RM3A camera in PC Remote / SDRAM capture mode.

## Default Flow

All still frames are captured in single-shot mode.

1. Pre: `1/4000 s`, 6 frames, 1 frame/s.
2. Totality: `1/2000 1/1000 1/500 1/250 1/125 1/60 1/30 1/15 1/8 1/4`, 3 frames per shutter speed, 1 frame/s.
3. Partial download: download `POST_START_AFTER_DOWNLOAD_FRAMES` frames before Post.
4. Post: `1/4000 s`, 1 frame/s until Ctrl-C or `C3_TIME + 3s`.
5. Final download: download all pending SDRAM frames and silently rename ARW files by exposure time.

Nominal elapsed time before the first download is about `+00:00:36`: Pre `+00:00:06` and Totality `+00:00:30`, plus shutter-confirmation overhead.

## Scheduled Start and Stop

`C2_TIME` marks the start of totality. When it is set, the script waits so the first Pre frame is captured at `C2_TIME - 3s`.

`C3_TIME` marks the end of totality. When it is set, Post stops automatically at `C3_TIME + 3s`. Ctrl-C still works at any time and triggers safe download of pending SDRAM frames.

Supported time formats:

```bash
C2_TIME='2026-08-12 20:32:00'
C2_TIME='20:32:00'
```

Time-only values use the current local date.

Examples:

```bash
./gphoto2.sh
```

```bash
C2_TIME='2026-08-12 20:32:00' C3_TIME='2026-08-12 20:34:00' ./gphoto2.sh
```

## Main Configuration

```bash
PRE_SHUTTER=1/4000
PRE_FRAME_COUNT=6
TOTALITY_SHUTTERS='1/2000 1/1000 1/500 1/250 1/125 1/60 1/30 1/15 1/8 1/4'
TOTALITY_FRAMES_PER_SHUTTER=3
POST_SHUTTER=1/4000
SHOT_INTERVAL=1
POST_START_AFTER_DOWNLOAD_FRAMES=6
```

The ILCE-7RM3A SDRAM capacity used by the script is fixed at 36 RAW frames. A RAW download has been measured at about 2.2s/frame. For a 1m20s totality, set `POST_START_AFTER_DOWNLOAD_FRAMES=6`, which costs about 13s before Post.

## Output

Downloaded files are written directly to:

```bash
captures/
```

After the final download, ARW files are renamed by exposure time, for example:

```text
4000.1.ARW
4000.2.ARW
2000.1.ARW
4.3.ARW
```

The phase log is written as:

```text
captures/<RUN_ID>_phase-log.tsv
```

## Debug Output

The script normally hides raw `gphoto2` download chatter and only prints its own English logs.

To inspect lower-level download output:

```bash
SHOW_GPHOTO2_DOWNLOAD_OUTPUT=1 SHOW_DOWNLOAD_PROGRESS=1 ./gphoto2.sh
```

To also keep unknown PTP events visible:

```bash
SHOW_GPHOTO2_DOWNLOAD_OUTPUT=1 SHOW_UNKNOWN_PTP_EVENTS=1 ./gphoto2.sh
```

## Recovery

If shooting was interrupted and SDRAM frames still need to be pulled:

```bash
RECOVER_ONLY=1 ./gphoto2.sh
```
