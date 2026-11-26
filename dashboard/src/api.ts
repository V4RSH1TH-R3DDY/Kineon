import type { components } from './api-types'

type S = components['schemas']
export type Timeline = S['Timeline']
export type TimelinePoint = S['TimelinePoint']
export type Baseline = S['Baseline']
export type Report = S['Report']
export type ReviewItem = S['ReviewItem']
export type VerifyResult = S['VerifyResult']
export type MedicalRecord = S['MedicalRecord']
export type LinkCreated = S['LinkCreated']
export type LinkStatus = S['LinkStatus']
export type Lang = NonNullable<S['Report']['lang']>
export type Verdict = S['ReviewVerdict']['label']
export type ExportFormat = 'pdf' | 'csv' | 'png'

export type LiveLink = { token: string; linkId: string; claimSecret: string }
export type Session = { patientId: string; clinicKey: string | null; live?: LiveLink }

export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

const enc = encodeURIComponent

async function check(res: Response): Promise<Response> {
  if (res.ok) return res
  const body = await res.json().catch(() => null)
  const detail = typeof body?.detail === 'string' ? body.detail : res.statusText
  throw new ApiError(res.status, detail)
}

const json = async <T>(res: Response): Promise<T> => (await check(res)).json()

function call(method: string, url: string, opts: { clinicKey?: string | null; token?: string; claim?: string; body?: unknown } = {}) {
  const headers: Record<string, string> = {}
  if (opts.body !== undefined) headers['Content-Type'] = 'application/json'
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`
  if (opts.clinicKey) headers['X-Clinic-Key'] = opts.clinicKey
  if (opts.claim) headers['X-Claim-Secret'] = opts.claim
  return fetch(url, { method, headers, cache: 'no-store', body: opts.body === undefined ? undefined : JSON.stringify(opts.body) })
}

/** Asking a patient for access. The doctor reads the code to the patient, who approves it in their app. */
export const link = {
  request: (patientId: string, doctorName: string, clinicKey: string) =>
    call('POST', '/v1/links', { clinicKey, body: { patient_id: patientId, doctor_name: doctorName } }).then(json<LinkCreated>),
  status: (linkId: string, claim: string) => call('GET', `/v1/links/${enc(linkId)}`, { claim }).then(json<LinkStatus>),
  confirm: (linkId: string, claim: string) =>
    call('POST', `/v1/links/${enc(linkId)}/confirm`, { claim }).then(json<{ token: string; expires_at: string }>),
  end: (linkId: string, claim: string) => call('DELETE', `/v1/links/${enc(linkId)}`, { claim }).then(check),
}

export function doctorApi(patientId: string, clinicKey: string | null) {
  const base = `/v1/doctor/patients/${enc(patientId)}`
  const access = { clinicKey }
  return {
    timeline: () => call('GET', `${base}/timeline`, access).then(json<Timeline>),
    baseline: () => call('GET', `${base}/baseline`, access).then(json<Baseline>),
    live: (token: string) => call('GET', `${base}/live`, { ...access, token }).then(json<TimelinePoint | null>),
    record: () =>
      call('GET', `${base}/record`, access).then(async (r) => {
        if (r.status === 404) return null
        return json<MedicalRecord>(r)
      }),
    report: (lang: Lang) => call('POST', `${base}/report?lang=${lang}`, access).then(json<Report>),
    queue: () => call('GET', `${base}/review-queue`, access).then(json<ReviewItem[]>),
    verdict: (id: string, label: Verdict) =>
      call('POST', `${base}/review-queue/${enc(id)}`, { ...access, body: { label } }).then(check),
    exportFile: async (format: ExportFormat) => {
      const res = await check(await call('POST', `${base}/export?format=${format}`, access))
      return { blob: await res.blob(), digest: res.headers.get('X-Report-Digest') ?? '' }
    },
  }
}

export const verify = (digest: string) => call('GET', `/v1/verify/${enc(digest)}`).then(json<VerifyResult>)

// Hashing happens in the browser, so the file itself is never uploaded to check it.
export async function sha256Hex(buf: ArrayBuffer): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', buf))
  return Array.from(h, (b) => b.toString(16).padStart(2, '0')).join('')
}
