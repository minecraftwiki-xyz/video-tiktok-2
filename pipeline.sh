#!/bin/bash
# Обработать ОДНО видео канала.
# Итог 179.5с; стоп-кадры с оверлеем на финальных 0:10 / 1:10 / 2:10 (ровно 5.5с каждый);
# оверлей со звуком, по центру, ~44% экрана; fps = источник (>=50); тематика CS2;
# имя файла = ТОЧНОЕ название ролика. Заливка: git push в videos/.
# Использование: GH_TOKEN='...' bash pipeline.sh "@handle_канала"
set -u
export LC_ALL=C.UTF-8   # иначе grep -i не матчит заглавную кириллицу (POSIX locale)
cd "$(dirname "$0")"
CH="$1"
OWNER_REPO="minecraftwiki-xyz/video-tiktok-2"
TOPIC_RE='cs2|csgo|cs:go|counter|кс2|\bкс\b|кейс|скин|noscope|ноускоп|faceit|фейс|premier|премьер|karambit|керамбит|stattrak|статтрек|s1mple|donk|m0nesy|zywoo|clutch|клатч|bhop|headshot|major|мейджор|gloves?|перчатк|наклейк|sticker|scar|g3sg1|calibr|калибров|троллинг|анбоксинг|выпал|выпаден|открыва|elo|lvl|deagle|inferno|mirage|dust|nuke|cache|anubis|ancient|vertigo|tier|тир|миф|myth|streamer|стример|ранк|rank|pro |noob|нуб|читер|cheater|aim|глобал|mvp|1v1|2v2|5v5|смурф|smurf|тиммейт|рейтинг|капсул|souvenir|сувенир|донат|игрок'
CP="crop=ih*9/16:ih,scale=720:1280"
FFV="-c:v libx264 -preset ultrafast -crf 16 -an"
VIDSEL="bv[height<=720]/bv"
AUDSEL="bestaudio"
REPO_DIR="${REPO_DIR:-/tmp/repo}"   # локально переопределяется на диск (tmpfs всего 1GB!)

# --- git helpers: partial clone без блобов; каждый push родитель = актуальный origin/main
git_sync() {
  if [ ! -d "$REPO_DIR/.git" ]; then
    rm -rf "$REPO_DIR"
    git clone -q --filter=blob:none --no-checkout "https://x-access-token:$GH_TOKEN@github.com/$OWNER_REPO" "$REPO_DIR" || return 1
    mkdir -p "$REPO_DIR/videos"
  fi
  git -C "$REPO_DIR" fetch -q origin main || return 1
  git -C "$REPO_DIR" reset -q --soft FETCH_HEAD || return 1
  git -C "$REPO_DIR" read-tree FETCH_HEAD 2>/dev/null || git -C "$REPO_DIR" read-tree -m FETCH_HEAD || return 1
}
# подготовить коммит: видео + union-синк processed.txt между локалью и репо
_prep_commit() {
  local F="$1" NAME="$2"
  cp "$F" "$REPO_DIR/videos/$NAME" || return 1
  git -C "$REPO_DIR" add "videos/$NAME" || return 1
  # union-синхронизация маркеров processed.txt (локальный <-> репо, оба раннера)
  if [ -f "$REPO_DIR/processed.txt" ] && [ -f processed.txt ]; then
    sort -u processed.txt "$REPO_DIR/processed.txt" > /tmp/_merged_p.txt
    cp /tmp/_merged_p.txt processed.txt
    cp /tmp/_merged_p.txt "$REPO_DIR/processed.txt"
  elif [ -f processed.txt ]; then
    cp processed.txt "$REPO_DIR/processed.txt"
  fi
  [ -f "$REPO_DIR/processed.txt" ] && git -C "$REPO_DIR" add processed.txt
  git -C "$REPO_DIR" -c user.email=bot@local -c user.name="bot" commit -q -m "add $NAME" || \
  git -C "$REPO_DIR" -c user.email=bot@local -c user.name="bot" commit -q --allow-empty -m "sync processed"
}

