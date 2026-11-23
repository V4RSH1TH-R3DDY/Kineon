"""Calm Mode voice: one fixed breathing guide per language, spoken by ElevenLabs and cached on disk.

The text is generic. No patient data is ever sent to ElevenLabs. It never claims to reduce tremor or mentions medicine.
The Hindi and Kannada scripts are machine-written and need a native-speaker review before real use.

Environment:
  ELEVENLABS_API_KEY            needed to generate audio. Without it only cached or pre-recorded audio is served.
  ELEVENLABS_VOICE_ID           default voice. ELEVENLABS_VOICE_ID_HI / _KN / _EN override it per language.
  ELEVENLABS_MODEL              default eleven_v3 (the only ElevenLabs model that lists Kannada; v2 and Flash 2.5 lack it).
  KINEON_VOICE_CACHE            cache directory, default data/voice_cache.

Lookup order: a hand-made <lang>.mp3 in the cache directory (a pre-recorded fallback for a live demo),
then audio generated earlier for this exact text, voice and model, then a fresh ElevenLabs request.
"""
import hashlib
import os
from pathlib import Path

import httpx

from app.schemas import Lang

API = "https://api.elevenlabs.io/v1/text-to-speech"

SCRIPTS: dict[str, str] = {
    "en": (
        "Let's breathe together. Rest your arm on the table, or on your lap. Let your shoulders drop. "
        "Breathe in slowly through your nose, as the watch taps once. Now breathe out gently, as it taps twice. "
        "Again. In, one tap. Out, two taps. There is no hurry. Let your hands feel heavy and supported. "
        "Keep breathing at your own pace. If you like, hold your cup with both hands. "
        "You are doing well. Stay as long as you like."
    ),
    "hi": (
        "आइए साथ में सांस लें। अपना हाथ मेज़ या गोद पर आराम से रखिए। कंधों को ढीला छोड़िए। "
        "घड़ी एक बार थपथपाए तो नाक से धीरे-धीरे सांस अंदर लीजिए। अब दो बार थपथपाने पर आराम से सांस बाहर छोड़िए। "
        "फिर से। एक थपकी, सांस अंदर। दो थपकी, सांस बाहर। कोई जल्दी नहीं है। "
        "अपने हाथों को भारी और सहारे पर महसूस कीजिए। अपनी गति से सांस लेते रहिए। "
        "चाहें तो कप को दोनों हाथों से पकड़िए। आप अच्छा कर रहे हैं। जब तक चाहें इसी तरह रहिए।"
    ),
    "kn": (
        "ಬನ್ನಿ, ಒಟ್ಟಿಗೆ ಉಸಿರಾಡೋಣ. ನಿಮ್ಮ ಕೈಯನ್ನು ಮೇಜಿನ ಮೇಲೆ ಅಥವಾ ತೊಡೆಯ ಮೇಲೆ ಆರಾಮವಾಗಿ ಇಡಿ. ಭುಜಗಳನ್ನು ಸಡಿಲಗೊಳಿಸಿ. "
        "ಗಡಿಯಾರ ಒಮ್ಮೆ ಟ್ಯಾಪ್ ಮಾಡಿದಾಗ ಮೂಗಿನ ಮೂಲಕ ನಿಧಾನವಾಗಿ ಉಸಿರನ್ನು ಒಳಗೆ ಎಳೆಯಿರಿ. "
        "ಎರಡು ಬಾರಿ ಟ್ಯಾಪ್ ಮಾಡಿದಾಗ ಮೆಲ್ಲಗೆ ಉಸಿರನ್ನು ಹೊರಗೆ ಬಿಡಿ. ಮತ್ತೊಮ್ಮೆ. "
        "ಒಂದು ಟ್ಯಾಪ್, ಉಸಿರು ಒಳಗೆ. ಎರಡು ಟ್ಯಾಪ್, ಉಸಿರು ಹೊರಗೆ. ಯಾವುದೇ ಆತುರವಿಲ್ಲ. "
        "ನಿಮ್ಮ ಕೈಗಳು ಭಾರವಾಗಿ ಮತ್ತು ಆಧಾರದ ಮೇಲೆ ಇವೆ ಎಂದು ಅನುಭವಿಸಿ. ನಿಮ್ಮ ಲಯದಲ್ಲಿ ಉಸಿರಾಡುತ್ತಿರಿ. "
        "ಬೇಕಿದ್ದರೆ ಲೋಟವನ್ನು ಎರಡೂ ಕೈಗಳಿಂದ ಹಿಡಿಯಿರಿ. ನೀವು ಚೆನ್ನಾಗಿ ಮಾಡುತ್ತಿದ್ದೀರಿ. ಬೇಕಾದಷ್ಟು ಹೊತ್ತು ಹೀಗೇ ಇರಿ."
    ),
}


class VoiceUnavailable(Exception):
    """No hand-made file, no cached audio, and no API key or voice id to generate any."""


class VoiceFailed(Exception):
    """ElevenLabs could not be reached or rejected the request. The message never contains the key."""


def synthesize(lang: Lang, client: httpx.Client | None = None) -> bytes:
    cache = Path(os.environ.get("KINEON_VOICE_CACHE", "data/voice_cache"))
    manual = cache / f"{lang}.mp3"
    if manual.exists():
        return manual.read_bytes()

    voice = os.environ.get(f"ELEVENLABS_VOICE_ID_{lang.upper()}") or os.environ.get("ELEVENLABS_VOICE_ID")
    model = os.environ.get("ELEVENLABS_MODEL", "eleven_v3")
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not voice:
        raise VoiceUnavailable
    # Keyed on text, voice and model, so changing any of them regenerates instead of serving stale audio.
    digest = hashlib.sha256(f"{SCRIPTS[lang]}|{voice}|{model}".encode()).hexdigest()[:12]
    generated = cache / f"{lang}-{digest}.mp3"
    if generated.exists():
        return generated.read_bytes()
    if not key:
        raise VoiceUnavailable

    try:
        r = (client or httpx).post(
            f"{API}/{voice}",
            params={"output_format": "mp3_44100_128"},
            headers={"xi-api-key": key},
            json={"text": SCRIPTS[lang], "model_id": model},
            timeout=60,
        )
        r.raise_for_status()
    except httpx.HTTPStatusError as e:
        raise VoiceFailed(f"provider returned {e.response.status_code}") from None
    except httpx.HTTPError as e:
        raise VoiceFailed(type(e).__name__) from None
    if not r.content:
        raise VoiceFailed("empty audio")

    cache.mkdir(parents=True, exist_ok=True)
    tmp = generated.with_suffix(".tmp")
    tmp.write_bytes(r.content)
    os.replace(tmp, generated)
    return r.content
