"""End-to-end test of the action's list and post steps.

Runs list_new_security_advisories.py and ../post.sh as action.yml does, with
a fake GitHub API and a fake Discord webhook. Needs jq and curl.

Run: python3 -m unittest discover -s security-advisories
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import ClassVar

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_list_new_security_advisories import (  # noqa: E402
    A1,
    A2,
    SECRET_TEXT,
    FakeGitHub,
    advisory,
)

LISTER = os.path.join(HERE, "list_new_security_advisories.py")
POST = os.path.join(HERE, "..", "post.sh")


class FakeDiscord(BaseHTTPRequestHandler):
    """Records webhook posts; answers with `status`."""

    status: ClassVar[int] = 204
    posts: ClassVar[list[dict]] = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        self.posts.append({"path": self.path, "body": body})
        self.send_response(self.status)
        if self.status == 204:
            self.end_headers()
            return
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"message": "500: Internal Server Error", "code": 0}')


def serve(handler):
    server = HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


@unittest.skipUnless(shutil.which("jq") and shutil.which("curl"), "needs jq and curl")
class EndToEndTest(unittest.TestCase):
    def setUp(self):
        FakeGitHub.advisories = {}
        FakeDiscord.status = 204
        FakeDiscord.posts = []
        self.github = serve(FakeGitHub)
        self.discord = serve(FakeDiscord)
        self.tmp = tempfile.TemporaryDirectory()
        self.webhook = f"http://127.0.0.1:{self.discord.server_port}/api/webhooks/1/x"
        state_dir = os.path.join(self.tmp.name, "security-advisory-notify")
        self.payload_file = os.path.join(state_dir, "advisories.jsonl")
        self.output_file = os.path.join(self.tmp.name, "output")
        self.env = {
            "PATH": os.environ["PATH"],
            "GITHUB_ACTIONS": "true",
            "GITHUB_REPOSITORY": "octo-org/octo-repo",
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_API_URL": f"http://127.0.0.1:{self.github.server_port}",
            "GITHUB_OUTPUT": self.output_file,
            "RUNNER_TEMP": self.tmp.name,
            "ADVISORY_READ_TOKEN": "test-token",
            "STATE_KEY": self.webhook,
            "STATE_FILE": os.path.join(state_dir, "state.json"),
            "PAYLOAD_FILE": self.payload_file,
        }

    def tearDown(self):
        for server in (self.github, self.discord):
            server.shutdown()
            server.server_close()
        self.tmp.cleanup()

    def run_action(self):
        """Run the list step, then the post step if it says to; return the
        combined log and the post step's exit code (None if skipped)."""
        listed = subprocess.run(
            [sys.executable, LISTER],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(listed.returncode, 0, listed.stderr)
        with open(self.output_file) as f:
            outputs = dict(line.split("=", 1) for line in f.read().splitlines()[-2:])
        log = listed.stdout + listed.stderr
        if outputs["post"] != "true":
            return log, None
        posted = subprocess.run(
            ["bash", POST],
            env={
                **self.env,
                "WEBHOOK": self.webhook,
                "EVENT": "repository_advisory",
                "PAYLOAD": self.payload_file,
            },
            capture_output=True,
            text=True,
            check=False,
        )
        return log + posted.stdout + posted.stderr, posted.returncode

    def test_posts_each_new_advisory_once_without_details(self):
        FakeGitHub.advisories = {
            "triage": [advisory(A2, created="2026-10-02T00:00:00Z")],
            "draft": [
                advisory(A1, "draft", "2026-10-01T00:00:00Z", severity="critical")
            ],
        }
        log, code = self.run_action()
        self.assertEqual((log, code), ("", 0))
        self.assertEqual(len(FakeDiscord.posts), 2)
        self.assertTrue(
            all(
                p["path"] == "/api/webhooks/1/x?with_components=true"
                for p in FakeDiscord.posts
            )
        )
        bodies = [p["body"] for p in FakeDiscord.posts]
        contents = [b["components"][0]["components"][0]["content"] for b in bodies]
        url = "https://github.com/octo-org/octo-repo/security/advisories"
        self.assertEqual(
            contents,
            [
                f"### [{A1} • Critical severity (Draft advisory)]({url}/{A1})",
                f"### [{A2} • High severity (Triage advisory)]({url}/{A2})",
            ],
        )
        for body in bodies:
            self.assertEqual(body["allowed_mentions"], {"parse": []})
            self.assertNotIn(SECRET_TEXT, json.dumps(body))
            self.assertNotIn("username", body)

        # Simulates the cache save: the state file is kept between runs.
        log, code = self.run_action()
        self.assertEqual((log, code), ("", None))
        self.assertEqual(len(FakeDiscord.posts), 2)

    def test_discord_error_logs_no_advisory_data(self):
        FakeGitHub.advisories = {"triage": [advisory(A1)]}
        FakeDiscord.status = 500
        log, code = self.run_action()
        self.assertNotEqual(code, 0)
        self.assertIn("500", log)
        self.assertNotIn(A1, log)
        self.assertNotIn(SECRET_TEXT, log)


if __name__ == "__main__":
    unittest.main()
