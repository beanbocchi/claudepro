"""Tests for lib/claudepro-settings against a fake /v1/models: python3 -m unittest discover lib"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

SCRIPT = os.path.join(os.path.dirname(__file__), "claudepro-settings")


class Catalog(BaseHTTPRequestHandler):
    models = []

    def do_GET(self):
        body = json.dumps({"data": [{"id": i, "owned_by": o} for i, o in Catalog.models]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


MIXED = [
    ("claude-opus-4-5-20251101", "anthropic"),
    ("gpt-5.6-luna", "openai"),
    ("claude-sonnet-5-5", "anthropic"),
    ("gpt-image-2.5", "openai"),
    ("claude-opus-5-5", "anthropic"),
    ("gpt-6-luna", "openai"),
    ("codex-auto-review", "openai"),
    ("claude-fable-5-2", "anthropic"),
    ("gpt-6.1-sol", "openai"),
    ("gpt-6-astra", "openai"),
    ("claude-3-7-sonnet-20250219", "anthropic"),
]
CLAUDE_ORDER = ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-4-5-20251101", "claude-3-7-sonnet-20250219"]
GPT_ORDER = ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "gpt-5.6-luna"]

# What `codex debug models --bundled` prints, cut down to the fields the script reads.
BUNDLED = {
    "models": [
        {"slug": "gpt-6-luna", "display_name": "GPT-6-Luna", "priority": 4, "visibility": "list", "tool_mode": "code_mode_only"},
        {"slug": "gpt-5.5", "display_name": "GPT-5.5", "priority": 13, "visibility": "list", "tool_mode": None,
         "base_instructions": "You are Codex.", "comp_hash": "x", "service_tiers": [{"id": "priority"}],
         "supported_reasoning_levels": [{"effort": e} for e in ("low", "medium", "high", "xhigh")]},
    ]
}


class SettingsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.server = HTTPServer(("127.0.0.1", 0), Catalog)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def run_script(self, models, *args, **env):
        Catalog.models = models
        environ = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDEPRO_", "CODEXPRO_"))}
        environ.update(
            {"CLAUDEPRO_BASE_URL": f"http://127.0.0.1:{self.server.server_port}", "CLAUDEPRO_AUTH_TOKEN": "sk-test"},
            **env,
        )
        return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True, env=environ)

    def settings(self, models, **env):
        ran = self.run_script(models, **env)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        return json.loads(ran.stdout)

    def test_claude_picker_lists_chat_models_claude_first_newest_generation_first(self):
        out = self.settings(MIXED)
        self.assertEqual([o["model"] for o in out["modelPicker"]["options"]], CLAUDE_ORDER + GPT_ORDER)
        self.assertFalse(out["modelPicker"]["replaceBuiltInOptions"])

    def test_claude_pins_no_model_by_default(self):
        self.assertNotIn("model", self.settings(MIXED))

    def test_claude_default_alias_is_followed(self):
        out = self.settings(MIXED + [("claudepro-default.claude-sonnet-5-5", "anthropic")])
        self.assertEqual(out["model"], "claude-sonnet-5-5")

    def test_claudepro_model_takes_a_gpt_model_and_refuses_an_image_model(self):
        self.assertEqual(self.settings(MIXED, CLAUDEPRO_MODEL="gpt-6-luna")["model"], "gpt-6-luna")
        ran = self.run_script(MIXED, CLAUDEPRO_MODEL="gpt-image-2.5")
        self.assertEqual(ran.returncode, 1)
        self.assertEqual(ran.stderr.strip(), "claudepro: CLAUDEPRO_MODEL is not a chat model in the proxy catalog: gpt-image-2.5")

    def codex(self, models, config=None, **env):
        home = tempfile.mkdtemp(dir=self.dir)
        bundled = os.path.join(home, "bundled.json")
        catalog = os.path.join(home, "models.json")
        if config is not None:
            with open(os.path.join(home, "config.toml"), "w") as f:
                f.write(config)
        with open(bundled, "w") as f:
            json.dump(BUNDLED, f)
        ran = self.run_script(models, "--codex", bundled, catalog, **env)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        with open(catalog) as f:
            return json.loads(ran.stdout)["model"], json.load(f)["models"]

    def test_codex_starts_on_codex_own_default_among_offered_models(self):
        # gpt-6-luna has the lowest priority of the shipped models the server offers.
        model, _ = self.codex(MIXED)
        self.assertEqual(model, "gpt-6-luna")

    def test_codex_passes_no_model_once_codex_config_saved_one(self):
        model, _ = self.codex(MIXED, config='model = "gpt-6.1-sol"\n[tui]\nx = 1\n')
        self.assertIsNone(model)
        model, _ = self.codex(MIXED, config='[tui]\nmodel = "x"\n')
        self.assertEqual(model, "gpt-6-luna")

    def test_codex_catalog_lists_gpt_first_in_priority_order(self):
        _, entries = self.codex(MIXED)
        self.assertEqual([e["slug"] for e in entries], GPT_ORDER + CLAUDE_ORDER)
        self.assertEqual([e["priority"] for e in entries], list(range(1, len(entries) + 1)))
        self.assertTrue(all(e["visibility"] == "list" for e in entries))

    def test_codex_catalog_keeps_shipped_entries_and_copies_gpt_5_5_for_others(self):
        _, entries = self.codex(MIXED)
        by_slug = {e["slug"]: e for e in entries}
        self.assertEqual(by_slug["gpt-6-luna"]["tool_mode"], "code_mode_only")
        self.assertEqual(by_slug["gpt-6-luna"]["display_name"], "GPT-6-Luna")
        claude = by_slug["claude-opus-5-5"]
        self.assertEqual(claude["display_name"], "claude-opus-5-5")
        self.assertEqual(claude["base_instructions"], "You are Codex.")
        self.assertEqual(claude["service_tiers"], [])
        self.assertEqual([level["effort"] for level in claude["supported_reasoning_levels"]], ["low", "medium", "high"])
        self.assertNotIn("comp_hash", claude)
        self.assertEqual(by_slug["gpt-6-astra"]["supported_reasoning_levels"][-1], {"effort": "xhigh"})

    def test_codex_default_alias_and_env(self):
        model, _ = self.codex(MIXED + [("codexpro-default.gpt-6.1-sol", "openai")])
        self.assertEqual(model, "gpt-6.1-sol")
        model, _ = self.codex(MIXED, CODEXPRO_MODEL="claude-opus-5-5")
        self.assertEqual(model, "claude-opus-5-5")


if __name__ == "__main__":
    unittest.main()
