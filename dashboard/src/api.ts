import type { components } from './api-types'

type S = components['schemas']
export type Timeline = S['Timeline']
export type Baseline = S['Baseline']
export type Report = S['Report']
export type ReviewItem = S['ReviewItem']
export type VerifyResult = S['VerifyResult']
export type Lang = NonNullable<S['Report']['lang']>
export type Verdict = S['ReviewVerdict']['label']
export type ExportFormat = 'pdf' | 'csv' | 'png'

const enc = encodeURIComponent

async function check(res: Response): Promise<Response> {
  if (res.ok) return res
  const body = await res.json().catch(() => null)
  const detail = typeof body?.detail === 'string' ? body.detail : res.statusText
  throw new Error(`${res.status} ${detail}`)
}

const json = async <T>(res: Response): Promise<T> => (await check(res)).json()
const post = (url: string, body?: unknown) =>
  fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })

export const api = {
  timeline: (pid: string) => fetch(`/v1/patients/${enc(pid)}/timeline`).then(json<Timeline>),
  baseline: (pid: string) => fetch(`/v1/patients/${enc(pid)}/baseline`).then(json<Baseline>),
  report: (pid: string, lang: Lang) => post(`/v1/patients/${enc(pid)}/report?lang=${lang}`).then(json<Report>),
  queue: () => fetch('/v1/review-queue').then(json<ReviewItem[]>),
  verdict: (id: string, label: Verdict) => post(`/v1/review-queue/${enc(id)}`, { label }).then(check),
  consent: (pid: string) => post(`/v1/patients/${enc(pid)}/consent`).then(json<{ consent_id: string }>),
  revoke: (pid: string, cid: string) =>
    fetch(`/v1/patients/${enc(pid)}/consent/${enc(cid)}`, { method: 'DELETE' }).then(check),
  exportFile: async (pid: string, format: ExportFormat, consentId: string) => {
    const res = await check(await post(`/v1/patients/${enc(pid)}/export?format=${format}`, { consent_id: consentId }))
    return { blob: await res.blob(), digest: res.headers.get('X-Report-Digest') ?? '' }
  },
  verify: (digest: string) => fetch(`/v1/verify/${enc(digest)}`).then(json<VerifyResult>),
}

// Hashing happens in the browser, so the file itself is never uploaded to check it.
export async function sha256Hex(buf: ArrayBuffer): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', buf))
  return Array.from(h, (b) => b.toString(16).padStart(2, '0')).join('')
}
