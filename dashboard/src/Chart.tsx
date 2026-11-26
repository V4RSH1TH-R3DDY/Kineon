import { useEffect, useRef, useState } from 'react'
import type { Timeline } from './api'

const M = { l: 36, r: 12, t: 12, b: 25 }
const DAY_MS = 24 * 3600e3
const GAP_MS = 2 * 3600e3 // do not draw a line across a long gap (overnight, watch off)

type Pt = { t: number; score: number; lo: number; hi: number }

export default function Chart({ timeline }: { timeline: Timeline }) {
  const figure = useRef<HTMLElement>(null)
  const [width, setWidth] = useState(760)

  useEffect(() => {
    if (!figure.current) return
    const resize = new ResizeObserver(([entry]) => setWidth(Math.max(200, Math.floor(entry.contentRect.width))))
    resize.observe(figure.current)
    return () => resize.disconnect()
  }, [])

  const all = timeline.points.map((p) => ({ t: Date.parse(p.at), r: p.result }))
  const doses = timeline.doses.map((d) => Date.parse(d.taken_at))
  if (!all.length && !doses.length) return <figure ref={figure}><p className="muted empty-state">No data yet.</p></figure>
  const height = width >= 520 ? 253 : 190

  const t0 = Math.min(all[0]?.t ?? Infinity, doses[0] ?? Infinity)
  const t1 = Math.max(all.at(-1)?.t ?? -Infinity, doses.at(-1) ?? -Infinity)
  const span = t1 - t0
  const x = (t: number) => Math.round(M.l + ((t - t0) / (span || 1)) * (width - M.l - M.r))
  const y = (v: number) => Math.round(M.t + (1 - v / 100) * (height - M.t - M.b))

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

  const intraday = span <= DAY_MS
  const tickCount = Math.max(3, Math.min(8, Math.floor(width / 78)))
  const step = Math.max(1, Math.ceil(span / DAY_MS / tickCount))
  const ticks: number[] = []
  if (intraday) {
    if (span === 0) ticks.push(t0)
    else for (let i = 0; i < tickCount; i++) ticks.push(t0 + span * i / (tickCount - 1))
  } else {
    const d = new Date(t0)
    d.setHours(24, 0, 0, 0)
    for (; d.getTime() <= t1; d.setDate(d.getDate() + step)) ticks.push(d.getTime())
  }
  const tickFormat = new Intl.DateTimeFormat(undefined, intraday ? { hour: 'numeric', minute: '2-digit' } : { month: 'short', day: 'numeric' })

  return (
    <figure ref={figure}>
      <svg
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label={`Tremor score over time with ${good.length} good measurements, ${refused.length} unreliable windows and ${doses.length} logged doses`}
      >
        {[0, 25, 50, 75, 100].map((v) => (
          <g key={v}>
            <line x1={M.l} x2={width - M.r} y1={y(v)} y2={y(v)} className="grid" />
            <text x={M.l - 6} y={y(v) + 4} textAnchor="end" className="tick">{v}</text>
          </g>
        ))}
        {ticks.map((t, i) => (
          <text key={t} x={x(t)} y={height - 6} textAnchor={i === 0 ? 'start' : i === ticks.length - 1 ? 'end' : 'middle'} className="tick">
            {tickFormat.format(t)}
          </text>
        ))}
        {doses.map((t, i) => <line key={i} x1={x(t)} x2={x(t)} y1={M.t} y2={height - M.b} className="dose" />)}
        {segs.map((s, i) => <path key={`b${i}`} d={band(s)} className="band" />)}
        {segs.map((s, i) => <path key={`l${i}`} d={line(s)} className="line" />)}
        {segs.filter((s) => s.length === 1).map(([point], i) => (
          <circle key={i} cx={x(point.t)} cy={y(point.score)} r={3} className="line" />
        ))}
        {refused.map((t, i) => <line key={i} x1={x(t)} x2={x(t)} y1={height - M.b} y2={height - M.b - 7} className="refused" />)}
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
