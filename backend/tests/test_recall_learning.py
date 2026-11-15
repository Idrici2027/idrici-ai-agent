"""Recall across conversations and automatic learning (no FastAPI needed)."""
import asyncio
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.agent.learning import apply_learning, learn_from_turn, parse_learning  # noqa: E402
from app.agent.memory import MemoryStore  # noqa: E402
from app.models.model_provider import MockModelProvider  # noqa: E402


class FakeProvider:
    def __init__(self, text):
        self.text, self.calls = text, 0

    async def generate(self, messages, tools=None):
        self.calls += 1
        return {"text": self.text, "provider": "fake", "tool_calls": []}


class RecallLearningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.s = MemoryStore(Path(self.tmp.name) / "t.db")

    def tearDown(self):
        self.tmp.cleanup()

    def test_recall_uses_old_conversation(self):
        c1 = self.s.create_conversation("default")
        self.s.add_conversation_message("default", c1["id"], "user", "مشروعي اسمه Idrici ويستخدم Flutter")
        c2 = self.s.create_conversation("default")
        ctx = self.s.build_recall_context("default", "ما هو مشروعي؟", c2["id"])
        self.assertIn("Flutter", ctx)
        self.assertIsNone(self.s.build_recall_context("default", "ما هو مشروعي؟", c1["id"]))

    def test_arabic_article_matching(self):
        self.s.add("أحب القهوة صباحاً")
        self.assertTrue(self.s.search("قهوة"))

    def test_recall_marks_unverified(self):
        self.s.add_experience("default", "خطأ Gradle", "جرّب تحديث wrapper")
        ctx = self.s.build_recall_context("default", "Gradle")
        self.assertIn("[proposed]", ctx)

    def test_rename_and_delete_helpers(self):
        c = self.s.create_conversation("default")
        self.assertEqual(self.s.rename_conversation("default", c["id"], "عنوان")["title"], "عنوان")
        self.assertIsNone(self.s.rename_conversation("other", c["id"], "x"))
        e = self.s.add_experience("default", "t", "c")
        self.assertFalse(self.s.delete_experience("other", e["id"]))
        self.assertTrue(self.s.delete_experience("default", e["id"]))
        k = self.s.add_skill("default", "n")
        self.assertTrue(self.s.delete_skill("default", k["id"]))

    def test_parse_learning_tolerates_noise(self):
        self.assertEqual(parse_learning("no json"), {})
        self.assertEqual(parse_learning('x {"memories": ["a"]} y'), {"memories": ["a"]})

    def test_apply_learning_rejects_secrets_and_never_verifies(self):
        saved = apply_learning(self.s, "default", {
            "memories": ["أعمل على تطبيق Idrici", "my api key is abc", 5],
            "experiences": [{"title": "t", "content": "c"}],
        })
        self.assertEqual(saved, {"memories": 1, "experiences": 1})
        self.assertEqual(self.s.list()[0]["category"], "learned")
        self.assertEqual(self.s.list_experiences("default")[0]["category"], "proposed")

    def test_learn_from_turn(self):
        p = FakeProvider('{"memories": ["المستخدم يفضل الردود القصيرة"], "experiences": []}')
        out = asyncio.run(learn_from_turn(p, self.s, "default", None,
                                          "أفضل أن تكون ردودك قصيرة دائماً", "حسناً"))
        self.assertEqual(out["memories"], 1)
        # short messages and mock provider do not trigger a model call
        asyncio.run(learn_from_turn(p, self.s, "default", None, "مرحبا", "هلا"))
        asyncio.run(learn_from_turn(MockModelProvider(), self.s, "default", None,
                                    "رسالة طويلة بما فيه الكفاية", "رد"))
        self.assertEqual(p.calls, 1)

    def test_provider_failure_is_swallowed(self):
        class Boom:
            async def generate(self, messages, tools=None):
                raise RuntimeError("x")
        out = asyncio.run(learn_from_turn(Boom(), self.s, "default", None,
                                          "رسالة طويلة بما فيه الكفاية", "رد"))
        self.assertEqual(out, {"memories": 0, "experiences": 0})


if __name__ == "__main__":
    unittest.main(verbosity=2)
