"""Measures how steady the backend's UDP gateway answers while the rest of the server is busy.

    python tools/relay_jitter_test.py --backend C:/path/to/server.py [--seconds 20] [--load 8]

It sends a small UDP probe 60 times a second (the same rate as a fight's input) to the gateway,
which answers it from the same loop that carries the fights' packets, and records how long each
answer takes. Meanwhile --load threads hammer the HTTP side (ranking, accounts, the database).
Prints the median, 99th percentile, the worst and the share over 10 / 30 ms, for the server as it is.
Compare two versions of the backend by running it on both.
"""
import argparse
import json
import os
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

PORT = 18097


def call(path, data=None, token=None):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path), data=json.dumps(data).encode() if data is not None else None,
                                 method="POST" if data is not None else "GET")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception:
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", required=True)
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--load", type=int, default=8, help="threads hammering the HTTP side")
    args = ap.parse_args()
    tmp = tempfile.mkdtemp()
    env = dict(os.environ, POKEBRAWL_PORT=str(PORT), POKEBRAWL_DB=os.path.join(tmp, "j.db"), POKEBRAWL_REGISTER_LIMIT="500",
               POKEBRAWL_LEADERBOARD_MIN="0")
    log = open(os.path.join(tmp, "server.log"), "w")
    server = subprocess.Popen([sys.executable, "-u", args.backend], env=env, stdout=log, stderr=subprocess.STDOUT)
    stop = threading.Event()
    requests_done = [0]
    try:
        for _ in range(60):
            if call("/health"):
                break
            time.sleep(0.1)
        tokens = []
        for i in range(20):
            r = call("/register", {"name": "Load%02d" % i, "email": "l%d@t.dev" % i, "password": "secret-%d" % i})
            if r.get("token"):
                tokens.append(r["token"])

        def hammer(k):
            n = 0
            while not stop.is_set():
                tok = tokens[(k + n) % len(tokens)] if tokens else None
                call("/leaderboard?limit=50")
                call("/me", token=tok)
                call("/queue", token=tok)
                call("/login", {"name": "Load%02d" % ((k + n) % 20), "password": "secret-%d" % ((k + n) % 20)})
                n += 1
                requests_done[0] += 4
        threads = [threading.Thread(target=hammer, args=(k,), daemon=True) for k in range(args.load)]
        for t in threads:
            t.start()
        time.sleep(1.0)

        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.5)
        addr = ("127.0.0.1", PORT)
        rtts = []
        lost = 0
        next_t = time.perf_counter()
        end = time.time() + args.seconds
        while time.time() < end:
            t0 = time.perf_counter()
            s.sendto(b"\x04", addr)
            try:
                s.recvfrom(64)
                rtts.append((time.perf_counter() - t0) * 1000.0)
            except socket.timeout:
                lost += 1
            next_t += 1.0 / 60.0
            time.sleep(max(0.0, next_t - time.perf_counter()))
        stop.set()
        rtts.sort()
        n = len(rtts)

        def pct(p):
            return rtts[min(n - 1, int(n * p))]
        print("probes %d (lost %d), HTTP requests meanwhile %d" % (n, lost, requests_done[0]))
        print("median %.2f ms   p99 %.2f ms   p99.9 %.2f ms   worst %.2f ms" % (statistics.median(rtts), pct(0.99), pct(0.999), rtts[-1]))
        print("over 10 ms: %.2f %%   over 30 ms: %.2f %%" % (100.0 * sum(1 for x in rtts if x > 10) / n, 100.0 * sum(1 for x in rtts if x > 30) / n))
    finally:
        stop.set()
        server.terminate()


if __name__ == "__main__":
    main()

