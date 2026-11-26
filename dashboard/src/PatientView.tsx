import { useCallback, useEffect, useMemo, useState } from 'react'
import Chart from './Chart'
import Records from './Records'
import LiveSharing from './LiveSharing'
import Workspace, { Icon } from './Workspace'
import {
  ApiError, doctorApi, link, sha256Hex, verify,
  type Baseline, type ExportFormat, type Lang, type MedicalRecord, type Report, type ReviewItem,
  type LiveLink, type Session, type Timeline, type TimelinePoint, type Verdict, type VerifyResult,
} from './api'

const POLL_MS = 5000
const LIVE_WITHIN_S = 120
const num = (n: number | null | undefined) => (n == null ? '–' : n.toFixed(1))
const when = (iso: string) => new Date(iso).toLocaleString()
const RANGES = [[1, '1 day'], [7, '7 days'], [30, '30 days'], [0, 'All history']] as const
const LANGS: [Lang, string][] = [['en', 'English'], ['hi', 'हिन्दी'], ['kn', 'ಕನ್ನಡ']]

/** Plain words for each reason the scorer withholds a window (see backend/app/sense/score.py). */
const REASONS: Record<string, string> = {
  no_motion_signal: 'The watch is not picking up movement. It may be loose or off the wrist.',
  voluntary_movement: 'The patient was moving their arm, so tremor could not be measured.',
  motion_artefact_or_noise: 'The signal was too noisy to trust.',
  sensor_saturated: 'The movement was too strong for the sensor.',
  sample_rate_too_low: 'The sensor was too slow for this reading.',
  window_too_short: 'The reading was too short.',
  malformed_data: 'The reading could not be read.',
}

function ago(seconds: number): string {
  if (seconds < 10) return 'just now'
  if (seconds < 90) return `${Math.round(seconds)} s ago`
  if (seconds < 5400) return `${Math.round(seconds / 60)} min ago`
  if (seconds < 172800) return `${Math.round(seconds / 3600)} h ago`
  return `${Math.round(seconds / 86400)} days ago`
}

function download(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob)
  const a = Object.assign(document.createElement('a'), { href: url, download: name })
  a.click()
  URL.revokeObjectURL(url)
}

