"""Signs the instance owner's browser in to T3 Code.

T3 Code has its own auth: a browser needs a one-time pairing link before the server will talk to it. Here the router
has already authenticated the owner, so this service mints such a link on request and redirects the browser to it.

It listens on loopback only and is reached through nginx, which lets through nothing but owner requests.
"""

import json
import re
import subprocess
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer

LISTEN_ADDRESS = ("127.0.0.1", 3774)
PAIR_PATH = "/_bottle/pair"

# The link is followed by the redirect that carries it, so it only has to outlive one page load.
PAIRING_TTL = "2m"
PAIRING_LABEL = "Cloud in a Bottle owner"
T3_TIMEOUT_SECONDS = 60

_HOST_PATTERN = re.compile(r"[A-Za-z0-9.-]+(:[0-9]{1,5})?")
_SCHEMES = frozenset({"http", "https"})

# Minting is a POST behind a button rather than a side effect of the GET: any website can send the logged-in owner
# to a GET URL, and each mint leaves a pairing record on the server.
_PAIR_PAGE = f"""<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pair with T3 Code</title>
<body style="font-family:system-ui;max-width:32rem;margin:4rem auto;padding:0 1rem">
<h1>T3 Code</h1>
<p>This browser is not signed in to T3 Code yet.</p>
<form method="post" action="{PAIR_PATH}">
<button type="submit" autofocus style="font-size:1rem;padding:0.6rem 1.2rem">Pair this browser</button>
</form>
"""


class PairingError(Exception):
    pass


def public_base_url(forwarded_proto: str | None, forwarded_host: str | None) -> str:
    """The URL the visitor reached the app on, from the headers the router sets."""
    if forwarded_proto not in _SCHEMES:
        raise PairingError(f"unexpected X-Forwarded-Proto: {forwarded_proto!r}")
    if forwarded_host is None or _HOST_PATTERN.fullmatch(forwarded_host) is None:
        raise PairingError(f"unexpected X-Forwarded-Host: {forwarded_host!r}")
    return f"{forwarded_proto}://{forwarded_host}"


def pairing_command(base_url: str) -> list[str]:
    return [
        "t3",
        "auth",
        "pairing",
        "create",
        "--base-url",
        base_url,
        "--ttl",
        PAIRING_TTL,
        "--label",
        PAIRING_LABEL,
        "--json",
    ]


def parse_pair_url(stdout: str, base_url: str) -> str:
    """Extract the pairing link from `t3 auth pairing create --json` output."""
    try:
        issued = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise PairingError(f"t3 did not print JSON: {error}") from error
    pair_url = issued.get("pairUrl") if isinstance(issued, dict) else None
    if not isinstance(pair_url, str) or not pair_url.startswith(f"{base_url}/pair#token="):
        raise PairingError("t3 printed no pairUrl for the requested base URL")
    return pair_url


def create_pair_url(base_url: str) -> str:
    try:
        result = subprocess.run(
            pairing_command(base_url), capture_output=True, text=True, timeout=T3_TIMEOUT_SECONDS, check=False
        )
    except subprocess.TimeoutExpired as error:
        raise PairingError(f"t3 did not answer within {T3_TIMEOUT_SECONDS}s") from error
    if result.returncode != 0:
        raise PairingError(f"t3 exited with {result.returncode}: {result.stderr.strip()}")
    return parse_pair_url(result.stdout, base_url)


class PairHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if not self._is_owner_pair_request():
            return
        self._send(HTTPStatus.OK, "text/html; charset=utf-8", _PAIR_PAGE)

    def do_POST(self) -> None:
        if not self._is_owner_pair_request():
            return
        try:
            base_url = public_base_url(self.headers.get("X-Forwarded-Proto"), self.headers.get("X-Forwarded-Host"))
            pair_url = create_pair_url(base_url)
        except PairingError as error:
            # The detail goes to the container log only; the page is not the place for server internals.
            print(f"[pair_helper] pairing failed: {error}", file=sys.stderr, flush=True)
            self._send(
                HTTPStatus.BAD_GATEWAY,
                "text/plain; charset=utf-8",
                "Could not create a T3 Code pairing link. The app's logs have the reason.\n",
            )
            return
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", pair_url)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _is_owner_pair_request(self) -> bool:
        if self.path.split("?", 1)[0] != PAIR_PATH:
            self._send(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", "not found\n")
            return False
        # nginx already enforces this; checked again because this endpoint hands out full access to the server.
        if self.headers.get("X-OpenHost-Is-Owner") != "true":
            self._send(HTTPStatus.FORBIDDEN, "text/plain; charset=utf-8", "forbidden\n")
            return False
        return True

    def _send(self, status: HTTPStatus, content_type: str, body: str) -> None:
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        # Quiet by default: the request line carries nothing useful, and failures are logged where they happen.
        pass


def main() -> None:
    server = ThreadingHTTPServer(LISTEN_ADDRESS, PairHandler)
    print(f"[pair_helper] listening on {LISTEN_ADDRESS[0]}:{LISTEN_ADDRESS[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
