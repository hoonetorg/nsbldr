#!/usr/bin/env python3
"""withpw.py <password> <command...>: runs the command on a terminal (pty), types the password at the first
"Vault password:" prompt, prints the output (without the password) and exits with the command's exit code."""
import os
import pty
import sys

pw, cmd = sys.argv[1].encode(), sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf, sent = b"", False
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    buf += data
    if not sent and b"Vault password:" in buf:
        os.write(fd, pw + b"\n")
        sent = True
sys.stdout.write(buf.decode(errors="replace").replace("\r\n", "\n"))
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
