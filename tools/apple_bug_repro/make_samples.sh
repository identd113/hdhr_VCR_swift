#!/bin/bash
# Makes three 60-second MPEG-2/AC-3 transport streams that differ only in where their 90 kHz timestamps start.
# Needs ffmpeg (used only to generate the test pattern; the bug is in AVFoundation's reader).
#   before.ts  starts at 47600 s -> timestamps stay below 2^32 (4,294,967,296) for the whole file
#   across.ts  starts at 47692 s -> timestamps cross 2^32 (at 47,721.86 s) 29 s into the file
#   after.ts   starts at 47730 s -> timestamps are above 2^32 for the whole file
set -e
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  echo "Usage: make_samples.sh   (no arguments; needs ffmpeg on PATH)"
  echo "Writes before.ts / across.ts / after.ts (60 s MPEG-2 + AC-3 each) next to this script."
  echo "Then: swiftc -o read_samples read_samples.swift && ./read_samples across.ts   (docs/AppleBugReport_TS_2e32.md)"
  exit 0
fi
cd "$(dirname "$0")"
for pair in before:47600 across:47692 after:47730; do
  name=${pair%%:*}; off=${pair##*:}
  ffmpeg -v error -y -f lavfi -i "testsrc2=size=1280x720:rate=60000/1001" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 60 -c:v mpeg2video -b:v 6M -g 30 -c:a ac3 -b:a 192k -output_ts_offset "$off" -f mpegts "$name.ts"
done
ls -l before.ts across.ts after.ts
