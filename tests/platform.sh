#!/bin/bash
# tooling for configuring automation platforms: example playbook, collections docs,
# CLIs read the CONTROLLER_* environment (no network: --network=none, host *.invalid)
source "$(dirname "$0")/common.sh"
check "examples/controller/ping.yml syntax" \
  ctr --user root --entrypoint ansible-playbook -v "$REPO_DIR/examples:/ex:ro,z" "$IMAGE" --syntax-check /ex/controller/ping.yml
for m in awx.awx.project ctrliq.ascender.project awx.awx.workflow_job_template ctrliq.ascender.workflow_job_template; do
  check "module docs: $m" in_img "$IMAGE" "ansible-doc -j $m | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin) else 1)'"
done
for cli in awx ascender; do
  out=$(ctr --network=none --user root -e CONTROLLER_HOST=https://nsbldr-test.invalid -e CONTROLLER_USERNAME=u \
          -e CONTROLLER_PASSWORD=p --entrypoint "$cli" "$IMAGE" -k projects list 2>&1 || true)
  if grep -q "nsbldr-test.invalid" <<<"$out"; then ok "$cli CLI uses CONTROLLER_HOST"; else bad "$cli CLI ignored CONTROLLER_HOST: $(tail -2 <<<"$out")"; fi
done
finish
