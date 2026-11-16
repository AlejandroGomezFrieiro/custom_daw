#!/bin/sh
# gif.sh name : $WORK/name.mkv and its captions -> $WORK/name.gif, with the
# captions in a bar under the picture.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
WORK=${WORK:-$ROOT/target/test-scratch/media}
N=$1
FONTFILE=$(fc-match -f '%{file}' 'DejaVu Sans Mono')
filter=""; prev_t=""; prev_c=""; i=0
mkdir -p "$WORK/caps"
while IFS="$(printf '\t')" read -r t c; do
  if [ -n "$prev_c" ]; then
    i=$((i + 1))
    printf '%s' "$prev_c" > "$WORK/caps/$N-$i.txt"
    filter="$filter,drawtext=fontfile=$FONTFILE:textfile=$WORK/caps/$N-$i.txt:fontcolor=0xd8dee9:fontsize=20:x=(w-text_w)/2:y=h-33:enable='between(t,$prev_t,$t)'"
  fi
  prev_t=$t; prev_c=$c
done < "$WORK/$N.caps"
ffmpeg -loglevel error -y -i "$WORK/$N.mkv" -vf "fps=10,pad=iw:ih+44:0:0:color=0x0d0f12$filter,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" "$WORK/$N.gif"
gifsicle -O3 "$WORK/$N.gif" -o "$WORK/$N.gif" 2>/dev/null
