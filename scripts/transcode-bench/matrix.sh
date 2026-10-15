#!/bin/bash
cd "$(dirname "$0")"
for c in C A B BV P; do
  for n in 1 2 3 4 6 8; do bash run.sh $c $n 45; done
done
bash run.sh A,A,B 3 45
ASS=extreme bash run.sh A 1 45 | sed 's/cases=A /cases=A-extreme /'
bash run.sh A,A,B,C 4 45
