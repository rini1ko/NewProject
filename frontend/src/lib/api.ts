import { signOut } from 'aws-amplify/auth'
import { format } from 'date-fns'

import { getIdToken } from '@/lib/auth'

export type Participant = {
  id: string
  name: string
  email: string
}

export type Meeting = {
  id: string
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participants: Participant[]
  created_at: string
}

export type MeetingCreate = {
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participant_ids: string[]
}

export type ParticipantCreate = {
  name: string
  email: string
}

export type AgendaItem = { topic: string; owner: string | null; minutes: number | null }
export type ActionItem = { task: string; owner: string | null; due: string | null }

/** What the parser suggested; sent back with Save so the API can compare it with the result. */
export type AiSuggestion = {
  model: string
  prompt_version: string
  agenda: ParsedAgenda
}

export type Agenda = {
  items: AgendaItem[]
  action_items: ActionItem[]
  ai_suggestion: AiSuggestion | null
  updated_at: string | null
}

export type AgendaWrite = {
  items: AgendaItem[]
  action_items: ActionItem[]
  ai_suggestion: AiSuggestion | null
}

export type ParsedAgenda = {
  title: string | null
  starts_at: string | null
  duration_minutes: number | null
  items: AgendaItem[]
  action_items: ActionItem[]
  language: string
}

export type ParseResult = { agenda: ParsedAgenda; model: string; prompt_version: string }

export class ApiError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

// Backend origin, set at build time for AWS (the Lambda function URL). Empty locally,
// where the Vite dev server or nginx proxies /api to the backend.
const API_URL = (import.meta.env.VITE_API_URL ?? '').replace(/\/+$/, '')

type ValidationIssue = { loc?: (string | number)[]; msg: string }

function errorMessage(detail: unknown, fallback: string): string {
  if (typeof detail === 'string') return detail
  if (Array.isArray(detail)) {
    return (detail as ValidationIssue[])
      .map((issue) => {
        const field = issue.loc?.filter((part) => part !== 'body').join('.')
        const msg = issue.msg.replace(/^Value error, /, '')
        return field ? `${field}: ${msg}` : msg
      })
      .join('; ')
  }
  return fallback
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const token = await getIdToken()
  const response = await fetch(`${API_URL}/api${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(token && { Authorization: `Bearer ${token}` }),
      ...init?.headers,
    },
  })

  // The session is gone (revoked, or the refresh token expired): sign out, which sends the
  // user back to the login page (see AuthProvider).
  if (response.status === 401) await signOut().catch(() => undefined)

  if (!response.ok) {
    let detail: unknown
    try {
      detail = (await response.json()).detail
    } catch {
      // body was not JSON
    }
    throw new ApiError(response.status, errorMessage(detail, response.statusText))
  }

  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

// The agenda parser is a separate Lambda (outside the VPC). It only suggests; saving goes
// through the normal API. Empty when the parser is not deployed (local runs).
export const PARSER_URL = (import.meta.env.VITE_PARSER_URL ?? '') as string
export const MAX_PASTE_CHARS = 10_000

export type ParseErrorCode =
  | 'not_configured'
  | 'too_long'
  | 'no_agenda'
  | 'busy'
  | 'upstream'
  | 'unauthorized'
  | 'network'
  | 'bad_request'

export class ParseError extends Error {
  readonly code: ParseErrorCode

  constructor(code: ParseErrorCode, message: string) {
    super(message)
    this.code = code
  }
}

export const PARSE_ERROR_MESSAGES: Record<ParseErrorCode, string> = {
  not_configured: 'Paste an agenda is not available here. Type the agenda by hand.',
  too_long: `The text is too long (the limit is ${MAX_PASTE_CHARS.toLocaleString('en')} characters). Paste a shorter part.`,
  no_agenda: 'No agenda found in this text. Paste an agenda, or type it by hand.',
  busy: 'The AI service is busy right now. Try again in a minute, or type the agenda by hand.',
  upstream: 'The AI service is unavailable. You can still type the agenda by hand.',
  unauthorized: 'Your session has expired. Sign in again.',
  network: 'Could not reach the server. Check your connection and try again.',
  bad_request: 'The request was not accepted. Check the text and try again.',
}

/** Asks the parser for a suggestion. `today` and `tz` are the user's, not the server's. */
export async function parseAgenda(text: string, signal: AbortSignal): Promise<ParseResult> {
  if (!PARSER_URL) throw new ParseError('not_configured', PARSE_ERROR_MESSAGES.not_configured)
  const token = await getIdToken()
  let response: Response
  try {
    response = await fetch(PARSER_URL, {
      method: 'POST',
      signal,
      headers: {
        'Content-Type': 'application/json',
        ...(token && { Authorization: `Bearer ${token}` }),
      },
      body: JSON.stringify({
        text,
        today: format(new Date(), 'yyyy-MM-dd'),
        tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      }),
    })
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw error
    throw new ParseError('network', PARSE_ERROR_MESSAGES.network)
  }
  if (response.ok) return response.json() as Promise<ParseResult>

  let code: string | undefined
  try {
    code = (await response.json()).error
  } catch {
    // body was not JSON (e.g. a gateway error)
  }
  const known = code && code in PARSE_ERROR_MESSAGES ? (code as ParseErrorCode) : undefined
  const fallback: ParseErrorCode = response.status === 429 ? 'busy' : 'upstream'
  const finalCode = known ?? fallback
  throw new ParseError(finalCode, PARSE_ERROR_MESSAGES[finalCode])
}

export const api = {
  listMeetings: () => request<Meeting[]>('/meetings'),
  createMeeting: (data: MeetingCreate) =>
    request<Meeting>('/meetings', { method: 'POST', body: JSON.stringify(data) }),
  updateMeeting: ({ id, ...data }: MeetingCreate & { id: string }) =>
    request<Meeting>(`/meetings/${id}`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteMeeting: (id: string) => request<void>(`/meetings/${id}`, { method: 'DELETE' }),
  getAgenda: (meetingId: string) => request<Agenda>(`/meetings/${meetingId}/agenda`),
  saveAgenda: ({ meetingId, ...data }: AgendaWrite & { meetingId: string }) =>
    request<Agenda>(`/meetings/${meetingId}/agenda`, { method: 'PUT', body: JSON.stringify(data) }),
  listParticipants: () => request<Participant[]>('/participants'),
  createParticipant: (data: ParticipantCreate) =>
    request<Participant>('/participants', { method: 'POST', body: JSON.stringify(data) }),
}
