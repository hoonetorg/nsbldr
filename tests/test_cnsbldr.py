#!/usr/bin/env python3
"""Unit tests for cnsbldr (no podman needed): the podman commands it composes - the default use as a fixed
expected command, plus the additions (--image, --entrypoint,
platform access files, env passthrough, encrypt-content)."""

import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True  # no __pycache__ next to cnsbldr / in the repo
REPO = Path(__file__).resolve().parent.parent


def load(path: Path, name: str):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


CN = load(REPO / "cnsbldr", "cnsbldr")

PATHS = dict(
    globalconffile=Path("/cfg/nsbldr.json"),
    hostconffile=Path("/cfg/host.json"),
    ansibleinventoriesdir=Path("/in/inventories"),
    ansiblefilesdir=Path("/in/files"),
    ansibleplaybooksdir=Path("/in/playbooks"),
    ansiblerolesdir=Path("/in/roles"),
    ansiblecollectionsdir=Path("/in/collections"),
    ansiblelogsdir=Path("/in/logs"),
    ansiblelargefilesdir=Path("/in/largefiles"),
)
ARGS = ["-i", "/srv/ansible/inventories/x", "/srv/ansible/playbooks/site.yml"]
CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith(("CONTROLLER_", "TOWER_"))}


def run_cmd(mod, interactive=False, **kw) -> str:
    """playbook() of module mod, returns the podman command it would execute"""
    cmds = []
    with mock.patch.object(mod, "subprocess_run_wrapper", lambda cmd, dryrun=False, **k: cmds.append(cmd)):
        mod.playbook(interactive=interactive, ansiblecommand="x", args=ARGS, **PATHS, **kw)
    assert len(cmds) == 1
    return cmds[0]


class NoTty:
    def isatty(self):
        return False


class Tty:
    def isatty(self):
        return True


# the podman command of the default use, as before the platform additions (only --entrypoint ansible-playbook
# is new); the desktop/RouterOS runs (host.json + --interactive) depend on it
MOUNTS = (
    "-w /nsbldr "
    "-v /cfg/nsbldr.json:/srv/ansible/nsbldr.json:ro,z "
    "-v /cfg/host.json:/srv/ansible/host.json:ro,z "
    "-v /in/inventories:/srv/ansible/inventories:z "
    "-v /in/files:/srv/ansible/files:z "
    "-v /in/largefiles:/srv/ansible/largefiles:z "
    "-v /in/playbooks:/srv/ansible/playbooks:z "
    "-v /in/roles:/srv/ansible/roles:z "
    "-v /in/collections:/srv/ansible/collections:z "
    "-v /in/logs:/srv/ansible/logs:z "
    "nsbldr -i /srv/ansible/inventories/x /srv/ansible/playbooks/site.yml"
)
HEAD = "podman run --pids-limit=-1 --name nsbldr --network=host --user=root --group-add=root --log-driver=none --rm "


@mock.patch.dict(os.environ, CLEAN_ENV, clear=True)
class TestDefaultCommand(unittest.TestCase):
    """default use: exactly this podman command"""

    def test_default(self):
        self.assertEqual(run_cmd(CN), HEAD + "--entrypoint ansible-playbook " + MOUNTS)

    def test_interactive(self):
        self.assertEqual(run_cmd(CN, interactive=True), HEAD + "-it --entrypoint /bin/bash " + MOUNTS)


