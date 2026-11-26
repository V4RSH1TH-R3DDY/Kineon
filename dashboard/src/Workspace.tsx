import { useSyncExternalStore, type ReactNode } from 'react'

const paths = {
  pulse: 'M2 12h5l3-7 4 14 3-7h5',
  overview: 'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',
  record: 'M5 3h14v18H5z M12 7v6m-3-3h6m-6 7h6',
  report: 'M5 3h10l4 4v14H5z M9 11h6m-6 5h6',
  review: 'M8 5H5v16h14V5h-3 M8 3h8v4H8z M9 14l2 2 4-4',
  download: 'M12 3v12m-4-4 4 4 4-4 M4 16v4h16v-4',
  lock: 'M6 10h12a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1z M8 10V7a4 4 0 0 1 8 0v3m-4 4v2',
  arrow: 'M4 12h15m-6-6 6 6-6 6',
  back: 'M20 12H5m6-6-6 6 6 6',
  chart: 'M3 4v16h18M7 15l4-4 4 2 5-6',
  frequency: 'M2 12h2m16 0h2M6 9v6m4-9v12m4-15v18m4-12v6',
  samples: 'M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01',
  person: 'M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2 M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
  info: 'M12 11v5m0-8h.01 M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0',
} as const

type IconName = keyof typeof paths

export function Icon({ name }: { name: IconName }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65"
      strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={paths[name]} />
    </svg>
  )
}

const patientNavigation: { id: string; label: string; icon: IconName }[] = [
  { id: 'overview', label: 'Overview', icon: 'overview' },
  { id: 'medical-record', label: 'Medical record', icon: 'record' },
  { id: 'summary', label: 'Clinical summary', icon: 'report' },
  { id: 'review', label: 'Review queue', icon: 'review' },
  { id: 'export', label: 'Reports & export', icon: 'download' },
]

function subscribeToLocation(update: () => void) {
  window.addEventListener('hashchange', update)
  return () => window.removeEventListener('hashchange', update)
}

function readLocation() {
  return window.location.hash.slice(1)
}

export default function Workspace({ patient, children }: { patient?: boolean; children: ReactNode }) {
  const items = patient ? patientNavigation : [{ id: 'patient-access', label: 'Patient access', icon: 'lock' as const }]
  const location = useSyncExternalStore(subscribeToLocation, readLocation)
  const active = items.find((item) => item.id === location)?.id ?? items[0].id

  return (
    <div className="workspace">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark"><Icon name="pulse" /></span>
          <span>TremorTrack<span className="brand-plus">+</span></span>
        </div>
        <nav className="side-nav" aria-label="Workspace navigation">
          {items.map(({ id, icon, label }) => (
            <a key={id} href={`#${id}`} aria-current={active === id ? 'location' : undefined}>
              <Icon name={icon} /><span>{label}</span>
            </a>
          ))}
        </nav>
      </aside>
      <div className="workspace-content">
        <div className="workspace-bar">
          <span>Doctor dashboard</span>
          <span className="workspace-location"><span aria-hidden="true">/</span> {patient ? 'Patient workspace' : 'Patient access'}</span>
        </div>
        {children}
      </div>
    </div>
  )
}
