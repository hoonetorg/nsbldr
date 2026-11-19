# sourced by the test scripts (host side)
set -euo pipefail
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$TESTS_DIR")
CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}
IMAGE=${IMAGE:-localhost/nsbldr:latest}
BASE_IMAGE=${BASE_IMAGE:-$(sed -n 's/^ARG BASE_IMAGE=//p' "$REPO_DIR/Containerfile")}
WORK_DIR=${WORK_DIR:-${TMPDIR:-/var/tmp}/nsbldr-tests}
mkdir -p "$WORK_DIR"

ctr() { "$CONTAINER_ENGINE" run --rm --log-driver=none "$@"; }
# shell command in an image as root, stderr dropped
in_img() { local img=$1; shift; ctr --user root --entrypoint sh "$img" -c "$*" 2>/dev/null; }

FAILS=0
ok()   { echo "OK   $*"; }
bad()  { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
# check <description> <command...>: OK if the command succeeds
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# equal <description> <expected> <actual>
equal() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: expected '$2', got '$3'"; fi; }
finish() { [ "$FAILS" -eq 0 ]; }

# mk_ws <dir> [json with extra host.json keys]: a cnsbldr workspace (nsbldr.json, host.json, mapped dirs)
mk_ws() {
  local d=$1 extra=${2:-'{}'}
  mkdir -p "$d"/{inventories,files,largefiles,playbooks,roles,collections,logs}
  printf '{"ansibleplaybooksdir":"%s","ansiblerolesdir":"%s","ansiblecollectionsdir":"%s","ansiblelogsdir":"%s"}\n' \
    "$d/playbooks" "$d/roles" "$d/collections" "$d/logs" > "$d/nsbldr.json"
  python3 -c 'import json,sys; d,extra=sys.argv[1],json.loads(sys.argv[2]); json.dump({"ansibleinventoriesdir":d+"/inventories","ansiblefilesdir":d+"/files","ansiblelargefilesdir":d+"/largefiles","ansiblecommand":"ansible-playbook",**extra}, open(d+"/host.json","w"))' "$d" "$extra"
}
# cn <dir> <cnsbldr args...>: cnsbldr with the workspace <dir> and $IMAGE
cn() { local d=$1; shift; "$REPO_DIR/cnsbldr" --image "${IMAGE#localhost/}" --globalconffile "$d/nsbldr.json" --hostconffile "$d/host.json" "$@"; }
# a TCP port on 127.0.0.1 where nothing listens
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
# vault_encrypt <password> <file...>: ansible-vault encrypt in the image, files replaced (test password via env)
vault_encrypt() {
  local pw=$1 f; shift
  for f in "$@"; do
    VPW=$pw ctr -i --network=none --user root -e VPW --entrypoint sh "$IMAGE" -c \
      'printf "%s\n" "$VPW" > /tmp/p && ansible-vault encrypt --vault-password-file /tmp/p --output - - 2>/dev/null' < "$f" > "$f.enc"
    mv "$f.enc" "$f"
  done
}
# withpw <password> <command...>: the command on a terminal, password typed at the "Vault password:" prompt
withpw() { python3 "$TESTS_DIR/withpw.py" "$@"; }