@mock.patch.dict(os.environ, CLEAN_ENV, clear=True)
class TestAdditions(unittest.TestCase):
    def test_image_and_container_name(self):
        cmd = run_cmd(CN, image="nsbldr:ascender-ee")
        self.assertIn("--name nsbldr-ascender-ee ", cmd)
        self.assertIn(" nsbldr:ascender-ee -i ", cmd)

    def test_container_name(self):
        self.assertEqual(CN.container_name("nsbldr"), "nsbldr")
        self.assertEqual(CN.container_name("nsbldr:ascender-ee"), "nsbldr-ascender-ee")
        self.assertEqual(CN.container_name("localhost/x:y"), "x-y")

    def test_entrypoint_no_tty_when_piped(self):
        with mock.patch.object(sys, "stdin", NoTty()), mock.patch.object(sys, "stdout", NoTty()):
            cmd = run_cmd(CN, entrypoint="awx")
        self.assertIn("--rm -i --entrypoint awx ", cmd)

    def test_entrypoint_tty_on_terminal(self):
        with mock.patch.object(sys, "stdin", Tty()), mock.patch.object(sys, "stdout", Tty()):
            cmd = run_cmd(CN, entrypoint="awx")
        self.assertIn("--rm -it --entrypoint awx ", cmd)

    def test_interactive_wins_over_entrypoint(self):
        cmd = run_cmd(CN, interactive=True, entrypoint="awx")
        self.assertIn("-it --entrypoint /bin/bash ", cmd)
        self.assertNotIn("--entrypoint awx", cmd)

    def test_config_and_kubeconfig_mounts(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = Path(d) / "tower_cli.cfg"
            kube = Path(d) / "kubeconfig"
            cfg.write_text("[general]\n")
            kube.write_text("apiVersion: v1\n")
            mounts = CN.get_optional_mounts({"controllerconfigfile": str(cfg), "kubeconfigfile": str(kube)})
            cmd = run_cmd(CN, optionalmounts=mounts)
        self.assertIn(f"-v {cfg}:/root/.tower_cli.cfg:ro,z ", cmd)
        self.assertIn(f"-v {cfg}:/root/.controller_cli.cfg:ro,z ", cmd)
        self.assertIn(f"-v {kube}:/root/.kube/config:ro,z ", cmd)
        # plain files: init wrapper (runs the command through ctlenv), no tmpfs, no tty
        self.assertIn("--rm --entrypoint nsbldr-init ", cmd)
        self.assertNotIn("--tmpfs", cmd)

    def test_encrypted_access_files(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = Path(d) / "platform.cfg"
            kube = Path(d) / "kubeconfig"
            cfg.write_text("$ANSIBLE_VAULT;1.1;AES256\n6162\n")
            kube.write_text("apiVersion: v1\n")
            mounts = CN.get_optional_mounts({"controllerconfigfile": str(cfg), "kubeconfigfile": str(kube)})
            self.assertEqual(mounts, [(cfg, "/srv/ansible/access/platform.cfg"), (kube, "/root/.kube/config")])
            with mock.patch.object(sys, "stdin", Tty()), mock.patch.object(sys, "stdout", NoTty()):
                default = run_cmd(CN, optionalmounts=mounts)
                piped = run_cmd(CN, optionalmounts=mounts, entrypoint="awx")
            with mock.patch.object(sys, "stdin", NoTty()), mock.patch.object(sys, "stdout", NoTty()):
                notty = run_cmd(CN, optionalmounts=mounts)
            interactive = run_cmd(CN, interactive=True, optionalmounts=mounts)
        tmpfs = "--tmpfs /run/nsbldr:rw,mode=0700,noexec,nosuid,nodev "
        # a terminal for the password prompt whenever stdin is one
        self.assertIn("--rm -it --entrypoint nsbldr-init " + tmpfs, default)
        self.assertIn("--rm -it --entrypoint nsbldr-init " + tmpfs, piped)
        self.assertIn("--rm --entrypoint nsbldr-init " + tmpfs, notty)
        self.assertIn("--rm -it --entrypoint nsbldr-init " + tmpfs, interactive)
        self.assertIn(f"-v {cfg}:/srv/ansible/access/platform.cfg:ro,z ", default)
        self.assertNotIn("/root/.tower_cli.cfg", default)

    def test_cacerts_files_and_dirs(self):
        with tempfile.TemporaryDirectory() as d:
            one = Path(d) / "one.crt"
            cadir = Path(d) / "cas"
            cadir.mkdir()
            for f in (one, cadir / "b.pem", cadir / "a.crt", cadir / "ignored.txt"):
                f.write_text("x")
            mounts = CN.get_optional_mounts({"cacerts": [str(one), str(cadir)]})
            anchors = "/etc/pki/ca-trust/source/anchors"
            self.assertEqual(mounts, [
                (one, f"{anchors}/nsbldr-1-one.crt"),
                (cadir / "a.crt", f"{anchors}/nsbldr-2-a.crt"),
                (cadir / "b.pem", f"{anchors}/nsbldr-3-b.pem"),
            ])
            self.assertEqual(CN.get_optional_mounts({"cacerts": str(one)}), [(one, f"{anchors}/nsbldr-1-one.crt")])
            with mock.patch.object(sys, "stdin", NoTty()), mock.patch.object(sys, "stdout", NoTty()):
                default = run_cmd(CN, optionalmounts=mounts)
                other = run_cmd(CN, optionalmounts=mounts, entrypoint="ctlenv")
            interactive = run_cmd(CN, interactive=True, optionalmounts=mounts)
        self.assertIn(f"-v {one}:{anchors}/nsbldr-1-one.crt:ro,z ", default)
        # init wrapper runs first, the real command becomes its first argument
        self.assertIn("--rm --entrypoint nsbldr-init ", default)
        self.assertTrue(default.endswith(" nsbldr ansible-playbook " + " ".join(ARGS)), default)
        self.assertIn("--rm -i --entrypoint nsbldr-init ", other)
        self.assertTrue(other.endswith(" nsbldr ctlenv " + " ".join(ARGS)), other)
        self.assertIn("--rm -it --entrypoint nsbldr-init ", interactive)
        self.assertTrue(interactive.endswith(" nsbldr /bin/bash " + " ".join(ARGS)), interactive)

    def test_optional_mounts_absent_or_missing(self):
        self.assertEqual(CN.get_optional_mounts({}), [])
        for hostconf in (
            {"controllerconfigfile": "/nonexistent/tower_cli.cfg"},
            {"kubeconfigfile": "/nonexistent/kubeconfig"},
            {"cacerts": ["/nonexistent/ca.crt"]},
        ):
            with self.assertRaises(FileNotFoundError):
                CN.get_optional_mounts(hostconf)
        with tempfile.TemporaryDirectory() as d, self.assertRaises(FileNotFoundError):
            CN.get_optional_mounts({"cacerts": d})  # directory without certificates

    def test_env_passthrough_by_name_only(self):
        env = {"CONTROLLER_HOST": "https://platform.invalid", "CONTROLLER_PASSWORD": "s3cr3t-value"}
        with mock.patch.dict(os.environ, env):
            cmd = run_cmd(CN)
        self.assertIn("-e CONTROLLER_HOST ", cmd)
        self.assertIn("-e CONTROLLER_PASSWORD ", cmd)
        self.assertNotIn("s3cr3t-value", cmd)
        self.assertNotIn("platform.invalid", cmd)
        self.assertNotIn("-e CONTROLLER_USERNAME", cmd)


class TestEncryptContent(unittest.TestCase):
    def test_platform_access_keys_not_packed(self):
        globalconf = {
            "ansibleplaybooksdir": "/p", "ansiblerolesdir": "/r",
            "ansiblecollectionsdir": "/c", "ansiblelogsdir": "/l",
        }
        hostconf = {
            "ansibleinventoriesdir": "/i", "ansiblefilesdir": "/f", "ansiblelargefilesdir": "/lf",
            "ansiblecommand": "ansible-playbook site.yml",
            "controllerconfigfile": "~/.tower_cli.cfg", "kubeconfigfile": "~/.kube/config",
            "cacerts": ["/etc/customer-ca.crt"],
        }
        packed = {}

        def fake_tar(outfile, globalconffile, hostconffile, globalconf, hostconf):
            packed["host"] = json.loads(Path(hostconffile).read_text())

        with mock.patch.object(CN, "find_gpg_binary", lambda: "/bin/true"), \
             mock.patch.object(CN, "create_workspace_tar_from_runtime", fake_tar), \
             mock.patch.object(CN, "subprocess_run_wrapper", lambda *a, **k: None), \
             tempfile.TemporaryDirectory() as d:
            CN.encrypt_content(Path(d) / "out.gpg", Path("/g.json"), Path("/h.json"), globalconf, hostconf)
        self.assertEqual(packed["host"], {"ansiblecommand": "ansible-playbook site.yml"})
        self.assertIn("controllerconfigfile", hostconf, "caller's dict must not be modified")


if __name__ == "__main__":
    unittest.main()
