# Nsbldr

Used for building a container containing Ansible. 

Container can be built, exported, imported with script

Ansible can be run interactively in Container. 

Global config files for defining locations of roles, playbooks etc.

Host config files for defining locations of inventories files etc.

## Logs

The container runs with `--log-driver=none`: podman keeps no copy of its output (podman's default would put
everything shown on screen into the journal, e.g. decrypted vault values from `ansible-inventory`, also after
`--rm`). Ansible's own logs are configured in `src/ansible.cfg` (`log_path`, per-host `log_plays` in the logs
dir); switch them off for a single command with
`ANSIBLE_LOG_PATH=/dev/null ANSIBLE_CALLBACKS_ENABLED=ansible.posix.timer` (an empty `ANSIBLE_CALLBACKS_ENABLED=` crashes
`ansible-playbook`; `ansible-inventory` only needs `ANSIBLE_LOG_PATH=/dev/null`).

## Large files

`ansiblelargefilesdir` (required, in the environment's hostconf next to `ansiblefilesdir`): a host directory
for large files (downloads, installers, ISOs, later local package repos) that don't belong into the
git-managed input dirs. It is mounted to `/srv/ansible/largefiles` in the container and packed into the
encrypted bundle (`largefiles/`), so a bundle on a stick carries everything needed offline. With
`--workspace-root` it is `<workspace_root>/largefiles`.

```json
"ansiblelargefilesdir": "/srv/work/nsbldr/ano-ansiblelargefiles"
```

One directory per environment keeps environments apart, e.g.
`/srv/work/nsbldr/secretenv2-ansiblelargefiles/desktops-vienna` and `.../desktops-newyork`.

## Ansible and content

- ansible-core 2.21 (Python 3.12): targets with Python 3.9 - 3.14, maintained until Nov 2027
- collections for desktop and network automation (community.general, community.crypto, ansible.posix,
  ansible.utils, ansible.netcommon, community.routeros) and for configuring automation platforms
  (projects, inventories, job templates, workflows as code)
- network devices (`network_cli`, e.g. RouterOS): ssh via libssh (`ansible-pylibssh`), ansible-core
  2.21 has no paramiko connection anymore; password auth without trying keys:
  `[libssh_connection] look_for_keys = False` in `src/ansible.cfg`
- CLIs: `awx` and the platform CLIs listed in `requirements/requirements.txt`, `kubectl`, `oc`
  (e.g. in `--interactive`)
- AAP's own CLI and collections need a subscription: optional hooks in `Containerfile` and
  `requirements/collections.yml`
- everything is pinned (`Containerfile` ARGs, `requirements/`); nothing changes without changing a pin

## Two modes, same results

- standalone with `cnsbldr` (config files, mapped folders), as before
- as execution environment in an automation platform: the image keeps the execution environment's
  entrypoint, user and ansible-runner, so it can be registered there and runs the same playbooks with
  the same Ansible. `tests/standalone-vs-ee.sh` checks that both modes give the same task results.

## Image name: `--image`

`--image NAME[:TAG]` (default `nsbldr`) is used by `--build`, `--export-image` and for running. The
container name follows the image (`nsbldr:test` -> `nsbldr-test`), so different images can run side
by side.

```
./cnsbldr --image nsbldr:test --build
./cnsbldr --image nsbldr:test --export-image ~/nsbldr-test.ctr
```

## Other commands: `--entrypoint`

Default is `ansible-playbook` (always passed explicitly, the image keeps the execution environment's
entrypoint); all other arguments are passed through as before. For other commands a tty is only
allocated when attached to a terminal, so output can be piped.

```
./cnsbldr --entrypoint ansible --version
./cnsbldr --entrypoint ansible-doc <collection>.<module>
./cnsbldr --entrypoint awx projects list -f human
./cnsbldr --entrypoint kubectl get pods -n <namespace>
```

## Automation platform access

Optional keys in the host config file. Mounted read-only, never packed by `--encrypt-content`:

```json
"controllerconfigfile": "~/.config/nsbldr/platform.cfg",
"kubeconfigfile": "~/.config/nsbldr/kubeconfig",
"cacerts": ["~/.config/nsbldr/customer-ca.crt", "~/.config/nsbldr/cas/"]
```

- `controllerconfigfile`: platform connection, mounted as `~/.tower_cli.cfg` and
  `~/.controller_cli.cfg` (the platform collections read one or the other)

  ```ini
  [general]
  host = https://platform.example.internal
  oauth_token = xxxxx          # or username / password
  verify_ssl = true            # false only for test servers
  ```

- `kubeconfigfile`: kubeconfig for `kubectl` / `oc` (CA or `insecure-skip-tls-verify` per cluster in
  the file). Without it, `oc login` in `--interactive` keeps its token only in the container.
- `cacerts`: CA certificate files and/or directories (`*.crt`, `*.pem`), e.g. internal CAs. They are
  added to the container's trust store at start, the public CAs stay. All tools use the merged store
  (Ansible incl. platform modules, curl, git, kubectl/oc without CA in the kubeconfig, platform CLIs).
  Independent of the trust store of the machine you run cnsbldr on.

Which tool reads what:

| tool | connection | CA |
|---|---|---|
| platform modules (playbooks) | `controllerconfigfile` or `CONTROLLER_*` env | system trust store (+ `cacerts`), `verify_ssl` |
| platform CLIs (`awx`, ...) | `CONTROLLER_*` env only, set from `controllerconfigfile` at start | system trust store (+ `cacerts`), `verify_ssl` |
| `kubectl`, `oc` | `kubeconfigfile` | kubeconfig, else system trust store (+ `cacerts`) |

With `controllerconfigfile`, the container runs the command (or the `--interactive` shell) through
`ctlenv`: it sets the `CONTROLLER_*` variables from the config file once at start, for everything started
there, and prints nothing. After changing the file, start the container again. The old form
`--entrypoint ctlenv <command>` still works. The `awx` CLI uses username / password (no token), other platform CLIs also
the token.

`CONTROLLER_HOST`, `CONTROLLER_USERNAME`, `CONTROLLER_PASSWORD`, `CONTROLLER_OAUTH_TOKEN`,
`CONTROLLER_TOKEN` and `CONTROLLER_VERIFY_SSL` set on the host are passed into the container by name,
so the values are not in the logged podman command - but visible in `podman inspect` while the
container runs. The config file is the better way.

Read-only smoke test: `examples/controller/ping.yml` (copy it into the playbooks dir).

### Encrypted access files

`controllerconfigfile` and `kubeconfigfile` may be encrypted with `ansible-vault encrypt`, e.g. to keep them
in git. Then the container asks once at start for the vault password:

- the password and the decrypted files stay in a tmpfs in the container (RAM only, gone when it stops);
  the files are linked where the tools look for them
- `ansible-playbook` and `ansible-vault` use the same password (`ANSIBLE_VAULT_PASSWORD_FILE`): encrypt
  the inventory vault files with it too and drop `--ask-vault-password` from `ansiblecommand`
- `--interactive`: one prompt, then all commands in the shell run without further prompts
- needs a terminal; without one (cron, `< /dev/null`) the container stops with an error. With a
  terminal, output piped to another command has `\r\n` line endings
- a vault password stored on the platform as a Vault credential should not be this password: whoever can
  use that credential could decrypt the access files

## Secrets

- cnsbldr runs every container with `--log-driver=none`: no container output in the journal or
  `podman logs`; podman events record no arguments, environment or output
- the platform modules hide password and token (`no_log`), also with `-vvv`; `tests/secrets.sh` checks
  that no credential shows up in any output or log
- still logged by Ansible (`log_path`, per-host `log_plays`): whatever a playbook prints - `debug` of
  secrets, `--diff` of files with secrets, `ansible-inventory` output (decrypted vault values)
- no secrets as command line arguments (`--conf.password`, `oc login -p`, `-e password=...`): cnsbldr
  prints the podman command including them, `ps` shows them
- no secrets via `export X=value` in the shell (history); `read -rs X; export X` or the config file
- no high verbosity with real credentials (`awx -v`, `kubectl -v=8` and higher)
- prefer personal tokens with limited rights and expiry over admin passwords

## Rootless podman with domain users

Domain users usually have no `/etc/subuid` range. Podman then warns and uses a single UID mapping
(container root = your user), which is fine for this image. For full mappings an admin adds
`<user>:100000:65536` to `/etc/subuid` and `/etc/subgid`, then runs `podman system migrate`.

## Tests

`tests/run.sh` - see [tests/README.md](tests/README.md).
