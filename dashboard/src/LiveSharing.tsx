import { useEffect, useState } from 'react'
import { link, type LiveLink, type LinkCreated, type LinkStatus } from './api'
import { Icon } from './Workspace'

const ENDED: Partial<Record<LinkStatus['state'], string>> = {
  expired: 'This code expired. Request a new code to start live sharing.',
  locked: 'Too many incorrect attempts. Request a new code.',
  revoked: 'The live sharing request was cancelled.',
}

export default function LiveSharing({ patientId, clinicKey, onStart }: {
  patientId: string
  clinicKey: string
  onStart: (live: LiveLink) => void
}) {
  const [doctor, setDoctor] = useState(() => localStorage.getItem('kineon.doctor') ?? '')
  const [created, setCreated] = useState<LinkCreated | null>(null)
  const [state, setState] = useState<LinkStatus['state']>('pending')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!created || state !== 'pending') return
    let stale = false
    const id = setInterval(async () => {
      try {
        const { state: current } = await link.status(created.link_id, created.claim_secret)
        if (!stale) setState(current)
      } catch (e) {
        if (!stale) setError(e instanceof Error ? e.message : String(e))
      }
    }, 2000)
    return () => { stale = true; clearInterval(id) }
  }, [created, state])

  async function run(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="live-sharing">
      {error && <p role="alert" className="error">{error}</p>}
      {!created ? (
        <form className="stack" onSubmit={(e) => {
          e.preventDefault()
          void run(async () => {
            const name = doctor.trim()
            setCreated(await link.request(patientId, name, clinicKey))
            setState('pending')
            localStorage.setItem('kineon.doctor', name)
          })
        }}>
          <label>Your name
            <input value={doctor} onChange={(e) => setDoctor(e.target.value)} autoComplete="name" maxLength={80} />
          </label>
          <button type="submit" disabled={busy || !doctor.trim()}><Icon name="lock" />Request live code</button>
        </form>
      ) : (
        <div className="stack">
          {state === 'pending' && <>
            <p>Read this code to the patient so they can approve live sharing in their app.</p>
            <p className="code" aria-label={'Code ' + created.code.split('').join(' ')}>{created.code}</p>
          </>}
          {state === 'patient_approved' && <>
            <p className="ok" role="status">The patient approved live sharing.</p>
            <button disabled={busy} onClick={() => void run(async () => {
              const { token } = await link.confirm(created.link_id, created.claim_secret)
              onStart({ token, linkId: created.link_id, claimSecret: created.claim_secret })
            })}>Start live sharing</button>
          </>}
          {ENDED[state] && <p role="status" className="muted">{ENDED[state]}</p>}
          <button className="quiet" disabled={busy} onClick={() => void run(async () => {
            if (!ENDED[state]) await link.end(created.link_id, created.claim_secret)
            setCreated(null)
          })}>{ENDED[state] ? 'Start again' : 'Cancel request'}</button>
        </div>
      )}
    </div>
  )
}
