#!/bin/bash

APP_NAME="Remote"

log() {
  local shutter="$1"
  echo "shutter: ${shutter}, timestamp: $(date "+%Y-%m-%d %H:%M:%S")"
}

# Activate IEDT Remote
osascript -e "tell application \"$APP_NAME\" to activate"
sleep 2

# 1 = key code 18
# S = key code 1
# Shift+S = key code 1 using shift down
# Control+R = key code 15 using control down

# 1/4000 s
log "1/4000 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 3
    key up "1"
end tell
EOF
sleep 2

# 1/2000 s
for i in {1..2}; do
  osascript -e 'tell application "System Events" to key code 1'
  sleep 1
done
sleep 1

log "1/2000 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 2
    key up "1"
end tell
EOF
sleep 2

# 1/1000 s
for i in {1..2}; do
  osascript -e 'tell application "System Events" to key code 1'
  sleep 1
done
sleep 1

log "1/1000 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 2
    key up "1"
end tell
EOF
sleep 4

# 1/500 s
for i in {1..2}; do
  osascript -e 'tell application "System Events" to key code 1'
  sleep 1
done
sleep 1

log "1/500 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 2
    key up "1"
end tell
EOF
sleep 2

# 1/250 s
for i in {1..2}; do
  osascript -e 'tell application "System Events" to key code 1'
  sleep 1
done
sleep 1

log "1/250 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 2
    key up "1"
end tell
EOF
sleep 2

# 1/125 s
for i in {1..2}; do
  osascript -e 'tell application "System Events" to key code 1'
  sleep 1
done
sleep 1

log "1/125 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 2
    key up "1"
end tell
EOF
sleep 2

# 1/60 s
for i in {1..2}; do
  osascript -e 'tell application "System Events" to key code 1'
  sleep 1
done
sleep 1

log "1/60 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 2
    key up "1"
end tell
EOF
sleep 2

# 1/30 s
for i in {1..2}; do
  osascript -e 'tell application "System Events" to key code 1'
  sleep 1
done
sleep 1

log "1/30 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 2
    key up "1"
end tell
EOF
sleep 2

# 1/15 s
for i in {1..2}; do
  osascript -e 'tell application "System Events" to key code 1'
  sleep 1
done
sleep 1

log "1/15 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 3
    key up "1"
end tell
EOF
sleep 2

# 1/15 s -> 1/200 s: 0.5EV x 7 faster shutter steps
for i in {1..7}; do
  osascript -e 'tell application "System Events" to key code 1 using shift down'
  sleep 1
done
sleep 1

log "1/200 s"
osascript <<'EOF'
tell application "System Events"
    key down "1"
    delay 6
    key up "1"
end tell
EOF
