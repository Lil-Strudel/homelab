#!/bin/bash
# usage: run.sh "CASE[,CASE...]" N WALL_SECONDS   (cases are cycled across the N copies)
. "$(dirname "$0")/cases.sh"
IFS=, read -ra CASES <<< "$1"; N=$2; WALL=$3
OUT=$B/out; mkdir -p $OUT; rm -f $OUT/*.log
engines() {
  for p in /proc/[0-9]*; do
    grep -q jellyfin-ffmpeg/ffmpeg $p/cmdline 2>/dev/null || continue
    for fd in $p/fdinfo/*; do grep -q '^drm-driver:' $fd 2>/dev/null && cat $fd; done
  done | awk '/^drm-client-id/{id=$2} /^drm-engine-[a-z-]+:/{k=$1; sub(":","",k); v[id" "k]=$2} /^drm-engine-capacity-/{k=$1; sub(":","",k); cap[k]=$2}
    END{for (x in v){split(x,a," "); s[a[2]]+=v[x]} for (k in s) print k, s[k]; for (k in cap) print k, cap[k]}'
}
start=$(date +%s.%N)
for i in $(seq 1 $N); do
  c=${CASES[$(( (i-1) % ${#CASES[@]} ))]}
  eval "timeout -s INT ${WALL}s $(case_cmd $c 36000)" > $OUT/$i-$c.log 2>&1 &
done
sleep 10; e1=$(engines); t1=$(date +%s.%N)
sleep 25; e2=$(engines); t2=$(date +%s.%N)
wait
cpus=$(nproc)
printf "N=%-2s cases=%-8s " $N "$1"
for f in $OUT/*.log; do
  sp=$(tr '\r' '\n' < $f | grep -oE 'speed= *[0-9.]+x' | tail -1 | grep -oE '[0-9.]+')
  b=$(grep -oE 'utime=[0-9.]+s stime=[0-9.]+s rtime=[0-9.]+s' $f | tail -1)
  ut=$(echo "$b" | sed -E 's/utime=([0-9.]+)s.*/\1/'); st=$(echo "$b" | sed -E 's/.*stime=([0-9.]+)s.*/\1/'); rt=$(echo "$b" | sed -E 's/.*rtime=([0-9.]+)s/\1/')
  err=$(grep -ciE 'error|failed' $f)
  printf "[%s %sx cpu=%s%%%s] " "$(basename $f .log)" "${sp:-?}" "$(awk -v u=$ut -v s=$st -v r=$rt 'BEGIN{printf "%.0f", (u+s)/r*100}')" "$( [ $err -gt 0 ] && echo " ERR")"
done
echo
awk -v t1=$t1 -v t2=$t2 'NR==FNR{a[$1]=$2; next} {b[$1]=$2} END{dt=(t2-t1)*1e9; for (k in b) if (k !~ /capacity/) { c=b["drm-engine-capacity-" substr(k,12)]; if (c=="") c=1; printf "  gpu %-28s %5.1f%%\n", k, (b[k]-a[k])/(dt*c)*100 } }' <(echo "$e1") <(echo "$e2") | sort
