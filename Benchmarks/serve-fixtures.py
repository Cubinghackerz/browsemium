#!/usr/bin/env python3
"""Serve the deterministic benchmark fixtures on localhost.

Usage:
    python3 Benchmarks/serve-fixtures.py [--port 8791]

Keep this process running while a benchmark executes, then stop it with Ctrl-C.
"""

import argparse
import functools
import http.server
import socketserver
from pathlib import Path

FIXTURES = Path(__file__).parent / "Fixtures"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8791)
    args = parser.parse_args()

    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(FIXTURES))
    with socketserver.TCPServer(("127.0.0.1", args.port), handler) as httpd:
        print(f"Serving {FIXTURES} at http://127.0.0.1:{args.port}/")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
