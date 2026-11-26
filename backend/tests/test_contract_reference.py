"""Guard the v1 surface while v2 routes and models are added."""
from hashlib import sha256
import json
from pathlib import Path

from app.main import app

CONTRACT = Path(__file__).resolve().parents[2] / "contracts/openapi.json"
SCHEMA_PREFIX = "#/components/schemas/"
V1_REFERENCE = "acd80c064ef2e38e675ed63be0d20dac6f87cc3190f147326237cadd5c900267"


def schema_references(value):
    if isinstance(value, dict):
        ref = value.get("$ref")
        if isinstance(ref, str) and ref.startswith(SCHEMA_PREFIX):
            yield ref.removeprefix(SCHEMA_PREFIX)
        for child in value.values():
            yield from schema_references(child)
    elif isinstance(value, list):
        for child in value:
            yield from schema_references(child)


def legacy_digest(document):
    paths = {path: api for path, api in document["paths"].items() if path.startswith("/v1/")}
    definitions = document["components"]["schemas"]
    schemas = {}
    pending = list(schema_references(paths))
    while pending:
        name = pending.pop()
        if name not in schemas:
            schemas[name] = definitions[name]
            pending.extend(schema_references(schemas[name]))
    canonical = json.dumps({"paths": paths, "schemas": schemas}, sort_keys=True, separators=(",", ":"))
    return sha256(canonical.encode()).hexdigest()


def test_generated_openapi_matches_tracked_contract():
    assert json.loads(CONTRACT.read_text(encoding="utf-8")) == app.openapi()


def test_v1_contract_remains_compatible_with_reference_freeze():
    assert legacy_digest(app.openapi()) == V1_REFERENCE