export default function PatientView({ session, onExit, onLive }: {
  session: Session
  onExit: (notice?: string) => void
  onLive: (live?: LiveLink) => void
}) {
  const { patientId, clinicKey, live: liveLink } = session
  const api = useMemo(() => doctorApi(patientId, clinicKey), [patientId, clinicKey])
  const [timeline, setTimeline] = useState<Timeline | null>(null)
  const [baseline, setBaseline] = useState<Baseline | null>(null)
  const [queue, setQueue] = useState<ReviewItem[]>([])
  const [record, setRecord] = useState<MedicalRecord | null | undefined>(undefined)
  const [recordError, setRecordError] = useState(false)
  const [range, setRange] = useState(0)
  const [report, setReport] = useState<Report | null>(null)
  const [lang, setLang] = useState<Lang>('en')
  const [updatedAt, setUpdatedAt] = useState<number | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const [offline, setOffline] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [digest, setDigest] = useState<string | null>(null)
  const [checked, setChecked] = useState<{ name: string; result: VerifyResult } | null>(null)
  const [livePoint, setLivePoint] = useState<{ token: string; point: TimelinePoint | null }>()
  const [liveNotice, setLiveNotice] = useState<string | null>(null)

  const fail = useCallback((e: unknown) => {
    if (e instanceof ApiError && e.status === 401) onExit('The clinic key was rejected. Enter a valid key to open the file.')
    else setError(e instanceof Error ? e.message : String(e))
  }, [onExit])

  const refresh = useCallback(async () => {
    try {
      const [t, b, q] = await Promise.all([api.timeline(), api.baseline(), api.queue()])
      setTimeline(t); setBaseline(b); setQueue(q); setUpdatedAt(Date.now()); setOffline(false); setError(null)
    } catch (e) {
      if (e instanceof ApiError) fail(e)
      else setOffline(true) // the server is unreachable: keep showing the last data and retry
    }
  }, [api, fail])

  const refreshRecord = useCallback(async () => {
    try {
      setRecord(await api.record())
      setRecordError(false)
    } catch (e) {
      setRecordError(true)
      if (e instanceof ApiError && e.status === 401) fail(e)
    }
  }, [api, fail])

  useEffect(() => {
    let busy = false
    const poll = async () => {
      setNow(Date.now())
      if (document.hidden || busy) return
      busy = true
      try {
        await Promise.all([refresh(), refreshRecord()])
      } finally {
        busy = false
      }
    }
    void poll()
    const id = setInterval(() => void poll(), POLL_MS)
    return () => clearInterval(id)
  }, [refresh, refreshRecord])

  const liveToken = liveLink?.token
  useEffect(() => {
    if (!liveToken) return
    let stale = false
    let pending = false
    async function poll(token: string) {
      if (document.hidden || pending) return
      pending = true
      try {
        const point = await api.live(token)
        if (!stale) {
          setLivePoint({ token, point })
          setLiveNotice(null)
        }
      } catch (e) {
        if (stale) return
        if (e instanceof ApiError && e.status === 403) {
          setLiveNotice('Live sharing ended. Saved readings are still available.')
          onLive()
        } else if (e instanceof ApiError && e.status === 401) fail(e)
        else {
          setLivePoint({ token, point: null })
          setLiveNotice('Could not refresh the live reading. Retrying…')
        }
      } finally {
        pending = false
      }
    }
    void poll(liveToken)
    const id = setInterval(() => void poll(liveToken), POLL_MS)
    return () => { stale = true; clearInterval(id) }
  }, [api, liveToken, onLive, fail])

  useEffect(() => {
    let stale = false
    api.report(lang).then((r) => { if (!stale) setReport(r) }).catch(fail)
    return () => { stale = true }
  }, [api, lang, fail])

  const fresh = livePoint?.token === liveToken ? livePoint?.point : null
  const live = !!fresh && now - Date.parse(fresh.at) < LIVE_WITHIN_S * 1000
  const latest = live ? fresh : timeline?.points.at(-1)
  const age = latest ? Math.max(0, (now - Date.parse(latest.at)) / 1000) : null
  const chart = useMemo(() => {
    if (!timeline || !range) return timeline
    const lastDose = timeline.doses.at(-1)
    const end = Math.max(Date.parse(timeline.points.at(-1)?.at ?? '') || 0, lastDose ? Date.parse(lastDose.taken_at) : 0)
    const cutoff = end - range * 86_400_000
    return {
      ...timeline,
      points: timeline.points.filter((p) => Date.parse(p.at) >= cutoff),
      doses: timeline.doses.filter((d) => Date.parse(d.taken_at) >= cutoff),
    }
  }, [timeline, range])

  const doExport = async (format: ExportFormat) => {
    try {
      const { blob, digest } = await api.exportFile(format)
      setDigest(digest)
      download(blob, `tremortrack-${session.patientId}.${format}`)
    } catch (e) { fail(e) }
  }

  const review = async (item: ReviewItem, label: Verdict) => {
    try { await api.verdict(item.id, label); setQueue((q) => q.filter((i) => i.id !== item.id)) } catch (e) { fail(e) }
  }

  const check = async (file: File) => {
    setChecked(null)
    try { setChecked({ name: file.name, result: await verify(await sha256Hex(await file.arrayBuffer())) }) } catch (e) { fail(e) }
  }

  const endAccess = async (leaveFile: boolean) => {
    try {
      if (liveLink) await link.end(liveLink.linkId, liveLink.claimSecret)
      if (leaveFile) onExit()
      else {
        onLive()
        setLiveNotice('Live sharing stopped. Saved readings are still available.')
        void refresh()
      }
    } catch (e) { fail(e) }
  }

  const result = latest?.result
  const scored = result?.status === 'ok'
  const connection = offline ? 'Connection lost' : live ? 'Live readings' : latest ? 'Last reading ' + ago(age ?? 0) : timeline ? 'No readings yet' : 'Connecting…'

  return (
    <Workspace patient>
      <main className="patient-workspace" id="overview">
        <header className="page-heading">
          <div>
            <h1>Patient overview</h1>
            <p className="muted">Tremor readings, care history and shared medical details.</p>
          </div>
          <button className="quiet heading-action" onClick={() => void endAccess(true)}>
            <Icon name="back" />Back to patient access
          </button>
        </header>

        {error && <p role="alert" className="banner error">{error}</p>}
        {timeline?.illustrative && <p className="banner"><Icon name="info" />Illustrative demo data. This is not a real patient.</p>}

        {clinicKey && (
          <section className="surface" aria-labelledby="live-sharing-title">
            <div className="panel-heading">
              <div>
                <h2 id="live-sharing-title">Live tremor sharing</h2>
                <p className="muted">{liveLink ? 'Approved readings are saved automatically to this patient file.' : 'Request a six-digit code for the patient to approve in their app.'}</p>
              </div>
              {liveLink && <button className="quiet" onClick={() => void endAccess(false)}>Stop live sharing</button>}
            </div>
            {liveNotice && <p role="status" className="muted">{liveNotice}</p>}
            {liveLink ? <span className={live ? 'status-chip status-live' : 'status-chip'}>{live ? 'Receiving live readings' : 'Waiting for a live reading'}</span> : (
              <LiveSharing patientId={patientId} clinicKey={clinicKey} onStart={(approved) => { setLiveNotice(null); onLive(approved) }} />
            )}
          </section>
        )}

        <div className="metric-grid" role="group" aria-label="Latest reading and personal baseline">
          <div className="metric surface">
            <span className="metric-icon violet"><Icon name="pulse" /></span>
            <span>Latest tremor score</span>
            <strong>{scored ? num(result.tremor_score) : latest ? 'No score' : '–'}{scored && <small> / 100</small>}</strong>
            <small>{latest && !scored ? 'Not enough data' : 'Most recent measurement'}</small>
          </div>
          <div className="metric surface">
            <span className="metric-icon peach"><Icon name="chart" /></span>
            <span>Usual tremor score</span>
            <strong>{num(baseline?.median_score)}<small> / 100</small></strong>
            <small>Personal baseline</small>
          </div>
          <div className="metric surface">
            <span className="metric-icon mint"><Icon name="frequency" /></span>
            <span>Dominant frequency</span>
            <strong>{num(result?.dominant_hz)}<small> Hz</small></strong>
            <small>Usual frequency {num(baseline?.typical_hz)} Hz</small>
          </div>
          <div className="metric surface">
            <span className="metric-icon blue"><Icon name="samples" /></span>
            <span>Scored readings</span>
            <strong>{baseline?.windows_seen ?? '–'}</strong>
            <small>Used for the baseline</small>
          </div>
        </div>

        <div className="overview-grid">
          <section className="surface chart-panel" aria-labelledby="chart-title">
            <div className="panel-heading">
              <div><h2 id="chart-title">Tremor history</h2><p className="muted">Tremor scores and logged medication doses</p></div>
              <div className="segmented" role="group" aria-label="Chart date range">
                {RANGES.map(([days, label]) => (
                  <button key={days} aria-pressed={range === days} onClick={() => setRange(days)}>{label}</button>
                ))}
              </div>
            </div>
            {chart ? <Chart timeline={chart} /> : <p className="muted empty-state">Loading history…</p>}
          </section>

          <section className="surface snapshot-panel" aria-labelledby="snapshot-title">
            <div className="panel-heading"><h2 id="snapshot-title">Patient snapshot</h2></div>
            <div className="patient-identity">
              <span className="metric-icon violet"><Icon name="person" /></span>
              <div><strong>{timeline?.illustrative ? 'Demo patient' : session.patientId}</strong><small>{timeline?.illustrative ? session.patientId : 'Patient ID'}</small></div>
            </div>
            {record ? (
              <dl className="snapshot-facts">
                <div><dt>Condition</dt><dd>{record.diagnosis || 'None recorded'}</dd></div>
                <div className="snapshot-allergy"><dt>Allergies</dt><dd>{record.allergies.trim() || 'None recorded'}</dd></div>
                <div><dt>Medications</dt><dd>{record.medications?.length ?? 0} recorded</dd></div>
              </dl>
            ) : <p className="muted">{record === undefined ? 'Loading medical details…' : 'No medical record is saved.'}</p>}
            <a className="text-action" href="#medical-record">View medical record <Icon name="arrow" /></a>
          </section>
        </div>

        <div className="detail-grid">
          <section className="surface" aria-labelledby="reading-title">
            <div className="panel-heading">
              <h2 id="reading-title">Latest reading</h2>
              <span className={`status-chip ${offline ? 'status-offline' : live ? 'status-live' : ''}`} role="status">{connection}</span>
            </div>
            {!latest ? <p className="muted">Waiting for a reading from the patient’s watch or phone.</p> : scored ? (
              <dl className="facts">
                <div><dt>Confidence band</dt><dd>{num(result.band_low)} to {num(result.band_high)}</dd></div>
                <div><dt>Activity</dt><dd className="activity">{result.activity ?? 'Unknown'}</dd></div>
                <div><dt>Measured</dt><dd>{when(latest.at)}</dd></div>
              </dl>
            ) : (
              <p>{REASONS[result?.reason ?? ''] ?? 'The reading could not be scored.'} <span className="muted">({when(latest.at)})</span></p>
            )}
            {updatedAt && !offline && <p className="footnote">Checked at {new Date(updatedAt).toLocaleTimeString()}</p>}
          </section>

          <section className="surface" id="summary">
            <div className="panel-heading">
              <h2>Clinical summary</h2>
              <div className="segmented" role="group" aria-label="Summary language">
                {LANGS.map(([l, name]) => (
                  <button key={l} lang={l} aria-pressed={lang === l} onClick={() => setLang(l)}>{name}</button>
                ))}
              </div>
            </div>
            {report ? <><p lang={report.lang}>{report.summary}</p><p className="footnote" lang={report.lang}>{report.disclaimer}</p></> : <p className="muted">Loading…</p>}
          </section>
        </div>

        <section className="surface" id="medical-record">
          <div className="panel-heading"><h2>Medical record</h2></div>
          {recordError && <p role="status" className="muted">Could not refresh the medical record. Retrying…</p>}
          {record === undefined ? (!recordError && <p className="muted">Loading…</p>) : <Records record={record} />}
        </section>

        <section className="surface" id="review">
          <div className="panel-heading"><h2>Review queue</h2><span className="count-label">{queue.length} to review</span></div>
          {queue.length === 0 ? <p className="muted">Nothing to review.</p> : (
            <ul className="queue">
              {queue.slice(0, 8).map((i) => (
                <li key={i.id}>
                  <div><strong>{when(i.at)}</strong><small>Score {num(i.result.tremor_score)} · band {num(i.result.band_low)}–{num(i.result.band_high)} · {num(i.result.dominant_hz)} Hz</small></div>
                  <span className="row">
                    <button className="quiet" onClick={() => void review(i, 'tremor')}>Tremor</button>
                    <button className="quiet" onClick={() => void review(i, 'not_tremor')}>Not tremor</button>
                    <button className="quiet" onClick={() => void review(i, 'unsure')}>Unsure</button>
                  </span>
                </li>
              ))}
            </ul>
          )}
          {queue.length > 8 && <p className="muted">{queue.length - 8} more not shown.</p>}
        </section>

        <section className="surface" id="export">
          <div className="panel-heading"><h2>Reports &amp; export</h2></div>
          <p className="muted">Exports contain saved historical readings. Each export is logged and signed.</p>
          <div className="row">
            {(['pdf', 'csv', 'png'] as const).map((f) => (
              <button key={f} disabled={!timeline} onClick={() => void doExport(f)}><Icon name="download" />Download {f.toUpperCase()}</button>
            ))}
          </div>
          {digest && <p className="muted">Signed. SHA-256 <code>{digest}</code></p>}

          <h3>Check a file</h3>
          <p className="muted">The file is hashed in your browser and is not uploaded.</p>
          <input type="file" aria-label="File to check" onChange={(e) => { const f = e.target.files?.[0]; if (f) void check(f) }} />
          {checked && (
            <p role="status" className={checked.result.valid ? 'ok' : 'error'}>
              {checked.result.valid
                ? checked.name + ' is unaltered. ' + (checked.result.signed_at ? 'Signed ' + when(checked.result.signed_at) + '.' : '')
                : checked.name + ' does not match any signed export. It may have been edited.'}
            </p>
          )}
        </section>
      </main>
    </Workspace>
  )
}
