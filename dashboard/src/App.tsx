import { useState } from 'react'
import Connect from './Connect'
import PatientView from './PatientView'
import type { Session } from './api'

const KEY = 'kineon.file-session'

// The local clinic credential and any live link last for the browser tab, including reloads.
function load(): Session | null {
  try {
    const raw = sessionStorage.getItem(KEY)
    return raw ? (JSON.parse(raw) as Session) : null
  } catch {
    return null
  }
}

function resetViewPosition() {
  if (window.location.hash) window.history.replaceState(null, '', window.location.pathname + window.location.search)
  window.scrollTo(0, 0)
}

export default function App() {
  const [session, setSession] = useState<Session | null>(load)
  const [notice, setNotice] = useState<string | null>(null)

  const open = (s: Session) => {
    sessionStorage.setItem(KEY, JSON.stringify(s))
    setNotice(null)
    setSession(s)
    resetViewPosition()
  }
  const close = (message?: string) => {
    sessionStorage.removeItem(KEY)
    setNotice(message ?? null)
    setSession(null)
    resetViewPosition()
  }

  return session
    ? <PatientView key={session.patientId} session={session} onExit={close} onLive={(live) => {
      const updated = { ...session, live }
      sessionStorage.setItem(KEY, JSON.stringify(updated))
      setSession(updated)
    }} />
    : <Connect notice={notice} onReady={open} />
}
