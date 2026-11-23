import os
import tempfile
from pathlib import Path

os.environ.setdefault("KINEON_DB", ":memory:")  # keep tests off the real database file
os.environ.setdefault("KINEON_SIGNING_KEY", str(Path(tempfile.mkdtemp()) / "key.pem"))  # and off the real key
os.environ.setdefault("KINEON_VOICE_CACHE", str(Path(tempfile.mkdtemp()) / "voice"))
for name in list(os.environ):  # a real key in the shell must never be used by tests
    if name.startswith("ELEVENLABS_"):
        del os.environ[name]
