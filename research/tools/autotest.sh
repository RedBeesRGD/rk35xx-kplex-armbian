#!/bin/bash
# Keep reproducing until a genuine latch appears, then immediately run the
# instrumented patch test on it (association events counted for contamination).
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
for round in 1 2 3 4 5 6; do
  rm -f /tmp/repro-v3.csv
  BGFLOW=$(( round % 2 )) /tmp/repro-v3.sh 60 >/dev/null 2>&1
  if grep -q BAD /tmp/repro-v3.csv 2>/dev/null; then
    { echo "### reproduced in round $round (BGFLOW=$(( round % 2 )))"
      grep BAD /tmp/repro-v3.csv
      /tmp/patchtest.sh; } > /tmp/patchtest.out 2>&1
    exit 0
  fi
  echo "round $round: no repro ($(($(wc -l < /tmp/repro-v3.csv)-1)) trials)" >> /tmp/autotest.log
done
echo "### no reproduction in 6 rounds" > /tmp/patchtest.out
