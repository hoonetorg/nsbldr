#!/bin/bash
# image contents: pinned versions, base image untouched except for the listed additions,
# EE plumbing kept, CLIs and tools usable
source "$(dirname "$0")/common.sh"
req=$REPO_DIR/requirements/requirements.txt
col=$REPO_DIR/requirements/collections.yml
"$CONTAINER_ENGINE" image inspect "$BASE_IMAGE" >/dev/null 2>&1 || "$CONTAINER_ENGINE" pull -q "$BASE_IMAGE" >/dev/null

core_pin=$(sed -n 's/^ansible-core==\([^ ]*\).*/\1/p' "$req")
equal "ansible-core is the pinned version" "$core_pin" "$(in_img "$IMAGE" "python3 -c 'import ansible.release as r; print(r.__version__)'")"
equal "python is 3.12" "3.12" "$(in_img "$IMAGE" "python3 -c 'import sys; print(\"%d.%d\" % sys.version_info[:2])'")"
check "ansible-runner present" in_img "$IMAGE" "ansible-runner --version"

# EE plumbing: the whole image config (entrypoint, cmd, user, workdir, env, labels, ...) as in the base image
cfg() { "$CONTAINER_ENGINE" image inspect "$1" --format '{{json .Config}}' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), sort_keys=True))'; }
if [ "$(cfg "$BASE_IMAGE")" = "$(cfg "$IMAGE")" ]; then ok "image config identical to the base image"
else bad "image config differs from the base image: $(diff <(cfg "$BASE_IMAGE" | python3 -m json.tool) <(cfg "$IMAGE" | python3 -m json.tool) | head -10 | tr '\n' ' ')"; fi

# python packages: nothing removed, changes only for packages named in requirements.txt
in_img "$BASE_IMAGE" "python3 -m pip freeze" > "$WORK_DIR/pip.base"
in_img "$IMAGE" "python3 -m pip freeze" > "$WORK_DIR/pip.image"
if out=$(python3 - "$WORK_DIR/pip.base" "$WORK_DIR/pip.image" "$req" <<'PY'
import re, sys
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
def pkgs(f):
    d = {}
    for l in open(f):
        l = l.strip()
        if l and not l.startswith("#"):
            d[norm(re.split(r"\s*(==| @ )", l)[0])] = l
    return d
base, img = pkgs(sys.argv[1]), pkgs(sys.argv[2])
allowed = {norm(re.split(r"[\s=<>@;#]", l.strip())[0]) for l in open(sys.argv[3]) if l.strip() and not l.lstrip().startswith("#")}
removed = sorted(set(base) - set(img))
changed = sorted(n for n in img if base.get(n) != img[n])
unexpected = [n for n in changed if n not in allowed]
print("changed:", ", ".join(changed))
if removed: print("removed:", removed)
if unexpected: print("not in requirements.txt:", unexpected)
sys.exit(1 if removed or unexpected else 0)
PY
); then ok "pip: only requirements.txt packages differ from base ($out)"; else bad "pip: $out"; fi

# collections: base collections unchanged, collections.yml ones at their pins
coll() { in_img "$1" "ansible-galaxy collection list --format json" | python3 -c '
import json, sys
d = {}
for path in json.load(sys.stdin).values():
    for n, v in path.items(): d.setdefault(n, v["version"])
print("\n".join(f"{n} {v}" for n, v in sorted(d.items())))'; }
coll "$BASE_IMAGE" > "$WORK_DIR/coll.base"
coll "$IMAGE" > "$WORK_DIR/coll.image"
missing=$(comm -23 "$WORK_DIR/coll.base" "$WORK_DIR/coll.image" | tr '\n' ' ')
[ -z "$missing" ] && ok "collections of the base image unchanged" || bad "base collections changed/missing: $missing"
while read -r n v; do
  equal "collection $n pinned" "$n $v" "$(grep "^$n " "$WORK_DIR/coll.image" || echo "$n missing")"
done < <(python3 -c 'import sys, yaml; [print(c["name"], c["version"]) for c in yaml.safe_load(open(sys.argv[1]))["collections"] if "version" in c]' "$col")

# CLIs and tools
for c in "awx --version" "ascender --version" "kubectl version --client" "oc version --client"; do
  check "CLI runs: $c" in_img "$IMAGE" "$c"
done
for b in ssh scp sftp sshpass rsync git shred nsbldr-init ctlenv update-ca-trust openssl; do check "tool: $b" in_img "$IMAGE" "command -v $b"; done
# network_cli (RouterOS): resolved like the plugins do it with nsbldr's ansible.cfg (cwd /nsbldr, like cnsbldr):
# transport libssh (core 2.21 has no paramiko connection), libssh without key lookup (password auth)
net=$(ctr --user root -w /nsbldr -e ANSIBLE_LOG_PATH=/dev/null --entrypoint python3 "$IMAGE" -c '
from ansible.plugins.loader import connection_loader, init_plugin_loader
init_plugin_loader()
from ansible.playbook.play_context import PlayContext
pc = PlayContext(); pc.network_os = "community.routeros.routeros"
n = connection_loader.get("ansible.netcommon.network_cli", pc, new_stdin=None)  # as task_executor does
n.set_options()
c = connection_loader.get("ansible.netcommon.libssh", PlayContext())
c.set_options()
print(n.ssh_type, c.get_option("look_for_keys"))' 2>/dev/null | tail -1)
equal "network_cli ssh transport" "libssh" "${net% *}"
equal "libssh look_for_keys from nsbldr's ansible.cfg" "False" "${net#* }"
for m in paramiko xmltodict netaddr awxkit ascenderkit pylibsshext; do check "python module: $m" in_img "$IMAGE" "python3 -c 'import $m'"; done
finish
