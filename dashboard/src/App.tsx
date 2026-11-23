import { useCallback, useEffect, useState } from 'react'
import Chart from './Chart'
import {
  api, sha256Hex,
  type Baseline, type ExportFormat, type Lang, type Report, type ReviewItem, type Timeline, type Verdict, type VerifyResult,
} from './api'

const DEFAULT_PATIENT = 'demo-patient'
const num = (n: number | null | undefined) => (n == null ? '–' : n.toFixed(1))
const when = (iso: string) => new Date(iso).toLocaleString()
const LANGS: [Lang, string][] = [['en', 'English'], ['hi', 'हिन्दी'], ['kn', 'ಕನ್ನಡ']]

function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob)
  const a = Object.assign(document.createElement('a'), { href: url, download: name })
  a.click()
  URL.revokeObjectURL(url)
}

export default function App() {
  const [input, setInput] = useState(DEFAULT_PATIENT)
  const [pid, setPid] = useState(DEFAULT_PATIENT)
  const [timeline, setTimeline] = useState<Timeline | null>(null)
  const [baseline, setBaseline] = useState<Baseline | null>(null)
  const [report, setReport] = useState<Report | null>(null)
  const [lang, setLang] = useState<Lang>('en')
  const [queue, setQueue] = useState<ReviewItem[]>([])
  // shortcut: clinic staff tick consent for the patient here. Production needs the patient's own consent screen on the phone.
  const [consentOk, setConsentOk] = useState(false)
  const [consentId, setConsentId] = useState<string | null>(null)
  const [digest, setDigest] = useState<string | null>(null)
  const [checked, setChecked] = useState<{ name: string; result: VerifyResult } | null>(null)
  const [error, setError] = useState<string | null>(null)

  const run = useCallback(async (fn: () => Promise<void>) => {
    setError(null)
    try { await fn() } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
  }, [])

  useEffect(() => {
    let stale = false
    setTimeline(null); setBaseline(null); setConsentId(null); setConsentOk(false); setDigest(null); setChecked(null)
    void run(async () => {
      const [t, b] = await Promise.all([api.timeline(pid), api.baseline(pid)])
      if (!stale) { setTimeline(t); setBaseline(b) }
    })
    return () => { stale = true }
  }, [pid, run])

  useEffect(() => {
    let stale = false
    setReport(null)
    void run(async () => { const r = await api.report(pid, lang); if (!stale) setReport(r) })
    return () => { stale = true }
  }, [pid, lang, run])

  useEffect(() => { void run(async () => setQueue(await api.queue())) }, [run])

  const doExport = (format: ExportFormat) => run(async () => {
    let cid = consentId
    if (!cid) { cid = (await api.consent(pid)).consent_id; setConsentId(cid) }
    const { blob, digest } = await api.exportFile(pid, format, cid)
    setDigest(digest)
    download(blob, `tremortrack-${pid}.${format}`)
  })

  const withdraw = () => run(async () => {
    if (!consentId) return
    await api.revoke(pid, consentId)
    setConsentId(null); setConsentOk(false)
  })

  const review = (item: ReviewItem, label: Verdict) => run(async () => {
    await api.verdict(item.id, label)
    setQueue((q) => q.filter((i) => i.id !== item.id))
  })

  const verify = (file: File) => run(async () => {
    setChecked(null)
    const result = await api.verify(await sha256Hex(await file.arrayBuffer()))
    setChecked({ name: file.name, result })
  })

  return (
    <main>
      <header>
        <h1>TremorTrack+ <span>doctor dashboard</span></h1>
        <p className="notice">Tracking report, not a diagnosis. The doctor makes every medical decision.</p>
      </header>

      <form className="row" onSubmit={(e) => { e.preventDefault(); setPid(input.trim()) }}>
        <label>Patient id <input value={input} onChange={(e) => setInput(e.target.value)} /></label>
        <button type="submit" disabled={!input.trim()}>Load</button>
      </form>

      {error && <p role="alert" className="error">{error}</p>}
      {timeline?.illustrative && <p className="banner">Illustrative demo data. This is not a real patient.</p>}

      {baseline && (
        <section className="cards" aria-label="Personal baseline">
          <div><b>{num(baseline.median_score)}</b><small>median score</small></div>
          <div><b>{num(baseline.typical_hz)}</b><small>typical Hz</small></div>
          <div><b>{baseline.windows_seen}</b><small>good windows used</small></div>
        </section>
      )}

      <section>
        <h2>Tremor vs doses</h2>
        {timeline ? <Chart timeline={timeline} /> : <p className="muted">Loading…</p>}
      </section>

      <section>
        <h2>Summary</h2>
        <div className="row" role="group" aria-label="Summary language">
          {LANGS.map(([l, name]) => (
            <button key={l} className={l === lang ? 'on' : ''} aria-pressed={l === lang} onClick={() => setLang(l)}>{name}</button>
          ))}
        </div>
        {report ? <><p lang={report.lang}>{report.summary}</p><p className="muted" lang={report.lang}>{report.disclaimer}</p></> : <p className="muted">Loading…</p>}
      </section>

      <section>
        <h2>Uncertain episodes to review</h2>
        {queue.length === 0 ? <p className="muted">Nothing to review.</p> : (
          <ul className="queue">
            {queue.slice(0, 8).map((i) => (
              <li key={i.id}>
                <span>
                  {when(i.at)} · {i.patient_id} · score {num(i.result.tremor_score)} (band {num(i.result.band_low)}–{num(i.result.band_high)}, {num(i.result.dominant_hz)} Hz)
                </span>
                <span className="row">
                  <button onClick={() => review(i, 'tremor')}>Tremor</button>
                  <button onClick={() => review(i, 'not_tremor')}>Not tremor</button>
                  <button onClick={() => review(i, 'unsure')}>Unsure</button>
                </span>
              </li>
            ))}
          </ul>
        )}
        {queue.length > 8 && <p className="muted">{queue.length - 8} more not shown.</p>}
      </section>

      <section>
        <h2>Export</h2>
        <label className="check">
          <input type="checkbox" checked={consentOk} disabled={!!consentId} onChange={(e) => setConsentOk(e.target.checked)} />
          The patient has agreed to export this report. Every export is logged.
        </label>
        <div className="row">
          {(['pdf', 'csv', 'png'] as const).map((f) => (
            <button key={f} disabled={!consentOk || !timeline} onClick={() => doExport(f)}>Download {f.toUpperCase()}</button>
          ))}
          {consentId && <button className="quiet" onClick={withdraw}>Withdraw consent</button>}
        </div>
        {digest && <p className="muted">Signed. SHA-256 <code>{digest}</code></p>}

        <h3>Check a file</h3>
        <p className="muted">The file is hashed in your browser and is not uploaded.</p>
        <input type="file" aria-label="File to check" onChange={(e) => { const f = e.target.files?.[0]; if (f) void verify(f) }} />
        {checked && (
          <p role="status" className={checked.result.valid ? 'ok' : 'error'}>
            {checked.result.valid
              ? `${checked.name} is unaltered. Signed ${checked.result.signed_at ? when(checked.result.signed_at) : ''}.`
              : `${checked.name} does not match any signed export. It may have been edited.`}
          </p>
        )}
      </section>
    </main>
  )
}
