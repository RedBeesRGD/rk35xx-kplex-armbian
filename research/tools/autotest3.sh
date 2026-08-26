#!/bin/bash
# Reproduce (cold start, ~20 s/trial), then run the backoff diagnostic on the live latch.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
for round in $(seq 1 8); do
  rm -f /tmp/repro-reload.csv
  /tmp/repro-reload.sh 15 >/dev/null 2>&1
  if grep -q BAD /tmp/repro-reload.csv 2>/dev/null; then
    { echo "### reproduced via cold start, round $round"; grep BAD /tmp/repro-reload.csv
      /tmp/latchdiag.sh; } > /tmp/latchdiag.out 2>&1
    exit 0
  fi
  echo "round $round: no repro ($(($(wc -l < /tmp/repro-reload.csv)-1)) cold starts)" >> /tmp/autotest3.log
done
echo "### no reproduction in 120 cold starts" > /tmp/latchdiag.out