upload_git() {
  local F="$1" NAME="$2"
  git_sync || return 1
  mkdir -p "$REPO_DIR/videos"
  _prep_commit "$F" "$NAME" || return 1
  if ! git -C "$REPO_DIR" push -q origin HEAD:main 2>/dev/null; then
    git_sync || return 1          # после reset файлы вернулись к HEAD - prepare заново
    _prep_commit "$F" "$NAME" || return 1
    git -C "$REPO_DIR" push -q origin HEAD:main || return 1
  fi
}

# --- окружение: локально файлы в uploads/, в GitHub Actions - assets/ + секрет
OL=uploads/video.mov.png; [ -f "$OL" ] || OL=assets/video.mov.png
CK=""; for F in uploads/m.youtube.com_cookies.txt assets/cookies.txt; do [ -f "$F" ] && { CK="--cookies $F"; break; }; done
CLIENTS="${YT_CLIENTS:-default,mweb,android_vr}"
ytc() { local CL="$1"; shift; local A=""; [ "$CL" != "default" ] && A="--extractor-args youtube:player_client=$CL"; yt-dlp $CK $A "$@" 2>/dev/null; }

MAP=""
for CL in ${CLIENTS//,/ }; do
  MAP=$(ytc "$CL" --flat-playlist --quiet --print "%(id)s|%(title)s" "https://youtube.com/$CH/videos" | head -"${MAP_MAX:-300}")
  [ -n "$MAP" ] && { echo "  список $CH получен (клиент=$CL): $(printf '%s\n' "$MAP" | wc -l) видео"; break; }
done
[ -z "$MAP" ] && { echo "ABORT: не удалось получить список $CH"; exit 2; }

ATTEMPTS=0
while IFS='|' read -r ID LIST_TITLE <&3; do   # fd3! иначе ffmpeg/aria2 крадут строки из stdin и ловят 'q'-команды
  [ "$ATTEMPTS" -ge 12 ] && break
  echo "$ID" | grep -qE '^[A-Za-z0-9_-]{11}$' || continue
  grep -q "^$CH|$ID|" processed.txt 2>/dev/null && continue
  ATTEMPTS=$((ATTEMPTS+1))

  TITLE=""
  for CL in ${CLIENTS//,/ }; do
    TITLE=$(ytc "$CL" --get-title "https://youtu.be/$ID" | head -1)
    [ -n "$TITLE" ] && break
  done
  [ -z "$TITLE" ] && TITLE="$LIST_TITLE"
  echo ">>> кандидат: $ID | ${TITLE:0:70}"

  if ! { echo "$TITLE" | grep -qiE "$TOPIC_RE" || echo "$LIST_TITLE" | grep -qiE "$TOPIC_RE"; }; then
    echo "$CH|$ID|skip-topic|$TITLE" >> processed.txt
    echo "    ПРОПУСК: не CS2 тематика"
    continue
  fi

  # имя файла заранее - проверяем, нет ли уже такого в videos/ на GitHub
  SAFE=$(echo "$TITLE" | tr '\n' ' ' | sed 's/[\/:*?"<>|]//g; s/^ *//; s/ *$//' | cut -c1-120)
  OUTNAME="$SAFE.mp4"
  if [ -n "${GH_TOKEN:-}" ] && [ -n "$SAFE" ]; then
    ENCPATH=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "videos/$OUTNAME" 2>/dev/null)
    CODE=$(curl -s -m 20 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$OWNER_REPO/contents/$ENCPATH")
    if [ "$CODE" = "200" ]; then
      echo "$CH|$ID|done-exists|$OUTNAME" >> processed.txt
      echo "    УЖЕ ЕСТЬ в videos/ - пропуск без скачивания"
      continue
    fi
  fi

  rm -f /tmp/dl_vid.bin /tmp/dl_aud.bin /tmp/clipv.mkv /tmp/clipa.mkv /tmp/f1.png /tmp/f2.png /tmp/f3.png /tmp/frz*.mp4 /tmp/part*.mp4 /tmp/out.mp4 /tmp/render.log /tmp/aria.log

  JNFO=""; VURL=""; AURL=""
  for CL in ${CLIENTS//,/ }; do
    for BACK in 0 4; do
      [ "$BACK" != "0" ] && sleep "$BACK"
      JNFO=$(ytc "$CL" --sleep-requests 1 -J -f "$VIDSEL,$AUDSEL" "https://youtu.be/$ID")
      [ -n "$JNFO" ] && break
    done
    if [ -n "$JNFO" ]; then
      printf '%s' "$JNFO" | python3 -c "
import json,sys
d=json.load(sys.stdin)
fmts=d.get('requested_downloads') or d.get('requested_formats') or [d]
v=[f for f in fmts if (f.get('vcodec') or 'none')!='none']
a=[f for f in fmts if (f.get('vcodec') or 'none')=='none' and (f.get('acodec') or 'none')!='none']
print((v and v[0].get('url') or d.get('url','')) or '')
print((a and a[0].get('url') or '') or '')
" > /tmp/urls.txt 2>/dev/null
      VURL=$(sed -n '1p' /tmp/urls.txt); AURL=$(sed -n '2p' /tmp/urls.txt)
    fi
    [ -n "$VURL" ] && break
  done
  [ -z "$VURL" ] && { echo "    нет прямого URL, следующий"; continue; }

  dl() { aria2c -x 16 -s 16 -k 1M --file-allocation=none --summary-interval=0 --console-log-level=warn --header="User-Agent: Mozilla/5.0" -d /tmp -o "$1" "$2" >>/tmp/aria.log 2>&1; }
  dl dl_vid.bin "$VURL" &
  PIDV=$!
  [ -n "$AURL" ] && { dl dl_aud.bin "$AURL" & PIDA=$!; } || PIDA=""
  wait $PIDV $PIDA
  [ -s /tmp/dl_vid.bin ] || { sleep 3; dl dl_vid.bin "$VURL"; }
  [ -s /tmp/dl_aud.bin ] || [ -z "$AURL" ] || { sleep 2; dl dl_aud.bin "$AURL"; }
  # запасной вариант: прямое скачивание yt-dlp (если прямые URL не пускают)
  if [ ! -s /tmp/dl_vid.bin ]; then
    for CL in ${CLIENTS//,/ }; do
      ytc "$CL" -f "$VIDSEL" --no-part -o /tmp/dl_vid.bin "https://youtu.be/$ID" >/dev/null 2>&1
      [ -s /tmp/dl_vid.bin ] && break; rm -f /tmp/dl_vid.bin
    done
  fi
  if [ ! -s /tmp/dl_aud.bin ] && [ -n "$AURL" ]; then :; fi
  if [ ! -s /tmp/dl_aud.bin ]; then
    for CL in ${CLIENTS//,/ }; do
      ytc "$CL" -f "$AUDSEL" --no-part -o /tmp/dl_aud.bin "https://youtu.be/$ID" >/dev/null 2>&1
      [ -s /tmp/dl_aud.bin ] && break; rm -f /tmp/dl_aud.bin
    done
  fi
  [ -s /tmp/dl_vid.bin ] || { echo "    видео не скачалось, следующий"; continue; }
  [ -s /tmp/dl_aud.bin ] || { echo "    аудио не скачалось"; rm -f /tmp/dl_vid.bin; continue; }
  SZVID=$(stat -c%s /tmp/dl_vid.bin)
  if [ "$SZVID" -gt 500000000 ]; then
    echo "$CH|$ID|skip-big|$((SZVID/1048576))MB" >> processed.txt
    rm -f /tmp/dl_vid.bin /tmp/dl_aud.bin
    echo "    ПРОПУСК: исходник >500MB ($((SZVID/1048576))MB), tmpfs не выдержит"
    continue
  fi

  FR=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 /tmp/dl_vid.bin)
  DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/dl_vid.bin)
  FPS=$(echo "$FR" | awk -F/ '{if($2>0) printf "%d", ($1/$2)+0.5; else print 0}')
  echo "    $FR fps, ${DUR}s"
  if [ "${FPS:-0}" -lt 50 ]; then echo "$CH|$ID|skip-fps|$FR" >> processed.txt; rm -f /tmp/dl_vid.bin /tmp/dl_aud.bin; echo "    ПРОПУСК: <50 fps"; continue; fi
  if awk "BEGIN{exit !($DUR<125)}"; then echo "$CH|$ID|skip-short|${DUR}s" >> processed.txt; rm -f /tmp/dl_vid.bin /tmp/dl_aud.bin; echo "    ПРОПУСК: короче 125с"; continue; fi
  [ "$FPS" -gt 60 ] && FPS=60
  FRZFR=$(awk "BEGIN{printf \"%d\", 5.5*$FPS}")

  ffmpeg -v error -y -t 165 -i /tmp/dl_vid.bin -c copy -f matroska /tmp/clipv.mkv >>/tmp/render.log 2>&1 || continue
  ffmpeg -v error -y -t 165 -i /tmp/dl_aud.bin -c copy -f matroska /tmp/clipa.mkv >>/tmp/render.log 2>&1 || { rm -f /tmp/clipv.mkv; continue; }
  rm -f /tmp/dl_vid.bin /tmp/dl_aud.bin
  VID=/tmp/clipv.mkv; AUD=/tmp/clipa.mkv

  SAFE=$(echo "$TITLE" | tr '\n' ' ' | sed 's/[\/:*?"<>|]//g; s/^ *//; s/ *$//' | cut -c1-120)
  OUTNAME="$SAFE.mp4"
  echo "    рендер: ${FPS} fps (стоп-кадр $FRZFR кадров x3) -> '$OUTNAME'"

  OK=1
  # стоп-кадры: картинки (input-seek; запасной вариант - точный output-seek)
  xc_png() { local SS="$1" OUT="$2"; rm -f "$OUT"; ffmpeg -v error -y -ss "$SS" -i "$VID" -frames:v 1 -vf "$CP" "$OUT" 2>>/tmp/render.log; [ -s "$OUT" ] || ffmpeg -v error -y -i "$VID" -ss "$SS" -frames:v 1 -vf "$CP" "$OUT" 2>>/tmp/render.log; [ -s "$OUT" ]; }
  xc_part() { local SS="$1" TT="$2" OUT="$3" D; rm -f "$OUT"
    if [ -z "$SS" ]; then ffmpeg -v error -y -t "$TT" -i "$VID" -vf "$CP,fps=$FPS" $FFV "$OUT" 2>>/tmp/render.log; else ffmpeg -v error -y -ss "$SS" -t "$TT" -i "$VID" -vf "$CP,fps=$FPS" $FFV "$OUT" 2>>/tmp/render.log; fi
    D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" 2>/dev/null)
    if [ -z "$D" ] || awk "BEGIN{exit !(${D:-0}<$TT-0.3 || ${D:-0}>$TT+0.3)}"; then
      if [ -z "$SS" ]; then ffmpeg -v error -y -i "$VID" -t "$TT" -vf "$CP,fps=$FPS" $FFV "$OUT" 2>>/tmp/render.log; else ffmpeg -v error -y -i "$VID" -ss "$SS" -t "$TT" -vf "$CP,fps=$FPS" $FFV "$OUT" 2>>/tmp/render.log; fi
      D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" 2>/dev/null)
    fi
    [ -n "$D" ] && ! awk "BEGIN{exit !($D<$TT-0.3 || $D>$TT+0.3)}"; }
  xc_png 10   /tmp/f1.png || OK=0
  xc_png 64.5 /tmp/f2.png || OK=0
  xc_png 119  /tmp/f3.png || OK=0
  [ $OK = 1 ] && { ffmpeg -v error -y -loop 1 -framerate $FPS -i /tmp/f1.png -frames:v $FRZFR -vf "format=yuv420p" $FFV /tmp/frz1.mp4 2>>/tmp/render.log || OK=0; }
  [ $OK = 1 ] && { ffmpeg -v error -y -loop 1 -framerate $FPS -i /tmp/f2.png -frames:v $FRZFR -vf "format=yuv420p" $FFV /tmp/frz2.mp4 2>>/tmp/render.log || OK=0; }
  [ $OK = 1 ] && { ffmpeg -v error -y -loop 1 -framerate $FPS -i /tmp/f3.png -frames:v $FRZFR -vf "format=yuv420p" $FFV /tmp/frz3.mp4 2>>/tmp/render.log || OK=0; }
  # 4 движущихся отрезка (input-seek + проверка, запасной output-seek)
  [ $OK = 1 ] && { xc_part ""    10   /tmp/part1.mp4 || OK=0; }
  [ $OK = 1 ] && { xc_part 10   54.5 /tmp/part2.mp4 || OK=0; }
  [ $OK = 1 ] && { xc_part 64.5 54.5 /tmp/part3.mp4 || OK=0; }
  [ $OK = 1 ] && { xc_part 119  44   /tmp/part4.mp4 || OK=0; }
  # контроль точности сегментов
  if [ $OK = 1 ]; then
    DF1=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/frz1.mp4); DF2=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/frz2.mp4); DF3=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/frz3.mp4)
    D1=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/part1.mp4); D2=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/part2.mp4); D3=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/part3.mp4); D4=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/part4.mp4)
    echo "    сегменты: $D1 $D2 $D3 $D4 | фризы: $DF1 $DF2 $DF3"
    if awk "BEGIN{exit !($DF1<5.45||$DF1>5.55||$DF2<5.45||$DF2>5.55||$DF3<5.45||$DF3>5.55||$D1<9.9||$D1>10.1||$D2<54.3||$D2>54.7||$D3<54.3||$D3>54.7||$D4<43.8||$D4>44.2)}"; then OK=0; echo "    СЕГМЕНТЫ НЕ ТОЧНЫЕ - пропуск видео"; fi
  fi
  if [ $OK = 1 ]; then
    assemble() {
      ffmpeg -v error -y -i /tmp/part1.mp4 -i /tmp/part2.mp4 -i /tmp/part3.mp4 -i /tmp/part4.mp4 \
      -i /tmp/frz1.mp4 -i /tmp/frz2.mp4 -i /tmp/frz3.mp4 \
      -i "$OL" -i "$OL" -i "$OL" -i "$AUD" \
      -filter_complex "[4:v]setpts=PTS-STARTPTS[fr1];[5:v]setpts=PTS-STARTPTS[fr2];[6:v]setpts=PTS-STARTPTS[fr3];[7:v]scale=1074:-2,format=rgba[o1];[8:v]scale=1074:-2,format=rgba[o2];[9:v]scale=1074:-2,format=rgba[o3];[fr1][o1]overlay=(W-w)/2:(H-h)/2:enable='lte(t,5.5)',trim=duration=5.5,setpts=PTS-STARTPTS[fo1];[fr2][o2]overlay=(W-w)/2:(H-h)/2:enable='lte(t,5.5)',trim=duration=5.5,setpts=PTS-STARTPTS[fo2];[fr3][o3]overlay=(W-w)/2:(H-h)/2:enable='lte(t,5.5)',trim=duration=5.5,setpts=PTS-STARTPTS[fo3];[0:v]setpts=PTS-STARTPTS[p1];[1:v]setpts=PTS-STARTPTS[p2];[2:v]setpts=PTS-STARTPTS[p3];[3:v]setpts=PTS-STARTPTS[p4];[p1][fo1][p2][fo2][p3][fo3][p4]concat=n=7:v=1:a=0[outv];[10:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,asplit=4[m1][m2][m3][m4];[m1]atrim=end=10,asetpts=PTS-STARTPTS[au1];[m2]atrim=start=10:end=64.5,asetpts=PTS-STARTPTS[au2];[m3]atrim=start=64.5:end=119,asetpts=PTS-STARTPTS[au3];[m4]atrim=start=119:end=163,asetpts=PTS-STARTPTS[au4];[7:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,atrim=duration=5.5,asetpts=PTS-STARTPTS[q1];[8:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,atrim=duration=5.5,asetpts=PTS-STARTPTS[q2];[9:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,atrim=duration=5.5,asetpts=PTS-STARTPTS[q3];[au1][q1][au2][q2][au3][q3][au4]concat=n=7:v=0:a=1[outa]" \
      -map "[outv]" -map "[outa]" -c:v libx264 -preset veryfast -crf 23 -c:a aac -movflags +faststart /tmp/out.mp4 2>>/tmp/render.log
    }
    assemble || { echo "    сборка упала, повтор..."; sleep 2; assemble; } || OK=0
  fi
  FDUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/out.mp4 2>/dev/null)
  VDUR=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 /tmp/out.mp4 2>/dev/null)
  if [ $OK = 1 ] && { [ ! -s /tmp/out.mp4 ] || awk "BEGIN{exit !(${VDUR:-0}<179.0 || ${VDUR:-0}>180.2)}"; }; then
    echo "    результат обрезанный (vdur=${VDUR:-none}), повтор сборки..."
    assemble
    FDUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/out.mp4 2>/dev/null)
    VDUR=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 /tmp/out.mp4 2>/dev/null)
  fi
  if [ $OK = 0 ] || [ ! -s /tmp/out.mp4 ] || awk "BEGIN{exit !(${VDUR:-0}<179.0 || ${VDUR:-0}>180.2)}"; then
    echo "    ОШИБКА рендера (dur=${FDUR:-none} vdur=${VDUR:-none}): $(tail -2 /tmp/render.log | head -1)"
    rm -f /tmp/out.mp4
    continue
  fi
  V1=$(ffmpeg -ss 10.3 -t 4.9 -i /tmp/out.mp4 -af volumedetect -f null - 2>&1 | grep mean_volume | grep -oE '\-?[0-9.]+ dB' | tr -d ' dB')
  V2=$(ffmpeg -ss 70.3 -t 4.9 -i /tmp/out.mp4 -af volumedetect -f null - 2>&1 | grep mean_volume | grep -oE '\-?[0-9.]+ dB' | tr -d ' dB')
  V3=$(ffmpeg -ss 130.3 -t 4.9 -i /tmp/out.mp4 -af volumedetect -f null - 2>&1 | grep mean_volume | grep -oE '\-?[0-9.]+ dB' | tr -d ' dB')
  echo "    звук пауз: ${V1:-?} / ${V2:-?} / ${V3:-?} dB | vdur=${VDUR}s"
  if awk "BEGIN{exit !(${V1:--91}<-45 || ${V2:--91}<-45 || ${V3:--91}<-45)}"; then
    echo "    ОШИБКА: тишина в одной из пауз, следующий"
    rm -f /tmp/out.mp4
    continue
  fi
  rm -f "$VID" "$AUD" /tmp/f1.png /tmp/f2.png /tmp/f3.png /tmp/frz*.mp4 /tmp/part*.mp4
  echo "    готово: $(du -h /tmp/out.mp4 | cut -f1), ${FDUR}s, заливаю в videos/..."

  SZ=$(stat -c%s /tmp/out.mp4)
  if [ "$SZ" -gt 95000000 ]; then
    echo "    >95MB, пережимаю crf26..."
    ffmpeg -v error -y -i /tmp/out.mp4 -c:v libx264 -preset veryfast -crf 26 -c:a copy -movflags +faststart /tmp/out2.mp4 && mv /tmp/out2.mp4 /tmp/out.mp4
    SZ=$(stat -c%s /tmp/out.mp4)
  fi
  if [ "$SZ" -gt 99000000 ]; then echo "$CH|$ID|skip-size|${SZ}" >> processed.txt; rm -f /tmp/out.mp4; echo "    ПРОПУСК: не влезает в GitHub даже после пережатия"; continue; fi

  if upload_git /tmp/out.mp4 "$OUTNAME"; then
    echo "$CH|$ID|done|$OUTNAME" >> processed.txt
    rm -f /tmp/out.mp4
    rm -rf "$REPO_DIR"   # не копить гит-объекты в tmpfs
    TOTAL=$(grep -c "|done|" processed.txt)
    echo "    ✅ ЗАЛИТО ($TOTAL/50)"
    exit 0
  fi
  echo "    ОШИБКА заливки (git api) | $(df -h /tmp | tail -1 | awk '{print "/tmp "$5}')"
  rm -f /tmp/out.mp4
  rm -rf "$REPO_DIR"     # не копить гит-объекты в tmpfs
  exit 4
done 3<<< "$MAP"
echo "Канал $CH: новых подходящих видео не найдено за $ATTEMPTS попыток"
exit 3
