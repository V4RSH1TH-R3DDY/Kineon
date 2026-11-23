"""Chart (PNG), CSV and PDF renderers for a Timeline. Every output says it is not a diagnosis.

shortcut: the PDF is English only (core fonts are Latin-1). Hindi/Kannada need an embedded Noto font.
"""
import csv
import io

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from fpdf import FPDF  # noqa: E402

from app.report.summary import DISCLAIMER, compute, summary_text  # noqa: E402
from app.schemas import Timeline  # noqa: E402

ILLUSTRATIVE = "ILLUSTRATIVE DATA - not a real patient."


def chart_png(tl: Timeline) -> bytes:
    fig, ax = plt.subplots(figsize=(9, 4), dpi=130)
    ok = [p for p in tl.points if p.result.status == "ok"]
    if ok:
        x = [p.at for p in ok]
        ax.fill_between(x, [p.result.band_low for p in ok], [p.result.band_high for p in ok], alpha=0.25, label="confidence band")
        ax.plot(x, [p.result.tremor_score for p in ok], lw=1, label="tremor score")
    for i, d in enumerate(tl.doses):
        ax.axvline(d.taken_at, color="tab:red", alpha=0.3, lw=0.8, label="dose logged" if i == 0 else None)
    refused = [p.at for p in tl.points if p.result.status != "ok"]
    if refused:
        ax.plot(refused, [0] * len(refused), "|", color="gray", label="signal unreliable (no score)")
    ax.set_ylim(0, 100)
    ax.set_ylabel("tremor score (0-100, uncalibrated)", fontsize=8)
    prefix = "ILLUSTRATIVE DATA - " if tl.illustrative else ""
    ax.set_title(f"{prefix}Tremor score over time (tracking report, not a diagnosis)", fontsize=9)
    if ax.get_legend_handles_labels()[0]:
        ax.legend(fontsize=7, loc="upper right")
    fig.autofmt_xdate()
    buf = io.BytesIO()
    fig.savefig(buf, format="png")
    plt.close(fig)
    return buf.getvalue()


def _safe_cell(v) -> str:
    # Stop spreadsheet formula injection: free text starting with = + - @ is shown as text.
    s = "" if v is None else str(v)
    return "'" + s if s[:1] in ("=", "+", "-", "@", "\t", "\r") else s


def csv_bytes(tl: Timeline) -> bytes:
    out = io.StringIO()
    out.write(f"# {DISCLAIMER['en']}" + (f" {ILLUSTRATIVE}" if tl.illustrative else "") + "\n")
    w = csv.writer(out, lineterminator="\n")
    w.writerow(["time_utc", "kind", "status", "reason", "tremor_score", "band_low", "band_high", "dominant_hz", "dose_label", "dose_tags"])
    rows = [(p.at, ["score", p.result.status, p.result.reason, p.result.tremor_score, p.result.band_low,
                    p.result.band_high, p.result.dominant_hz, "", ""]) for p in tl.points]
    rows += [(d.taken_at, ["dose", "", "", "", "", "", "", d.label, ";".join(d.tags)]) for d in tl.doses]
    for at, cells in sorted(rows, key=lambda r: r[0]):
        w.writerow([at.isoformat(), *map(_safe_cell, cells)])
    return out.getvalue().encode("utf-8")


def _latin1(s: str) -> str:
    return s.encode("latin-1", "replace").decode("latin-1")


def pdf_bytes(tl: Timeline) -> bytes:
    stats = compute(tl)
    pdf = FPDF()
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 16)
    pdf.cell(0, 10, "TremorTrack+ tracking report", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(0, 7, DISCLAIMER["en"], new_x="LMARGIN", new_y="NEXT")
    if tl.illustrative:
        pdf.set_text_color(200, 0, 0)
        pdf.cell(0, 7, ILLUSTRATIVE, new_x="LMARGIN", new_y="NEXT")
        pdf.set_text_color(0, 0, 0)
    pdf.set_font("Helvetica", "", 10)
    pdf.cell(0, 6, _latin1(f"Patient: {tl.patient_id}"), new_x="LMARGIN", new_y="NEXT")
    pdf.ln(2)
    pdf.multi_cell(0, 5, _latin1(summary_text(stats, "en")), new_x="LMARGIN", new_y="NEXT")
    pdf.ln(3)
    pdf.image(io.BytesIO(chart_png(tl)), w=190)
    pdf.ln(3)
    pdf.set_font("Helvetica", "I", 8)
    pdf.multi_cell(0, 4, "This report is signed by TremorTrack+. To check a copy, compute its SHA-256 and look it up "
                         "at /v1/verify/<sha256>. Any edit to the file changes the hash and the check fails. "
                         "Scores are uncalibrated and are not a clinical rating.", new_x="LMARGIN", new_y="NEXT")
    return bytes(pdf.output())
