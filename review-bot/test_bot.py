import hashlib
import hmac
import importlib.util
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from queue import Queue
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("bot", Path(__file__).with_name("bot.py"))
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)


def payload(action="opened", head="a" * 40):
    return {"action": action,
            "repository": {"full_name": "bitcoin/bitcoin",
                           "html_url": "https://git.fish.foo/bitcoin/bitcoin"},
            "pull_request": {"number": 42, "head": {"sha": head},
                             "base": {"ref": "master"}}}


class BotTests(unittest.TestCase):
    def test_signature_checks_raw_body(self):
        body = b'{"action":"opened"}'
        sig = hmac.new(b"secret", body, hashlib.sha256).hexdigest()
        self.assertTrue(bot.valid_signature(body, sig, b"secret"))
        self.assertFalse(bot.valid_signature(body + b" ", sig, b"secret"))
        self.assertFalse(bot.valid_signature(body, "bad", b"secret"))

    def test_event_filters_and_rejects_other_repository(self):
        self.assertEqual(bot.parse_event("pull_request", payload()), (42, "master", "a" * 40))
        self.assertEqual(bot.parse_event("pull_request", payload("synchronize")),
                         (42, "master", "a" * 40))
        self.assertIsNone(bot.parse_event("push", payload()))
        self.assertIsNone(bot.parse_event("pull_request", payload("closed")))
        wrong = payload()
        wrong["repository"]["full_name"] = "someone/bitcoin"
        with self.assertRaises(ValueError):
            bot.parse_event("pull_request", wrong)

    def test_webhook_queues_only_authenticated_target_event(self):
        jobs = Queue()
        server = ThreadingHTTPServer(("127.0.0.1", 0), bot.make_handler(b"secret", jobs))
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            body = json.dumps(payload()).encode()
            sig = hmac.new(b"secret", body, hashlib.sha256).hexdigest()
            url = f"http://127.0.0.1:{server.server_port}/webhooks/forgejo"
            request = urllib.request.Request(url, body, headers={
                "X-Forgejo-Signature": sig, "X-Forgejo-Event": "pull_request"})
            self.assertEqual(urllib.request.urlopen(request).status, 202)
            self.assertEqual(jobs.get_nowait(), (42, "master", "a" * 40))
            request.headers["X-Forgejo-Signature"] = "bad"
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(request)
            self.assertEqual(error.exception.code, 401)
            self.assertTrue(jobs.empty())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_collect_review_skips_stale_head_without_model_call(self):
        outputs = iter(["", "b" * 40, "c" * 40])
        with patch.object(bot, "prepare_checkout"), patch.object(bot, "git", side_effect=lambda *a: next(outputs)):
            base, head, review, skip, mentions = bot.collect_review(Path("/unused"), 42, "master", "a" * 40)
        self.assertEqual((base, head, review), ("c" * 40, "b" * 40, None))
        self.assertIn("changed", skip)
        self.assertEqual(mentions, [])

    def test_collect_review_uses_merge_base_and_finds_commit_mentions(self):
        head = "a" * 40
        base = "b" * 40
        merge_base = "c" * 40
        calls = []

        def fake_git(checkout, *args):
            calls.append(args)
            if args[0] == "rev-parse":
                return head if args[1].endswith("head") else base
            if args[0] == "merge-base":
                return merge_base
            if args[0] == "log":
                return "Fix issue @reviewer\n\x00"
            if args[0] == "diff":
                return "+change\n"
            return ""

        with patch.object(bot, "prepare_checkout"), patch.object(bot, "git", side_effect=fake_git):
            result = bot.collect_review(Path("/unused"), 42, "master", head)
        self.assertEqual(result[0:2], (base, head))
        self.assertIn("+change", result[2])
        self.assertEqual(result[4], ["Fix issue @reviewer"])
        self.assertIn(("diff", "--no-ext-diff", "--binary", f"{merge_base}..{head}"), calls)

    def test_openai_request_disables_storage(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self, *args):
                return json.dumps({"status": "completed", "output": [{"type": "message",
                    "content": [{"type": "output_text", "text": "No findings."}]}]}).encode()

        with patch.object(bot.urllib.request, "urlopen", return_value=Response()) as send:
            self.assertEqual(bot.openai_review("test-key", "patch"), "No findings.")
        request = send.call_args.args[0]
        sent = json.loads(request.data)
        self.assertIs(sent["store"], False)
        self.assertEqual(sent["model"], "gpt-6-sol")

    def test_draft_records_shas(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = bot.write_draft(Path(tmp), 42, "b" * 40, "a" * 40, "No findings.")
            self.assertIn("Base: `" + "b" * 40 + "`", path.read_text())
            self.assertIn("No findings.", path.read_text())


if __name__ == "__main__":
    unittest.main()
