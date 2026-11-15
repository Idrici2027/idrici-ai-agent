"""Restore after a server wipe, and recall of earlier conversations."""
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from app.agent.memory import MemoryStore, is_history_question  # noqa: E402


class BackupHistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.s = MemoryStore(self.dir / "a.db")

    def tearDown(self):
        self.tmp.cleanup()

    def _chat(self, user, assistant, store=None):
        s = store or self.s
        c = s.create_conversation("default")
        s.add_conversation_message("default", c["id"], "user", user)
        s.add_conversation_message("default", c["id"], "assistant", assistant)
        return c

    # ---- question detection
    def test_history_questions_detected(self):
        for q in ["ماذا تحدثنا في المحادثات السابقة؟",
                  "هل تتذكر باقي المحادثات؟",
                  "ما هي محادثاتنا الأخرى",
                  "what did we talk about in our previous conversations?",
                  "do you remember our other chats",
                  "ماذا تحدثنا أمس", "last time I told you my plan"]:
            self.assertTrue(is_history_question(q), q)
        for q in ["ما عاصمة فرنسا؟", "اكتب لي دالة بايثون", "hello there"]:
            self.assertFalse(is_history_question(q), q)

    # ---- the reported bug: new chat asks about the other chats
    def test_new_chat_can_see_other_conversations(self):
        self._chat("أريد بناء تطبيق للطبخ بفلاتر", "فكرة ممتازة، نبدأ بالتصميم")
        self._chat("ساعدني في خطة السفر إلى اسطنبول", "إليك برنامج ثلاثة أيام")
        cur = self.s.create_conversation("default")
        q = "ماذا تحدثنا في المحادثات السابقة؟"  # no keyword overlap at all
        ctx = self.s.build_recall_context(
            "default", q, cur["id"], history_question=is_history_question(q))
        self.assertIn("للطبخ", ctx)
        self.assertIn("اسطنبول", ctx)
        self.assertIn("DO have access", ctx)

    def test_index_present_even_for_ordinary_questions(self):
        self._chat("مشروع الطبخ", "حسناً")
        cur = self.s.create_conversation("default")
        ctx = self.s.build_recall_context("default", "ما عاصمة فرنسا", cur["id"])
        self.assertIn("مشروع الطبخ", ctx)  # titles only, no excerpts
        self.assertNotIn("user began with", ctx)

    def test_current_conversation_excluded_from_digest(self):
        c = self._chat("موضوع فريد", "رد")
        self.assertIsNone(self.s.build_recall_context("default", "شيء", c["id"]))

    def test_digest_skips_secrets(self):
        self._chat("my password is hunter2 for the server", "ok")
        cur = self.s.create_conversation("default")
        ctx = self.s.build_recall_context(
            "default", "previous conversations", cur["id"], history_question=True)
        self.assertNotIn("hunter2", ctx or "")

    # ---- the reported bug: server database wiped
    def test_restore_after_wipe(self):
        c = self._chat("خطة المشروع الكبير", "ابدأ بالتحليل")
        self.s.add("المستخدم يعمل على تطبيق Idrici", "learned")
        self.s.add_experience("default", "Gradle", "حدّث wrapper", "proposed")
        self.s.add_skill("default", "نشر", "خطوات النشر", "1. ادفع")
        backup = self.s.export_data("default")
        self.assertEqual(len(backup["conversations"]), 1)
        self.assertEqual(len(backup["conversations"][0]["messages"]), 2)

        fresh = MemoryStore(self.dir / "wiped.db")   # simulated Render wipe
        self.assertEqual(fresh.list_conversations("default"), [])
        out = fresh.import_data("default", backup)
        self.assertEqual(out["conversations"], 1)
        self.assertEqual(out["messages"], 2)
        restored = fresh.list_conversation_messages("default", c["id"])
        self.assertEqual([m["role"] for m in restored], ["user", "assistant"])
        self.assertEqual(fresh.get_conversation("default", c["id"])["title"],
                         "خطة المشروع الكبير")
        self.assertEqual(fresh.list()[0]["category"], "learned")
        self.assertEqual(len(fresh.list_experiences("default")), 1)
        self.assertEqual(len(fresh.list_skills("default")), 1)
        # and the restored chats are now visible to recall
        cur = fresh.create_conversation("default")
        self.assertIn("خطة المشروع", fresh.build_recall_context(
            "default", "x", cur["id"]))

    def test_restore_is_idempotent_and_never_overwrites(self):
        c = self._chat("الأصل", "رد")
        backup = self.s.export_data("default")
        backup["conversations"][0]["messages"].append(
            {"role": "user", "content": "دخيل", "created": 1.0})
        out = self.s.import_data("default", backup)
        self.assertEqual(out["conversations"], 0)
        self.assertEqual(len(self.s.list_conversation_messages("default", c["id"])), 2)
        again = self.s.import_data("default", backup)
        self.assertEqual(again["conversations"], 0)

    def test_restore_rejects_bad_data(self):
        out = self.s.import_data("default", {
            "conversations": [
                {"id": "../etc", "messages": [{"role": "user", "content": "x"}]},
                {"id": "ok1", "messages": [{"role": "system", "content": "x"},
                                           {"role": "user", "content": " "}]},
                "junk", 5],
            "memories": [{"content": "my api key is abc"}, "junk"],
        })
        self.assertEqual(out["conversations"], 0)
        self.assertEqual(out["memories"], 0)
        with self.assertRaises(ValueError):
            self.s.import_data("default", [])  # type: ignore[arg-type]

    def test_restore_is_per_owner(self):
        c = self._chat("خاص", "رد")
        backup = self.s.export_data("default")
        fresh = MemoryStore(self.dir / "w.db")
        fresh.import_data("someone", backup)
        self.assertIsNotNone(fresh.get_conversation("someone", c["id"]))
        self.assertIsNone(fresh.get_conversation("default", c["id"]))

    def test_since_returns_only_newer_conversations(self):
        old = self._chat("قديمة", "رد")
        cut = self.s.export_data("default")["server_time"]
        import time as _t
        _t.sleep(0.02)
        new = self._chat("جديدة", "رد")
        got = self.s.export_data("default", since=cut)
        self.assertEqual([c["id"] for c in got["conversations"]], [new["id"]])
        none = self.s.export_data("default", include_conversations=False)
        self.assertEqual(none["conversations"], [])
        self.assertNotEqual(old["id"], new["id"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
