"""Report summary text, written only from numbers computed here. No LLM, no free text.

The dose comparison is an observation. The text never says a dose caused a change.
Hindi and Kannada templates are machine-written and need a native-speaker review before any clinical use.
"""
import numpy as np

from app.schemas import Lang, Timeline

NEAR_HOURS = 2.0
MIN_GROUP = 5  # smallest group size for the dose comparison to be reported

DISCLAIMER: dict[str, str] = {
    "en": "Tracking report, not a diagnosis.",
    "hi": "यह ट्रैकिंग रिपोर्ट है, निदान नहीं।",
    "kn": "ಇದು ಟ್ರ್ಯಾಕಿಂಗ್ ವರದಿ, ರೋಗನಿರ್ಣಯವಲ್ಲ.",
}

_NONE = {
    "en": "No usable tremor measurements have been recorded yet. {n_refused} were set aside because the signal was unreliable.",
    "hi": "अभी तक कोई उपयोगी कंपन माप दर्ज नहीं हुआ है। संकेत भरोसेमंद न होने के कारण {n_refused} माप अलग रखे गए।",
    "kn": "ಇನ್ನೂ ಯಾವುದೇ ಉಪಯುಕ್ತ ನಡುಕ ಅಳತೆ ದಾಖಲಾಗಿಲ್ಲ. ಸಂಕೇತ ನಂಬಲರ್ಹವಾಗಿಲ್ಲದ ಕಾರಣ {n_refused} ಅಳತೆಗಳನ್ನು ಪಕ್ಕಕ್ಕೆ ಇಡಲಾಗಿದೆ.",
}

_MAIN = {
    "en": "Between {start} and {end} ({days} days), {n_ok} good tremor measurements were recorded and {n_refused} were set aside because the signal was unreliable. The median tremor score was {median} (usual range {p10} to {p90}).",
    "hi": "{start} से {end} ({days} दिन) के बीच {n_ok} अच्छे कंपन माप दर्ज हुए और संकेत भरोसेमंद न होने के कारण {n_refused} माप अलग रखे गए। कंपन स्कोर का मध्यमान {median} रहा (सामान्य सीमा {p10} से {p90})।",
    "kn": "{start} ರಿಂದ {end} ರವರೆಗೆ ({days} ದಿನಗಳು) {n_ok} ಉತ್ತಮ ನಡುಕ ಅಳತೆಗಳು ದಾಖಲಾಗಿವೆ, ಮತ್ತು ಸಂಕೇತ ನಂಬಲರ್ಹವಾಗಿಲ್ಲದ ಕಾರಣ {n_refused} ಅಳತೆಗಳನ್ನು ಪಕ್ಕಕ್ಕೆ ಇಡಲಾಗಿದೆ. ನಡುಕದ ಸ್ಕೋರ್‌ನ ಮಧ್ಯಮ ಮೌಲ್ಯ {median} (ಸಾಮಾನ್ಯ ಶ್ರೇಣಿ {p10} ರಿಂದ {p90}).",
}

_DOSE = {
    "en": "In the 2 hours after a logged dose the average tremor score was {near}, compared with {far} at other times. This is an observation only. It does not show that the dose caused the difference.",
    "hi": "दर्ज की गई दवा लेने के बाद के 2 घंटों में औसत कंपन स्कोर {near} रहा, जबकि बाकी समय में यह {far} था। यह केवल एक अवलोकन है। इससे यह साबित नहीं होता कि अंतर दवा के कारण हुआ।",
    "kn": "ದಾಖಲಿಸಿದ ಔಷಧಿ ತೆಗೆದುಕೊಂಡ ನಂತರದ 2 ಗಂಟೆಗಳಲ್ಲಿ ಸರಾಸರಿ ನಡುಕ ಸ್ಕೋರ್ {near} ಆಗಿತ್ತು, ಉಳಿದ ಸಮಯದಲ್ಲಿ {far}. ಇದು ಕೇವಲ ಒಂದು ಅವಲೋಕನ. ವ್ಯತ್ಯಾಸಕ್ಕೆ ಔಷಧಿಯೇ ಕಾರಣ ಎಂದು ಇದು ತೋರಿಸುವುದಿಲ್ಲ.",
}


def compute(tl: Timeline) -> dict:
    ok = [p for p in tl.points if p.result.status == "ok"]
    stats: dict = {"n_ok": len(ok), "n_refused": len(tl.points) - len(ok)}
    if not ok:
        return stats
    scores = np.array([p.result.tremor_score for p in ok])
    dose_times = [d.taken_at for d in tl.doses]
    near, far = [], []
    for p in ok:
        since = [(p.at - d).total_seconds() / 3600 for d in dose_times if p.at >= d]
        (near if since and min(since) <= NEAR_HOURS else far).append(p.result.tremor_score)
    stats.update(
        start=ok[0].at.date().isoformat(),
        end=ok[-1].at.date().isoformat(),
        days=(ok[-1].at.date() - ok[0].at.date()).days + 1,
        median=f"{np.median(scores):.1f}",
        p10=f"{np.percentile(scores, 10):.1f}",
        p90=f"{np.percentile(scores, 90):.1f}",
    )
    if len(near) >= MIN_GROUP and len(far) >= MIN_GROUP:
        stats.update(near=f"{np.mean(near):.1f}", far=f"{np.mean(far):.1f}")
    return stats


def summary_text(stats: dict, lang: Lang) -> str:
    if stats["n_ok"] == 0:
        return _NONE[lang].format(**stats)
    text = _MAIN[lang].format(**stats)
    if "near" in stats:
        text += " " + _DOSE[lang].format(**stats)
    return text
