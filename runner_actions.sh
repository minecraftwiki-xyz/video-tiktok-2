#!/bin/bash
# Марафон для GitHub Actions: по кругу по каналам, БЕСКОНЕЧНО (пока есть видео) или лимит времени.
# Самообновляется с origin/main при старте. Пишет zero_runs.txt: 0 если прогресс, иначе N+1
# (3 подряд = стоп самодиспатча, чтобы не жечь минуты при исчерпанных каналах).
set -u
export LC_ALL=C.UTF-8
cd "$(dirname "$0")"
START_TS=$(date +%s)
STOP_MIN=${STOP_AFTER_MIN:-330}
TARGET="${TARGET:-1000000}"
CAP="${CAP_PER_CHANNEL:-40}"
EMPTY=0

# самообновление до свежего main (другие раннеры могли пушить код/processed.txt)
git fetch -q origin main 2>/dev/null && git checkout -q origin/main -- pipeline.sh runner_actions.sh channels.txt processed.txt zero_runs.txt 2>/dev/null || true

DONE0=$(grep -c '|done|' processed.txt 2>/dev/null || true); DONE0=${DONE0:-0}
# склад: если на GitHub уже >=100 видео - ран не нужен, выходим лёгким
STOCK=$(curl -s -m 25 -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/minecraftwiki-xyz/video-tiktok-2/contents/videos" | python3 -c "import json,sys
try: print(len(json.load(sys.stdin)))
except: print(0)" 2>/dev/null || echo 0)
if [ "${STOCK:-0}" -ge 100 ]; then echo "=== склад полный ($STOCK>=100) - ран не нужен, выход"; echo 0 > zero_runs.txt; exit 0; fi
echo "=== СТАРТ ACTIONS-МАРАФОНА $(date -u '+%d.%m %H:%M:%S') UTC, done=$DONE0, склад=$STOCK (target=$TARGET, cap=$CAP) ==="
while true; do
  TOTAL=$(grep -c '|done|' processed.txt 2>/dev/null || true); TOTAL=${TOTAL:-0}
  [ "$TOTAL" -ge "$TARGET" ] && { echo "=== ЦЕЛЬ $TARGET ДОСТИГНУТА ==="; break; }
  ELAPSED=$(( ($(date +%s) - START_TS) / 60 ))
  [ "$ELAPSED" -ge "$STOP_MIN" ] && { echo "=== лимит времени ${STOP_MIN}м, выход на перезапуск ==="; break; }
  PROGRESS=0
  while read -r CH; do
    [ -z "$CH" ] && continue
    TOTAL=$(grep -c '|done|' processed.txt 2>/dev/null || true); TOTAL=${TOTAL:-0}
    [ "$TOTAL" -ge "$TARGET" ] && break
    ELAPSED=$(( ($(date +%s) - START_TS) / 60 ))
    [ "$ELAPSED" -ge "$STOP_MIN" ] && break
    STOCK=$(curl -s -m 20 -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/minecraftwiki-xyz/video-tiktok-2/contents/videos" | python3 -c "import json,sys
try: print(len(json.load(sys.stdin)))
except: print(0)" 2>/dev/null || echo 0)
    [ "${STOCK:-0}" -ge 100 ] && { echo "=== склад пополнен ($STOCK>=100) - стоп"; break 2; }
    CH_DONE=$(awk -F'|' -v c="$CH" '$1==c && $3=="done"{n++} END{print n+0}' processed.txt 2>/dev/null)
    if [ "$CH_DONE" -ge "$CAP" ]; then echo "--- канал $CH уже $CH_DONE (кап $CAP) - пропуск для баланса"; continue; fi
    echo "--- [$TOTAL] канал $CH (elapsed ${ELAPSED}м)"
    if GH_TOKEN="$GH_TOKEN" bash pipeline.sh "$CH" </dev/null; then PROGRESS=$((PROGRESS+1)); fi
    sleep 2
  done < channels.txt
  if [ "$PROGRESS" -eq 0 ]; then
    EMPTY=$((EMPTY+1))
    echo "=== пустой круг №$EMPTY"
    [ "$EMPTY" -ge 3 ] && { echo "=== 3 пустых круга подряд - выход"; break; }
    sleep 30
  else
    EMPTY=0
  fi
done
DONE1=$(grep -c '|done|' processed.txt 2>/dev/null || true); DONE1=${DONE1:-0}
ZR=0; [ -f zero_runs.txt ] && ZR=$(cat zero_runs.txt 2>/dev/null || echo 0)
if [ "$DONE1" -gt "$DONE0" ]; then echo 0 > zero_runs.txt; else echo $(( ${ZR:-0} + 1 )) > zero_runs.txt; fi
echo "=== РАН ОКОНЧЕН: done=$DONE1, zero_runs=$(cat zero_runs.txt)"
