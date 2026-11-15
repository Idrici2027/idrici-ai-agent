# التعديلات / Changes

## الخادم (backend)
- `backend/app/agent/memory.py` — بحث أوسع (حتى 20000 رسالة بدل 2000)، تجاهل "ال" في العربية، `build_recall_context` (ذكريات + محادثات سابقة + تجارب + مهارات)، إعادة تسمية المحادثة، حذف/عرض التجارب والمهارات، حد الذاكرة 2000 حرف.
- `backend/app/agent/learning.py` — **جديد**: تعلّم تلقائي بعد كل رد (يرفض الأسرار، التجارب دائماً `proposed`). إيقافه: `IDRICI_AUTO_LEARN=0`.
- `backend/main.py` — `/chat` يحقن الذاكرة الطويلة ويتعلم في الخلفية؛ نقاط جديدة: `PATCH /conversations/{id}`، `/experiences`، `/skills`.
- `backend/app/agent/tools.py` — أدوات بحث للوكيل: `conversation_search`, `experience_search`, `skill_search`.
- `backend/tests/test_recall_learning.py` — **جديد**: اختبارات.

## التطبيق (android_app)
- `lib/home_screen.dart` — أيقونة رسالة أعلى اليسار تفتح لوحة جانبية بكل المحادثات (إعادة تسمية/حذف/محادثة جديدة)، وزر "ذاكرة الوكيل" لعرض ما تعلمه وحذفه. المحادثة الجديدة تُنشأ مع أول رسالة.
- `lib/chat_api.dart` — `renameConversation`, `listMemories`, `deleteMemory`, دعم PATCH.

## أخرى
- `README.md` — حالة الميزات.
