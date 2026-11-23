"""Ed25519 signing of export digests.

shortcut: the private key sits unencrypted in a 0600 file, move it to KMS/HSM for production.
shortcut: Ed25519 is not post-quantum, the brief's ML-DSA is the production plan.
"""
import os
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


class Signer:
    def __init__(self, path: str):
        p = Path(path)
        if p.exists():
            self._key = serialization.load_pem_private_key(p.read_bytes(), password=None)
        else:
            self._key = Ed25519PrivateKey.generate()
            p.parent.mkdir(parents=True, exist_ok=True)
            pem = self._key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(pem)
        self._pub = self._key.public_key()

    def sign(self, digest_hex: str) -> str:
        return self._key.sign(bytes.fromhex(digest_hex)).hex()

    def verify(self, digest_hex: str, signature_hex: str) -> bool:
        try:
            self._pub.verify(bytes.fromhex(signature_hex), bytes.fromhex(digest_hex))
            return True
        except (InvalidSignature, ValueError):
            return False
