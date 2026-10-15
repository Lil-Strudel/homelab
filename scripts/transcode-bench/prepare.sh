#!/bin/bash
set -euo pipefail
. "$(dirname "$0")/cases.sh"
cd "$B"
$F -hide_banner -v error -y $HW $DEC -ss 600 -t 120 -i "$SRC" -map 0:v:0 -map 0:a:0 \
  -vf hwmap=derive_device=qsv,vpp_qsv=format=p010 -c:v hevc_qsv -profile:v main10 -low_power 1 -b:v 6M -maxrate 9M -bufsize 12M -g 240 \
  -c:a aac -ac 2 -b:a 192k a_hevc10.mkv
$F -hide_banner -v error -y $HW $DEC -ss 600 -t 120 -i "$SRC" -map 0:v:0 -map 0:a:0 \
  -vf hwmap=derive_device=qsv,vpp_qsv=w=3840:h=2160:format=p010 -c:v hevc_qsv -profile:v main10 -low_power 1 -b:v 40M -maxrate 60M -bufsize 80M -g 240 \
  -c:a copy -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv b_hdr10.mkv
