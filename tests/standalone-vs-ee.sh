#!/bin/bash
# the same playbook gives the same task results
#   a) standalone: started like cnsbldr does (root, --entrypoint ansible-playbook, -w /nsbldr with nsbldr's
#      ansible.cfg, /srv/ansible mounts)
#   b) EE mode: started like an automation platform does (the image's own entrypoint and user,
#      ansible-runner with a private data dir; results from runner's job events)
# plus a negative check: an extra var in EE mode only must be detected as a difference
source "$(dirname "$0")/common.sh"
W=$WORK_DIR/standalone-vs-ee
fx=$TESTS_DIR/fixtures
cleanup() { [ "$CONTAINER_ENGINE" = podman ] && podman unshare rm -rf "$W" 2>/dev/null; rm -rf "$W"; }
cleanup; mkdir -p "$W/sa-logs"

standalone() {
  ctr --user=root --group-add=root --network=host --entrypoint ansible-playbook -w /nsbldr \
    -v "$fx/project:/srv/ansible/playbooks:ro,z" -v "$fx/inventory:/srv/ansible/inventories:ro,z" \
    -v "$W/sa-logs:/srv/ansible/logs:z" -e ANSIBLE_STDOUT_CALLBACK=ansible.posix.json \
    "$IMAGE" -i /srv/ansible/inventories/hosts /srv/ansible/playbooks/sample.yml > "$W/standalone.json"
}

ee() {  # ee <ident> [extravars-yaml]
  local d=$W/ee-$1
  mkdir -p "$d/env"; cp -r "$fx/project" "$d/project"; cp -r "$fx/inventory" "$d/inventory"
  [ -n "${2:-}" ] && echo "$2" > "$d/env/extravars"
  chmod -R a+rwX "$d"   # the EE runs as its own user (1000)
  # runner writes its artifacts 0700 as the EE user: make them readable for the comparison on the host
  ctr --network=host -v "$d:/runner:z" "$IMAGE" \
    sh -c 'ansible-runner run /runner -p sample.yml --ident run; rc=$?; chmod -R a+rX /runner/artifacts; exit $rc' \
    > "$W/ee-$1.out" 2>&1
}

compare() { python3 "$TESTS_DIR/compare_results.py" "$W/standalone.json" "$W/ee-$1/artifacts/run/job_events"; }

if standalone; then ok "standalone run"; else bad "standalone run failed, see $W/standalone.json"; fi
if ee same; then ok "EE run (ansible-runner)"; else bad "EE run failed: $(tail -5 "$W/ee-same.out")"; fi
if out=$(compare same); then ok "same results standalone vs EE: $out"; else bad "results differ: $out"; fi

ee extra "sample_extra: true" || true
if out=$(compare extra); then bad "negative check: extra var in EE mode not detected ($out)"; else ok "negative check: difference detected"; fi
finish
