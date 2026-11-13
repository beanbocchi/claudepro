"""Tests for bin/imagegen.py against a local fake server: python3 -m unittest discover image-mod/tests"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "bin", "imagegen.py")
PNG = b"\x89PNG\r\n\x1a\nfake"


class Fake(BaseHTTPRequestHandler):
    requests = []
    status = 200

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        Fake.requests.append((self.path, dict(self.headers), body))
        if Fake.status != 200:
            self.send_response(Fake.status)
            self.end_headers()
            self.wfile.write(b'{"error":"quota"}')
            return
        answer = {"data": [{"b64_json": base64.b64encode(PNG).decode(), "revised_prompt": "a grey cat"}]}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(answer).encode())

    def do_GET(self):
        ids = ["gpt-image-2", "claude-opus-5-5", "gpt-image-2.5-flare", "gpt-image-2.5", "gpt-6-luna", "gpt-image-1.5"]
        body = json.dumps({"data": [{"id": i} for i in ids]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ImagegenTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Fake.requests = []
        Fake.status = 200
        self.dir = tempfile.mkdtemp()

    def run_script(self, request, *args, **env):
        environ = {k: v for k, v in os.environ.items() if not k.startswith("ANTHROPIC_")}
        environ.update({"ANTHROPIC_BASE_URL": self.base, "ANTHROPIC_AUTH_TOKEN": "sk-test"}, **env)
        if isinstance(request, dict):
            request = {"model": "gpt-image-2.5", **request}
        return subprocess.run(
            [sys.executable, SCRIPT, *args], input=json.dumps(request), capture_output=True, text=True, env=environ, cwd=self.dir
        )

    def test_list_models_prints_image_models_newest_first(self):
        ran = self.run_script("", "--list-models")
        self.assertEqual(ran.returncode, 0, ran.stderr)
        self.assertEqual(json.loads(ran.stdout), ["gpt-image-2.5", "gpt-image-2.5-flare", "gpt-image-2", "gpt-image-1.5"])

    def test_missing_model_is_refused_before_any_request(self):
        ran = self.run_script({"prompt": "a cat", "output_path": "cat.png", "model": ""})
        self.assertEqual(ran.returncode, 1)
        self.assertIn("model is empty", ran.stderr)
        self.assertEqual(Fake.requests, [])

    def test_generation_posts_json_and_saves_the_png(self):
        ran = self.run_script({"prompt": "a cat", "output_path": "out/cat.png", "size": "1024x1024"})
        self.assertEqual(ran.returncode, 0, ran.stderr)
        out = json.loads(ran.stdout)
        path = os.path.join(self.dir, "out", "cat.png")
        self.assertEqual(out, {"path": path, "bytes": len(PNG), "model": "gpt-image-2.5", "revised_prompt": "a grey cat"})
        with open(path, "rb") as f:
            self.assertEqual(f.read(), PNG)
        url, headers, body = Fake.requests[0]
        self.assertEqual(url, "/v1/images/generations")
        self.assertEqual(headers["Authorization"], "Bearer sk-test")
        self.assertEqual(
            json.loads(body),
            {"model": "gpt-image-2.5", "prompt": "a cat", "output_format": "png", "size": "1024x1024"},
        )

    def test_reference_images_go_to_edits_as_multipart(self):
        ref = os.path.join(self.dir, "ref.png")
        with open(ref, "wb") as f:
            f.write(b"REFBYTES")
        ran = self.run_script({"prompt": "same style", "output_path": "new.webp", "reference_images": [ref]})
        self.assertEqual(ran.returncode, 0, ran.stderr)
        url, headers, body = Fake.requests[0]
        self.assertEqual(url, "/v1/images/edits")
        self.assertTrue(headers["Content-Type"].startswith("multipart/form-data; boundary="))
        self.assertIn(b'name="image[]"; filename="ref.png"\r\nContent-Type: image/png\r\n\r\nREFBYTES', body)
        self.assertIn(b'name="output_format"\r\n\r\nwebp', body)

    def test_http_error_is_reported_with_status(self):
        Fake.status = 429
        ran = self.run_script({"prompt": "a cat", "output_path": "cat.png"})
        self.assertEqual(ran.returncode, 1)
        self.assertEqual(ran.stderr.strip(), 'the server answered HTTP 429: {"error":"quota"}')

    def test_unknown_extension_is_refused_before_any_request(self):
        ran = self.run_script({"prompt": "a cat", "output_path": "cat.gif"})
        self.assertEqual(ran.returncode, 1)
        self.assertIn("must end in .png", ran.stderr)
        self.assertEqual(Fake.requests, [])

    def test_missing_base_url_says_so(self):
        ran = self.run_script({"prompt": "a cat", "output_path": "cat.png"}, ANTHROPIC_BASE_URL="")
        self.assertEqual(ran.returncode, 1)
        self.assertIn("ANTHROPIC_BASE_URL", ran.stderr)


if __name__ == "__main__":
    unittest.main()
