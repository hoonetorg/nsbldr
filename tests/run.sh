#!/bin/bash
# runs all nsbldr tests; result: $WORK_DIR/summary.txt, logs: $WORK_DIR/logs/; exit code 0 = all OK
source "$(dirname "$0")/common.sh"
"$CONTAINER_ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image $IMAGE missing, build it first: ./cnsbldr --image ${IMAGE#localhost/} --build"; exit 1; }
rm -rf "$WORK_DIR/logs"; mkdir -p "$WORK_DIR/logs"
: > "$WORK_DIR/summary.txt"
rc=0
for t in cnsbldr image platform smoke standalone-vs-ee cacerts secrets; do
  case $t in
    cnsbldr) cmd=(python3 "$TESTS_DIR/test_cnsbldr.py" -v) ;;
    *)       cmd=(bash "$TESTS_DIR/$t.sh") ;;
  esac
  start=$SECONDS
  if "${cmd[@]}" > "$WORK_DIR/logs/$t.log" 2>&1; then res=OK; else res=FAIL; rc=1; fi
  printf '%-4s %-18s %3ss  logs/%s.log\n' "$res" "$t" $((SECONDS - start)) "$t" | tee -a "$WORK_DIR/summary.txt"
  [ $res = FAIL ] && grep -E '^(FAIL|ERROR|AssertionError)|^FAIL:' "$WORK_DIR/logs/$t.log" | head -10 | sed 's/^/       /'
done
echo "image: $IMAGE" >> "$WORK_DIR/summary.txt"
exit $rc
