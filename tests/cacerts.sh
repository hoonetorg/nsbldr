#!/bin/bash
# own CA certificates from host.json "cacerts" are added to the trust store at container start (nsbldr-init):
# a server certificate signed by a throwaway CA must fail verification without cacerts and be trusted with
# it by curl, Ansible (uri) and Python requests (platform CLIs); the public CAs must stay
source "$(dirname "$0")/common.sh"
W=$WORK_DIR/cacerts
rm -rf "$W"; mkdir -p "$W/pki" "$W/www"
port=$(free_port)
echo ok > "$W/www/ok.txt"

# throwaway CA + server certificate for localhost (openssl of the image, files owned by the invoking user)
ctr --user root -v "$W/pki:/pki:z" --entrypoint sh "$IMAGE" -c '
  cd /pki
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj "/CN=nsbldr test CA" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
  printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\n" > ext.cnf
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 2 -extfile ext.cnf 2>/dev/null
  chmod a+r *' || { bad "creating test CA"; finish; exit; }

srv=nsbldr-cacerts-srv-$$
"$CONTAINER_ENGINE" run -d --rm --log-driver=none --name "$srv" --network=host --user root \
  -v "$W/pki:/pki:ro,z" -v "$W/www:/www:ro,z" --entrypoint python3 "$IMAGE" -c "
import http.server, ssl, functools
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory='/www')
s = http.server.HTTPServer(('127.0.0.1', $port), h)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain('/pki/server.crt', '/pki/server.key')
s.socket = c.wrap_socket(s.socket, server_side=True); s.serve_forever()" >/dev/null
trap '"$CONTAINER_ENGINE" rm -f "$srv" >/dev/null 2>&1' EXIT
sleep 2

probe="
url=https://localhost:$port/ok.txt
curl -fsS -o /dev/null \$url 2>/dev/null; echo curl=\$?
python3 -c \"import requests; requests.get('\$url').raise_for_status()\" 2>/dev/null; echo requests=\$?
ansible localhost -m ansible.builtin.uri -a \"url=\$url\" >/dev/null 2>&1; echo uri=\$?
grep -q 'ISRG Root X1' /etc/pki/tls/certs/ca-bundle.crt; echo publicca=\$?
"
mk_ws "$W/ws-without"
mk_ws "$W/ws-with" "{\"cacerts\": [\"$W/pki/ca.crt\"]}"
without=$(cn "$W/ws-without" --entrypoint sh -c "$probe" 2>/dev/null)
with=$(cn "$W/ws-with" --entrypoint sh -c "$probe" 2>"$W/with.err")

for t in curl requests uri; do
  r=$(sed -n "s/^$t=//p" <<<"$without")
  [ -n "$r" ] && [ "$r" != 0 ] && ok "without cacerts: $t rejects the certificate" || bad "without cacerts: $t did not reject the certificate ($r)"
  equal "with cacerts: $t trusts the certificate" 0 "$(sed -n "s/^$t=//p" <<<"$with")"
done
equal "with cacerts: public CAs still in the system bundle" 0 "$(sed -n 's/^publicca=//p' <<<"$with")"
check "cnsbldr used nsbldr-init with cacerts" grep -q -- "--entrypoint nsbldr-init" "$W/with.err"
finish
