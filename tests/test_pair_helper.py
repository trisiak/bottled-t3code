import http.client
import json
import threading
from collections.abc import Iterator
from http.server import ThreadingHTTPServer

import pytest

import pair_helper

OWNER = {"X-OpenHost-Is-Owner": "true", "X-Forwarded-Proto": "https", "X-Forwarded-Host": "t3code.example.com"}
BASE_URL = "https://t3code.example.com"
PAIR_URL = f"{BASE_URL}/pair#token=abc123"


@pytest.fixture
def server() -> Iterator[ThreadingHTTPServer]:
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), pair_helper.PairHandler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield httpd
    httpd.shutdown()
    httpd.server_close()


def request(server: ThreadingHTTPServer, method: str, path: str, headers: dict[str, str]) -> http.client.HTTPResponse:
    connection = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
    connection.request(method, path, headers=headers)
    response = connection.getresponse()
    response.read()
    return response


def test_public_base_url_uses_forwarded_headers() -> None:
    assert pair_helper.public_base_url("https", "t3code.example.com") == BASE_URL
    assert pair_helper.public_base_url("http", "t3code.bottle.local:8080") == "http://t3code.bottle.local:8080"


@pytest.mark.parametrize(
    ("proto", "host"),
    [
        (None, "t3code.example.com"),
        ("javascript", "t3code.example.com"),
        ("https", None),
        ("https", "evil.example/path"),
        ("https", "user@evil.example"),
        ("https", "a b"),
    ],
)
def test_public_base_url_rejects_malformed_headers(proto: str | None, host: str | None) -> None:
    with pytest.raises(pair_helper.PairingError):
        pair_helper.public_base_url(proto, host)


def test_parse_pair_url_returns_link() -> None:
    stdout = json.dumps({"id": "p1", "credential": "abc123", "pairUrl": PAIR_URL})
    assert pair_helper.parse_pair_url(stdout, BASE_URL) == PAIR_URL


@pytest.mark.parametrize(
    "stdout",
    [
        "not json",
        json.dumps(["list"]),
        json.dumps({"credential": "abc123"}),
        json.dumps({"pairUrl": "https://elsewhere.example/pair#token=abc123"}),
    ],
)
def test_parse_pair_url_rejects_unexpected_output(stdout: str) -> None:
    with pytest.raises(pair_helper.PairingError):
        pair_helper.parse_pair_url(stdout, BASE_URL)


def test_get_shows_page_without_minting(server: ThreadingHTTPServer, monkeypatch: pytest.MonkeyPatch) -> None:
    def fail(base_url: str) -> str:
        raise AssertionError("GET must not mint a pairing link")

    monkeypatch.setattr(pair_helper, "create_pair_url", fail)
    response = request(server, "GET", pair_helper.PAIR_PATH, OWNER)
    assert response.status == 200
    assert response.getheader("Cache-Control") == "no-store"


def test_post_redirects_owner_to_pairing_link(server: ThreadingHTTPServer, monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[str] = []

    def mint(base_url: str) -> str:
        seen.append(base_url)
        return PAIR_URL

    monkeypatch.setattr(pair_helper, "create_pair_url", mint)
    response = request(server, "POST", pair_helper.PAIR_PATH, OWNER)
    assert response.status == 303
    assert response.getheader("Location") == PAIR_URL
    assert response.getheader("Cache-Control") == "no-store"
    assert seen == [BASE_URL]


@pytest.mark.parametrize("method", ["GET", "POST"])
def test_non_owner_is_refused(server: ThreadingHTTPServer, monkeypatch: pytest.MonkeyPatch, method: str) -> None:
    def fail(base_url: str) -> str:
        raise AssertionError("a non-owner request must not mint a pairing link")

    monkeypatch.setattr(pair_helper, "create_pair_url", fail)
    headers = {key: value for key, value in OWNER.items() if key != "X-OpenHost-Is-Owner"}
    assert request(server, method, pair_helper.PAIR_PATH, headers).status == 403
    assert request(server, method, pair_helper.PAIR_PATH, {**headers, "X-OpenHost-Is-Owner": "false"}).status == 403


def test_other_paths_are_not_found(server: ThreadingHTTPServer) -> None:
    assert request(server, "GET", "/_bottle/other", OWNER).status == 404


def test_failure_is_reported_without_detail(server: ThreadingHTTPServer, monkeypatch: pytest.MonkeyPatch) -> None:
    def fail(base_url: str) -> str:
        raise pair_helper.PairingError("secret detail")

    monkeypatch.setattr(pair_helper, "create_pair_url", fail)
    connection = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=5)
    connection.request("POST", pair_helper.PAIR_PATH, headers=OWNER)
    response = connection.getresponse()
    body = response.read().decode()
    assert response.status == 502
    assert "secret detail" not in body
