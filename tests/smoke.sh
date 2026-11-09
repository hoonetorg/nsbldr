#!/bin/bash
# standalone run with the production settings of src/ansible.cfg: log_path, per-host log_plays,
# timer callback; no warnings about collections not supporting the ansible-core version
source "$(dirname "$0")/common.sh"
W=$WORK_DIR/smoke
fx=$TESTS_DIR/fixtures
rm -rf "$W"; mkdir -p "$W/logs"
out=$(ctr --user=root --group-add=root --network=host --entrypoint ansible-playbook -w /nsbldr \
  -v "$fx/project:/srv/ansible/playbooks:ro,z" -v "$fx/inventory:/srv/ansible/inventories:ro,z" -v "$W/logs:/srv/ansible/logs:z" \
  -e ANSIBLE_CALLBACKS_ENABLED=ansible.posix.timer,community.general.log_plays \
  "$IMAGE" -i /srv/ansible/inventories/hosts /srv/ansible/playbooks/sample.yml 2>&1) && ok "playbook run" || bad "playbook run: $(tail -5 <<<"$out")"
echo "$out" > "$W/output.txt"
check "timer callback output" grep -q "Playbook run took" "$W/output.txt"
check "log_path written (logs/ansible.log)" test -s "$W/logs/ansible.log"
check "log_plays per-host log (logs/hosts/localhost)" test -s "$W/logs/hosts/localhost"
if grep -q "does not support Ansible version" "$W/output.txt"; then bad "collection/ansible-core version warning: $(grep -m1 'does not support' "$W/output.txt")"; else ok "no collection version warnings"; fi
if grep -qiE "^\[ERROR\]|Traceback" "$W/output.txt"; then bad "errors in output"; else ok "no errors in output"; fi
finish
