"""Write contracts/openapi.json from the FastAPI app. Run from backend/: uv run python ../scripts/dump_openapi.py"""
import json
import pathlib

from app.main import app

out = pathlib.Path(__file__).resolve().parent.parent / "contracts" / "openapi.json"
out.write_text(json.dumps(app.openapi(), indent=2) + "\n")
print(f"wrote {out}")
