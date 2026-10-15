F=/usr/lib/jellyfin-ffmpeg/ffmpeg
SRC=${SRC:-$(ls /data/media/anime-movies/*/*.mkv | head -1)}
B=${B:-/cache/bench}
HW="-init_hw_device vaapi=va:/dev/dri/renderD128,driver=iHD -init_hw_device qsv=qs@va -init_hw_device opencl=ocl@va -filter_hw_device qs"
DEC="-hwaccel vaapi -hwaccel_output_format vaapi -noautorotate"
H264="-c:v h264_qsv -preset veryfast -look_ahead 0 -low_power 1 -g:v 72 -keyint_min:v 72"
AAC="-c:a aac -ac 2 -b:a 256k"
case_cmd() {
  local c=$1 dur=$2
  case $c in
    C) echo "$F -hide_banner -nostdin -benchmark $HW $DEC -ss 600 -t $dur -i '$SRC' -map 0:v:0 -map 0:a:0 -vf hwmap=derive_device=qsv,scale_qsv=w=1280:h=720:format=nv12 $H264 -b:v 4M -maxrate 4M -bufsize 8M $AAC -f null -" ;;
    P) echo "$F -hide_banner -nostdin -benchmark $HW $DEC -ss 600 -t $dur -i '$SRC' -filter_complex '[0:3]scale=1920:1080,format=bgra,hwupload=derive_device=qsv:extra_hw_frames=64[sub];[0:0]hwmap=derive_device=qsv,scale_qsv=format=nv12[main];[main][sub]overlay_qsv=eof_action=pass:repeatlast=0[out]' -map [out] -map 0:a:0 $H264 -b:v 10M -maxrate 10M -bufsize 20M $AAC -f null -" ;;
    A) echo "$F -hide_banner -nostdin -benchmark $HW $DEC -stream_loop -1 -t $dur -i $B/a_hevc10.mkv -filter_complex 'alphasrc=s=1920x1080:r=24000/1001:start=0,format=bgra,subtitles=f=$B/${ASS:-typical}.ass:alpha=1:sub2video=1,hwupload=derive_device=qsv:extra_hw_frames=64[sub];[0:0]hwmap=derive_device=qsv,vpp_qsv=format=nv12[main];[main][sub]overlay_qsv=eof_action=pass:repeatlast=0[out]' -map [out] -map 0:a:0 $H264 -b:v 10M -maxrate 10M -bufsize 20M -c:a copy -f null -" ;;
    B) echo "$F -hide_banner -nostdin -benchmark $HW $DEC -stream_loop -1 -t $dur -i $B/b_hdr10.mkv -filter_complex '[0:0]hwmap=derive_device=qsv,scale_qsv=w=1920:h=1080:format=p010,hwmap=derive_device=opencl,tonemap_opencl=format=nv12:p=bt709:t=bt709:m=bt709:tonemap=bt2390:peak=100:desat=0,hwmap=derive_device=qsv:reverse=1:extra_hw_frames=40[out]' -map [out] -map 0:a:0 $H264 -b:v 12M -maxrate 12M -bufsize 24M $AAC -f null -" ;;
    BV) echo "$F -hide_banner -nostdin -benchmark $HW $DEC -stream_loop -1 -t $dur -i $B/b_hdr10.mkv -map 0:v:0 -map 0:a:0 -vf hwmap=derive_device=qsv,vpp_qsv=w=1920:h=1080:format=nv12:tonemap=1 $H264 -b:v 12M -maxrate 12M -bufsize 24M $AAC -f null -" ;;
  esac
}
