#!/usr/bin/env python3
"""Relay stdin and stdout to a TCP port on 127.0.0.1, for SSH's ProxyCommand.

    relay.py <port>

proxy.sh runs it as the last step, with the port of the target's bastion tunnel. Python rather than
nc or socat because Ansible already needs it, so every machine running this module has it. It
half-closes the connection when SSH closes stdin, and exits when the tunnel closes its side.
"""

import os
import select
import socket
import sys


def main() -> int:
    port = int(sys.argv[1])
    sock = socket.create_connection(("127.0.0.1", port), timeout=30)
    sock.settimeout(None)
    stdin_open = True

    while True:
        watch = [sock, 0] if stdin_open else [sock]
        readable, _, _ = select.select(watch, [], [])

        if 0 in readable:
            data = os.read(0, 65536)
            if data:
                sock.sendall(data)
            else:
                stdin_open = False
                sock.shutdown(socket.SHUT_WR)

        if sock in readable:
            data = sock.recv(65536)
            if not data:
                return 0
            view = memoryview(data)
            while view:
                view = view[os.write(1, view):]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BrokenPipeError, ConnectionResetError, KeyboardInterrupt):
        sys.exit(0)
