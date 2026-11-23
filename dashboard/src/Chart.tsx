import type { Timeline } from './api'

const W = 900
const H = 320
const M = { l: 44, r: 12, t: 12, b: 34 }
const GAP_MS = 2 * 3600e3 // do not draw a line across a long gap (overnight, watch off)

type Pt = { t: number; score: number; lo: number; hi: number }

export default function Chart({ timeline }: { timeline: Timeline }) {
  const all = timeline.points.map((p) => ({ t: Date.parse(p.at), r: p.result }))
  const doses = timeline.doses.map((d) => Date.parse(d.taken_at))
  const times = [...all.map((p) => p.t), ...doses]
  if (!times.length) return <p className="muted">No data yet.</p>

  const t0 = Math.min(...times)
  const t1 = Math.max(...times)
  const x = (t: number) => M.l + ((t - t0) / (t1 - t0 || 1)) * (W - M.l - M.r)
  const y = (v: number) => M.t + (1 - v / 100) * (H - M.t - M.b)

  const good: Pt[] = all.flatMap((p) =>
    p.r.status === 'ok' ? [{ t: p.t, score: p.r.tremor_score ?? 0, lo: p.r.band_low ?? 0, hi: p.r.band_high ?? 0 }] : [],
  )
  const refused = all.filter((p) => p.r.status !== 'ok').map((p) => p.t)
  const segs: Pt[][] = []
  for (const p of good) {
    const s = segs[segs.length - 1]
    if (s && p.t - s[s.length - 1].t <= GAP_MS) s.push(p)
    else segs.push([p])
  }
  const line = (s: Pt[]) => s.map((p, i) => `${i ? 'L' : 'M'}${x(p.t)},${y(p.score)}`).join('')
  const band = (s: Pt[]) =>
    `M${s.map((p) => `${x(p.t)},${y(p.hi)}`).join('L')}L${[...s].reverse().map((p) => `${x(p.t)},${y(p.lo)}`).join('L')}Z`

  const days = Math.ceil((t1 - t0) / 86400e3)
  const step = Math.max(1, Math.ceil(days / 7))
  const ticks: number[] = []
  const d = new Date(t0)
  d.setHours(24, 0, 0, 0)
  for (; d.getTime() <= t1; d.setDate(d.getDate() + step)) ticks.push(d.getTime())

  return (
    <figure>
      <svg
        viewBox={`0 0 ${W} ${H}`}
        role="img"
        aria-label={`Tremor score over time with ${good.length} good measurements, ${refused.length} unreliable windows and ${doses.length} logged doses`}
      >
        {[0, 25, 50, 75, 100].map((v) => (
          <g key={v}>
            <line x1={M.l} x2={W - M.r} y1={y(v)} y2={y(v)} className="grid" />
            <text x={M.l - 6} y={y(v) + 4} textAnchor="end" className="tick">{v}</text>
          </g>
        ))}
        {ticks.map((t) => (
          <text key={t} x={x(t)} y={H - 12} textAnchor="middle" className="tick">
            {new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}
          </text>
        ))}
        {doses.map((t, i) => <line key={i} x1={x(t)} x2={x(t)} y1={M.t} y2={H - M.b} className="dose" />)}
        {segs.map((s, i) => <path key={`b${i}`} d={band(s)} className="band" />)}
        {segs.map((s, i) => <path key={`l${i}`} d={line(s)} className="line" />)}
        {refused.map((t, i) => <line key={i} x1={x(t)} x2={x(t)} y1={H - M.b} y2={H - M.b - 7} className="refused" />)}
      </svg>
      <figcaption className="legend">
        <span><i className="sw line" /> tremor score (0-100, uncalibrated)</span>
        <span><i className="sw band" /> confidence band</span>
        <span><i className="sw dose" /> dose logged</span>
        <span><i className="sw refused" /> signal unreliable, no score</span>
      </figcaption>
    </figure>
  )
}
