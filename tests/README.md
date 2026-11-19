# Tests for nsbldr

Tests of nsbldr itself: `cnsbldr` and the image. Plain bash plus a stdlib Python unittest; the exit
code is the result (0 = all OK). Tests of roles and playbooks live in their own repos.

```bash
./cnsbldr --image nsbldr:<tag> --build          # build first
IMAGE=localhost/nsbldr:<tag> tests/run.sh       # all tests (default IMAGE: see common.sh)
bash tests/image.sh                             # a single test
python3 tests/test_cnsbldr.py -v                # unit tests only, no podman needed
```

| test | checks | needs | time |
|---|---|---|---|
| `test_cnsbldr.py` | podman commands composed by `cnsbldr`: default use and `--interactive` as fixed expected commands (what the existing runs rely on); `--image` / container name, `--entrypoint` + tty, platform access files (`controllerconfigfile` as both config names, `kubeconfigfile`, `cacerts` files/dirs with `nsbldr-init` in front of the command, missing files are errors), `CONTROLLER_*` passed by name only (values never in the command), `--encrypt-content` does not pack the access keys | python3 | <1 s |
| `cnsbldr-py39` (in `run.sh`) | `cnsbldr --help` and `test_cnsbldr.py` with python3.9 (EL9 host python, taken from the nsbldr image): type hints that need 3.10+ (`X \| None`) must be quoted | nsbldr image | <1 s |
| `image.sh` | ansible-core = pin, Python 3.12, ansible-runner; the whole image config (entrypoint, cmd, user, workdir, env, labels) as in the base image; Python packages: none removed, only `requirements.txt` ones changed; base collections unchanged, `collections.yml` ones at their pins; CLIs `awx`, platform CLI, `kubectl`, `oc` run; tools (incl. `nsbldr-init`, `ctlenv`) and Python modules present; `network_cli` resolves to the libssh transport and libssh to `look_for_keys = False` from nsbldr's `ansible.cfg` | podman, base image (pulled if missing) | ~10 s |
| `platform.sh` | `examples/controller/ping.yml` syntax, module docs of the platform collections, the CLIs use `CONTROLLER_HOST` (no network: `--network=none`, host `*.invalid`); `ctlenv` takes the connection from the config file (comments before `[general]`, a file without section header, both config names) and names no values when rejecting a broken file; ansible-vault encrypted `platform.cfg` / kubeconfig: one prompt (terminal via `withpw.py`), decrypted into a tmpfs and linked, `CONTROLLER_*` without `ctlenv`, inventory vault value decrypted with the same password, wrong password and no terminal fail | podman | ~10 s |
| `smoke.sh` | standalone run with the production settings of `src/ansible.cfg`: `log_path`, per-host `log_plays`, `timer`; no collection/ansible-core version warnings, no errors | podman | ~5 s |
| `cacerts.sh` | own CA certificates (host config `cacerts`, through `cnsbldr`): a server certificate signed by a throwaway CA is rejected without `cacerts` and trusted with it by curl, Ansible `uri` and Python requests (platform CLIs); public CAs stay in the trust store | podman | ~10 s |
| `secrets.sh` | random password / token / kubeconfig token never show up in `cnsbldr`'s output, the tools' output, `ansible.log`, per-host logs, podman events or the journal: playbooks with both platform collections at `-vvv` (credentials from the config file and from env), platform CLIs through `ctlenv`, `kubectl -v=6`, `oc`, the same with encrypted access files and the vault password; the fake platform is a closed port on 127.0.0.1 (nothing is sent); negative control: a playbook printing the password is detected | podman | ~40 s |
| `standalone-vs-ee.sh` | the sample playbook gives the same task results (status per task and host, debug values, recap) when started like `cnsbldr` does (root, `ansible-playbook`, nsbldr's `ansible.cfg`) and when started like an automation platform does (the image's own entrypoint and user, `ansible-runner` with a private data dir, results from runner's job events); negative check: an extra var in one mode only must be detected | podman | ~10 s |

The EE mode uses `ansible-runner run`; a platform uses `ansible-runner worker` fed through its
job queue - same runner, same event stream, but not the platform itself. Running the image as
execution environment in a real platform is a separate, manual test.

## Files

- `common.sh`: settings (`IMAGE`, `BASE_IMAGE` from the `Containerfile`, `CONTAINER_ENGINE`, `WORK_DIR`)
  and helpers
- `withpw.py`: runs a command on a terminal and types the vault password at the prompt
- `fixtures/project/sample.yml`, `fixtures/inventory/hosts`: generic sample run against the container
  itself (facts, file, template, ini_file, collection filters, assert, a task skipped by default)
- `compare_results.py`: compares `ansible.posix.json` output with ansible-runner job events

## Results

`WORK_DIR` (default `/var/tmp/nsbldr-tests`): `summary.txt`, `logs/<test>.log`, and the run
directories of `smoke` and `standalone-vs-ee`. With rootless podman the EE run leaves files owned by
the container user; `podman unshare rm -rf /var/tmp/nsbldr-tests` removes them.

## Updating pins

1. change the pin (`Containerfile` ARG, `requirements/requirements.txt`, `requirements/collections.yml`)
2. build, then `tests/run.sh`
3. `image.sh` fails if pip changed packages not listed in `requirements.txt`: add them with the
   version from `logs/image.log` / `$WORK_DIR/pip.image` as exact pins
