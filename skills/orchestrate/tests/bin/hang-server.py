#!/usr/bin/env python3
# Accepts a TCP connection and never responds — simulates an unreachable/hanging push endpoint
# for AC7, bounded from the client side by curl's own --connect-timeout/--max-time (the reporter
# must not add its own longer timeout on top). Prints "PORT <n>" on stdout once listening, then
# blocks forever (killed by the test).
# Usage: hang-server.py <marker-file>
# Touches <marker-file> the moment it accepts a connection, proving the reporter actually
# attempted the push, then never reads/writes/closes — the client hangs until its own timeout.
import socket, sys

marker = sys.argv[1] if len(sys.argv) > 1 else None

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(5)
port = s.getsockname()[1]
print("PORT %d" % port)
sys.stdout.flush()
while True:
    conn, _ = s.accept()
    if marker:
        open(marker, "w").close()
