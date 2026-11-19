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

# ctlenv: CONTROLLER_* from the mounted config file - comments before [general], a file without
# section header; values never in error messages
W=$WORK_DIR/platform; rm -rf "$W"; mkdir -p "$W"
printf '# connection to the platform\n# [general] below\n\n[general]\nhost = https://nsbldr-comments.invalid\noauth_token = c0mm3nt-token\n' > "$W/comments.cfg"
printf 'host = https://nsbldr-nosection.invalid\noauth_token = t0k3n-value\n' > "$W/nosection.cfg"
printf '[general]\nhost = https://x.invalid\npassword = s3cr3t-value\n[broken\n' > "$W/broken.cfg"
envof() { ctr --network=none --user root -v "$W/$1:/root/$2:ro,z" --entrypoint ctlenv "$IMAGE" sh -c 'echo "$CONTROLLER_HOST $CONTROLLER_OAUTH_TOKEN"' 2>&1; }
equal "ctlenv: comments before [general]" "https://nsbldr-comments.invalid c0mm3nt-token" "$(envof comments.cfg .tower_cli.cfg)"
equal "ctlenv: file without section, other config name" "https://nsbldr-nosection.invalid t0k3n-value" "$(envof nosection.cfg .controller_cli.cfg)"
out=$(envof broken.cfg .tower_cli.cfg || true)
if grep -q "not an ini file" <<<"$out" && ! grep -q "s3cr3t-value" <<<"$out"; then ok "ctlenv: broken file rejected, no value in the message"
else bad "ctlenv broken file: $out"; fi

# encrypted access files: one vault password, asked once by nsbldr-init (on a terminal); files decrypted into
# a tmpfs and linked; CONTROLLER_* set without ctlenv; the same password decrypts inventory values
V=$WORK_DIR/vault; rm -rf "$V"; mkdir -p "$V"
VPW=v4ult-pw-test
printf '[general]\nhost = https://nsbldr-vault.invalid\noauth_token = v4ult-token\n' > "$V/platform.cfg"
printf 'apiVersion: v1\nkind: Config\nclusters: [{name: t, cluster: {server: "https://nsbldr-kube.invalid"}}]\nusers: [{name: t, user: {token: x}}]\ncontexts: [{name: t, context: {cluster: t, user: t}}]\ncurrent-context: t\n' > "$V/kubeconfig"
cp "$V/platform.cfg" "$V/plain.cfg"
vault_encrypt "$VPW" "$V/platform.cfg" "$V/kubeconfig"
mk_ws "$V/ws" "{\"controllerconfigfile\": \"$V/platform.cfg\", \"kubeconfigfile\": \"$V/kubeconfig\"}"
mk_ws "$V/ws-plain" "{\"controllerconfigfile\": \"$V/plain.cfg\"}"
for ws in ws ws-plain; do
  printf 'echo "env: $CONTROLLER_HOST $CONTROLLER_OAUTH_TOKEN"\necho "links: $(readlink /root/.tower_cli.cfg /root/.controller_cli.cfg /root/.kube/config | tr "\\n" " ")"\necho "tmpfs: $(findmnt -no FSTYPE /run/nsbldr)"\necho "kube: $(kubectl config view --minify -o jsonpath={.clusters[0].cluster.server} 2>/dev/null)"\n' > "$V/$ws/files/check.sh"
done
printf 'localhost ansible_connection=local\n' > "$V/ws/inventories/hosts"
mkdir -p "$V/ws/inventories/group_vars"
printf '%s\n' "$VPW" | ctr -i --network=none --user root --entrypoint sh "$IMAGE" -c \
  'cat > /tmp/p && ansible-vault encrypt_string --vault-password-file /tmp/p inv-s3cret --name invsecret 2>/dev/null' > "$V/ws/inventories/group_vars/all.yml"
printf -- '- hosts: localhost\n  gather_facts: false\n  tasks:\n    - ansible.builtin.assert:\n        that: invsecret == "inv-s3cret"\n' > "$V/ws/playbooks/vault.yml"

out=$(withpw "$VPW" "$REPO_DIR/cnsbldr" --image "${IMAGE#localhost/}" --globalconffile "$V/ws/nsbldr.json" --hostconffile "$V/ws/host.json" --entrypoint sh /srv/ansible/files/check.sh 2>&1 || true)
grep -q "^env: https://nsbldr-vault.invalid v4ult-token" <<<"$out" && ok "vault: platform.cfg decrypted, CONTROLLER_* set without ctlenv" || bad "vault env: $out"
grep -q "^links: /run/nsbldr/platform.cfg /run/nsbldr/platform.cfg /run/nsbldr/kubeconfig" <<<"$out" && ok "vault: decrypted files linked from the tmpfs" || bad "vault links: $out"
grep -q "^tmpfs: tmpfs" <<<"$out" && ok "vault: /run/nsbldr is a tmpfs" || bad "vault tmpfs: $out"
grep -q "^kube: https://nsbldr-kube.invalid" <<<"$out" && ok "vault: kubeconfig decrypted, kubectl reads it" || bad "vault kube: $out"
[ "$(grep -c 'Vault password:' <<<"$out")" = 1 ] && ok "vault: asked once" || bad "vault prompt count: $out"
if withpw "$VPW" "$REPO_DIR/cnsbldr" --image "${IMAGE#localhost/}" --globalconffile "$V/ws/nsbldr.json" --hostconffile "$V/ws/host.json" \
     -i /srv/ansible/inventories/hosts /srv/ansible/playbooks/vault.yml >"$V/pb.out" 2>&1; then
  ok "vault: inventory value decrypted by ansible-playbook with the same password, no second prompt"
else bad "vault playbook: $(tail -5 "$V/pb.out")"; fi
out=$(withpw wrong-pw "$REPO_DIR/cnsbldr" --image "${IMAGE#localhost/}" --globalconffile "$V/ws/nsbldr.json" --hostconffile "$V/ws/host.json" --entrypoint true 2>&1) && rc=0 || rc=$?
[ "$rc" != 0 ] && grep -qi "decryption failed" <<<"$out" && ok "vault: wrong password fails" || bad "vault wrong password (rc $rc): $out"
out=$(cn "$V/ws" --entrypoint true 2>&1 </dev/null) && rc=0 || rc=$?
[ "$rc" != 0 ] && grep -q "vault password needed but no terminal" <<<"$out" && ok "vault: no terminal fails clearly" || bad "vault no terminal (rc $rc): $out"
out=$(cn "$V/ws-plain" --entrypoint sh /srv/ansible/files/check.sh 2>&1 </dev/null || true)
grep -q "^env: https://nsbldr-vault.invalid v4ult-token" <<<"$out" && grep -q "^tmpfs: $" <<<"$out" && ! grep -q "Vault password" <<<"$out" \
  && ok "plain platform.cfg: no prompt, no tmpfs, CONTROLLER_* set without ctlenv" || bad "plain platform.cfg: $out"
finish
