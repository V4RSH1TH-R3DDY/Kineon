import { useState } from 'react'
import { doctorApi, type Session } from './api'
import Workspace, { Icon } from './Workspace'

const ID_OK = /^[A-Za-z0-9._-]{1,64}$/

export default function Connect({ notice, onReady }: { notice: string | null; onReady: (s: Session) => void }) {
  const [patientId, setPatientId] = useState('')
  const [clinicKey, setClinicKey] = useState(() => sessionStorage.getItem('kineon.clinic-key') ?? '')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function open() {
    setBusy(true)
    setError(null)
    const id = patientId.trim()
    const key = clinicKey.trim()
    try {
      await doctorApi(id, key).timeline()
      sessionStorage.setItem('kineon.clinic-key', key)
      onReady({ patientId: id, clinicKey: key })
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Workspace>
      <main className="access-workspace" id="patient-access">
        <header className="page-heading">
          <div>
            <h1>Patient access</h1>
            <p className="muted">Open a saved medical record and tremor history with your clinic key.</p>
          </div>
        </header>
        {notice && <p role="status" className="banner">{notice}</p>}
        {error && <p role="alert" className="banner error">{error}</p>}
        <div className="access-grid">
          <section className="surface access-panel">
            <span className="metric-icon violet"><Icon name="record" /></span>
            <h2>Open a patient file</h2>
            <p className="muted">The patient’s six-digit code is only used when you start live sharing.</p>
            <form className="stack" onSubmit={(e) => { e.preventDefault(); void open() }}>
              <label>Patient ID
                <input value={patientId} onChange={(e) => setPatientId(e.target.value)}
                  placeholder="Patient ID from the phone app" autoComplete="off" />
              </label>
              <label>Clinic access key
                <input type="password" value={clinicKey} onChange={(e) => setClinicKey(e.target.value)}
                  autoComplete="current-password" maxLength={256} />
              </label>
              <div className="row">
                <button type="submit" disabled={busy || !ID_OK.test(patientId.trim()) || !clinicKey.trim()}>Open patient file</button>
              </div>
            </form>
          </section>
          <section className="surface demo-panel">
            <div className="demo-emblem"><span className="metric-icon violet"><Icon name="pulse" /></span></div>
            <div>
              <h2>Explore the dashboard</h2>
              <p className="muted">Try the tremor history, dose chart and medical record with an illustrative patient.</p>
            </div>
            <button className="quiet" onClick={() => onReady({ patientId: 'demo-patient', clinicKey: null })}>
              Open the illustrative demo patient <Icon name="arrow" />
            </button>
          </section>
        </div>
      </main>
    </Workspace>
  )
}
