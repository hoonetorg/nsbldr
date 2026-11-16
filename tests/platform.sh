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
finish
