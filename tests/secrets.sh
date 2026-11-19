#!/bin/bash
# platform credentials must never show up in cnsbldr's output, the screen output of the tools, Ansible's
# logs (log_path, log_plays), podman events or the journal - for playbooks against the platform (-vvv,
# credentials from the config file and from env), the platform CLIs through ctlenv, kubectl/oc with a
# kubeconfig, and the same with ansible-vault encrypted access files (vault password typed on a terminal). The "platform" is a closed port on 127.0.0.1: connections are refused, nothing is sent.
# Negative control: a playbook that prints the password must be detected.
source "$(dirname "$0")/common.sh"
W=$WORK_DIR/secrets
rm -rf "$W"; mkdir -p "$W/out"
rnd() { echo "$1-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"; }
PW=$(rnd pw); TOKEN=$(rnd tok); ENVPW=$(rnd envpw); KUBETOKEN=$(rnd kube); VPW=$(rnd vpw)
port=$(free_port); host=https://127.0.0.1:$port
since=$(date +%s)

printf '[general]\nhost = %s\nusername = admin\npassword = %s\nverify_ssl = false\n' "$host" "$PW" > "$W/pw.cfg"
printf '[general]\nhost = %s\noauth_token = %s\nverify_ssl = false\n' "$host" "$TOKEN" > "$W/token.cfg"
cat > "$W/kubeconfig" <<KUBE
apiVersion: v1
kind: Config
clusters: [{name: t, cluster: {server: "$host", insecure-skip-tls-verify: true}}]
users: [{name: t, user: {token: "$KUBETOKEN"}}]
contexts: [{name: t, context: {cluster: t, user: t}}]
current-context: t
KUBE
chmod 600 "$W"/*.cfg "$W/kubeconfig"
mkdir -p "$W/enc"; cp "$W/pw.cfg" "$W/enc/pw.cfg"; cp "$W/kubeconfig" "$W/enc/kubeconfig"
vault_encrypt "$VPW" "$W/enc/pw.cfg" "$W/enc/kubeconfig"

mk_ws "$W/ws-pw" "{\"controllerconfigfile\": \"$W/pw.cfg\", \"kubeconfigfile\": \"$W/kubeconfig\"}"
mk_ws "$W/ws-token" "{\"controllerconfigfile\": \"$W/token.cfg\"}"
mk_ws "$W/ws-env"
mk_ws "$W/ws-vault" "{\"controllerconfigfile\": \"$W/enc/pw.cfg\", \"kubeconfigfile\": \"$W/enc/kubeconfig\"}"
for ws in ws-pw ws-token ws-env ws-vault; do
  for c in awx.awx ctrliq.ascender; do
    sed -e "s/^    - awx.awx$/    - $c/" -e "s/^    ctl: awx.awx$/    ctl: $c/" "$REPO_DIR/examples/controller/ping.yml" > "$W/$ws/playbooks/ping-$c.yml"
  done
  printf -- '- hosts: localhost\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug:\n        msg: "{{ lookup(\x27env\x27, \x27CONTROLLER_PASSWORD\x27) }}"\n' > "$W/$ws/playbooks/leak.yml"
done

run() {  # run <name> <workspace> <cnsbldr args...>: output (stdout+stderr incl. cnsbldr's log) to out/<name>
  local n=$1 ws=$2; shift 2
  cn "$W/$ws" "$@" > "$W/out/$n" 2>&1 < /dev/null || true
}
pb=/srv/ansible/playbooks
for c in awx.awx ctrliq.ascender; do
  run "playbook-file-pw-$c"    ws-pw    -vvv "$pb/ping-$c.yml"
  run "playbook-file-token-$c" ws-token -vvv "$pb/ping-$c.yml"
  CONTROLLER_HOST=$host CONTROLLER_USERNAME=admin CONTROLLER_PASSWORD=$ENVPW CONTROLLER_VERIFY_SSL=false \
    run "playbook-env-$c" ws-env -vvv "$pb/ping-$c.yml"
done
run cli-awx-pw          ws-pw    --entrypoint ctlenv awx projects list
run cli-ascender-pw     ws-pw    --entrypoint ctlenv ascender projects list
run cli-ascender-token  ws-token --entrypoint ctlenv ascender projects list
run kubectl             ws-pw    --entrypoint kubectl get pods -v=6
run oc                  ws-pw    --entrypoint oc get pods
runpw() {  # like run, on a terminal with the vault password typed at the prompt
  local n=$1 ws=$2; shift 2
  withpw "$VPW" "$REPO_DIR/cnsbldr" --image "${IMAGE#localhost/}" --globalconffile "$W/$ws/nsbldr.json" \
    --hostconffile "$W/$ws/host.json" "$@" > "$W/out/$n" 2>&1 || true
}
runpw vault-playbook     ws-vault -vvv "$pb/ping-awx.awx.yml"
runpw vault-cli-awx      ws-vault --entrypoint awx projects list
runpw vault-kubectl      ws-vault --entrypoint kubectl get pods -v=6
sleep 1
"$CONTAINER_ENGINE" events --since "$since" --until "$(date +%s)" --stream=false --format json > "$W/out/podman-events" 2>/dev/null || true
journalctl --user --since "@$since" -o cat > "$W/out/journal-user" 2>/dev/null || true

# the runs really reached the point where credentials are used (refused connection to the fake platform)
for f in playbook-file-pw-awx.awx playbook-file-token-ctrliq.ascender playbook-env-awx.awx cli-awx-pw cli-ascender-token kubectl oc \
         vault-playbook vault-cli-awx vault-kubectl; do
  if grep -qiE "refused|127\.0\.0\.1:$port|connect" "$W/out/$f"; then ok "run $f tried the platform"; else bad "run $f did not try the platform: $(tail -2 "$W/out/$f" | tr '\n' ' ')"; fi
done

# no secret anywhere
for s in PW TOKEN ENVPW KUBETOKEN VPW; do
  hits=$( (grep -rlF -- "${!s}" "$W/out" "$W"/ws-*/logs 2>/dev/null || true) | sed "s|$W/||" | tr '\n' ' ')
  [ -z "$hits" ] && ok "secret $s not found in any output or log" || bad "secret $s found in: $hits"
done

# negative control: a playbook printing the password must be found by the same search
# (with nsbldr's ansible.cfg, ok results go to the per-host log_plays log, not to the screen/ansible.log)
LEAK=$(rnd leak)
CONTROLLER_PASSWORD=$LEAK run leak ws-env "$pb/leak.yml"
hits=$( (grep -rlF -- "$LEAK" "$W/out" "$W"/ws-*/logs 2>/dev/null || true) | sed "s|$W/||" | tr '\n' ' ')
[ -n "$hits" ] && ok "negative control: printed password detected ($hits)" || bad "negative control: printed password not detected"
finish
