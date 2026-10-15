"""HTTP client for the legacy server, shared by the CLI and optional MCP bridge."""

import os

import httpx


class IPhoneClient:
    def __init__(self, url: str | None = None, *, transport=None):
        url = url or os.environ.get("IPHONE_AGENT_URL", "http://127.0.0.1:8890")
        parsed = httpx.URL(url)
        if parsed.scheme not in ("http", "https") or not parsed.host or parsed.query or parsed.fragment:
            raise ValueError("server URL must be an HTTP(S) URL without a query or fragment")
        self.http = httpx.Client(base_url=url.rstrip("/"), timeout=60, transport=transport, trust_env=False)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.http.close()

    def request(self, method: str, path: str, body: dict | None = None):
        response = self.http.request(method, path, json=body)
        response.raise_for_status()
        return response

    def status(self) -> dict:
        return self.request("GET", "/api/status").json()

    def screenshot(self) -> bytes:
        return self.request("GET", "/api/frame.jpg").content

    def action(self, name: str, **arguments) -> dict:
        if name not in ("tap", "swipe", "scroll", "type", "key", "home", "back"):
            raise ValueError("unknown control action")
        return self.request("POST", f"/api/{name}", arguments or None).json()

    def calibrate(self, x: float | None = None, y: float | None = None) -> dict:
        if x is None and y is None:
            return self.request("POST", "/api/calibrate/start").json()
        if x is None or y is None:
            raise ValueError("provide both pointer coordinates")
        return self.request("POST", "/api/calibrate/finish", {"x": x, "y": y}).json()

    def edit_text(self, text: str, replace: bool = False, submit: bool = False) -> dict:
        return self.request("POST", "/api/edit_text", {"text": text, "replace": replace, "submit": submit}).json()

    def delegate(self, goal: str) -> dict:
        return self.request("POST", "/api/agent", {"text": goal}).json()

    def task_status(self) -> dict:
        return self.status()["agent"]

    def stop(self) -> dict:
        return self.request("POST", "/api/agent/stop").json()
