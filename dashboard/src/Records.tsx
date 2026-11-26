import type { MedicalRecord } from './api'

const STAGES: Record<number, string> = {
  1: 'Stage 1 · one side only',
  2: 'Stage 2 · both sides, balance fine',
  3: 'Stage 3 · balance affected, independent',
  4: 'Stage 4 · needs some help',
  5: 'Stage 5 · needs a wheelchair or bed',
}

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1)

function age(birth: string): number {
  const [year, month, day] = birth.split('-').map(Number)
  const n = new Date()
  const currentMonth = n.getMonth() + 1
  let a = n.getFullYear() - year
  if (currentMonth < month || (currentMonth === month && n.getDate() < day)) a--
  return a
}

function clock(minutes: number): string {
  const h = Math.floor(minutes / 60), m = minutes % 60
  return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`
}

function Fact({ label, value }: { label: string; value: string | number | null | undefined }) {
  if (value === null || value === undefined || value === '') return null
  return <div><dt>{label}</dt><dd>{value}</dd></div>
}

/** Everything is rendered as plain text, so nothing the patient typed can run as markup. */
export default function Records({ record }: { record: MedicalRecord | null }) {
  if (!record) {
    return <p className="muted">No medical record is saved for this patient yet.</p>
  }
  const r = record
  const symptoms = r.symptoms ?? []
  const medications = r.medications ?? []
  const emergencyContacts = r.emergency_contacts ?? []
  const doctors = [['Neurologist', r.neurologist], ['Family doctor', r.family_doctor]] as const
  const contacts = (['neurologist', 'family_doctor'] as const).some((k) => r[k]?.name || r[k]?.clinic || r[k]?.phone)
  return (
    <div className="record">
      <div className="allergy" role="note">
        <strong>Allergies</strong>
        <span>{r.allergies.trim() || 'None recorded'}</span>
      </div>

      <h3>About</h3>
      <dl className="facts">
        <Fact label="Age" value={r.birth_date ? `${age(r.birth_date)} years` : null} />
        <Fact label="Sex" value={r.sex ? cap(r.sex) : null} />
        <Fact label="Height" value={r.height_cm ? `${r.height_cm} cm` : null} />
        <Fact label="Weight" value={r.weight_kg ? `${r.weight_kg} kg` : null} />
        <Fact label="Blood type" value={r.blood_type} />
        <Fact label="Dominant hand" value={r.dominant_hand ? cap(r.dominant_hand) : null} />
      </dl>

      <h3>Diagnosis</h3>
      <dl className="facts">
        <Fact label="Condition" value={r.diagnosis} />
        <Fact label="Symptoms since" value={r.symptoms_since_year} />
        <Fact label="Diagnosed" value={r.diagnosed_year} />
        <Fact label="Affected side" value={r.affected_side ? cap(r.affected_side) : null} />
        <Fact label="Stage" value={r.stage ? STAGES[r.stage] : null} />
        <Fact label="Deep brain stimulation" value={r.has_dbs ? `Yes${r.dbs_since_year ? `, since ${r.dbs_since_year}` : ''}` : 'No'} />
        <Fact label="Other conditions" value={r.other_conditions.trim()} />
      </dl>
      {symptoms.length > 0 && (
        <ul className="tags" aria-label="Symptoms">{symptoms.map((s) => <li key={s}>{s}</li>)}</ul>
      )}

      <h3>Medications</h3>
      {medications.length === 0 ? <p className="muted">None recorded.</p> : (
        <div className="table-scroll" role="region" aria-label="Medication details" tabIndex={0}>
        <table>
          <thead><tr><th scope="col">Medicine</th><th scope="col">Dose</th><th scope="col">Times</th><th scope="col">Food</th><th scope="col">Notes</th></tr></thead>
          <tbody>
            {medications.map((m, i) => (
              <tr key={i}>
                <td>{m.name}</td>
                <td>{[m.amount, m.form, m.strength && `(${m.strength})`].filter(Boolean).join(' ')}</td>
                <td>{(m.times ?? []).slice().sort((a, b) => a - b).map(clock).join(', ') || '–'}</td>
                <td>{m.with_food === true ? 'With food' : m.with_food === false ? 'Without food' : '–'}</td>
                <td>{m.notes?.trim() || '–'}</td>
              </tr>
            ))}
          </tbody>
        </table>
        </div>
      )}

      {contacts && <>
        <h3>Care team</h3>
        <dl className="facts">
          {doctors.map(([label, c]) => c && (c.name || c.clinic || c.phone) ? (
            <Fact key={label} label={label} value={[c.name, c.clinic, c.phone].filter(Boolean).join(' · ')} />
          ) : null)}
        </dl>
      </>}

      {emergencyContacts.length > 0 && <>
        <h3>Emergency contacts</h3>
        <dl className="facts">
          {emergencyContacts.map((c, i) => (
            <Fact key={i} label={c.relationship || 'Contact'} value={[c.name, c.phone].filter(Boolean).join(' · ')} />
          ))}
        </dl>
      </>}

      {r.notes.trim() && <><h3>Notes from the patient</h3><p className="notes">{r.notes}</p></>}
      {r.updated_at && <p className="muted">Last updated by the patient {new Date(r.updated_at).toLocaleDateString()}.</p>}
    </div>
  )
}
