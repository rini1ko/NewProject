import { useEffect, useRef, useState } from 'react'
import { format, parseISO } from 'date-fns'
import { Loader2Icon, PlusIcon, SparklesIcon, Trash2Icon, XIcon } from 'lucide-react'
import { toast } from 'sonner'

import { Alert, AlertDescription } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { useAgenda, useSaveAgenda } from '@/hooks/queries'
import {
  ApiError,
  MAX_PASTE_CHARS,
  PARSER_URL,
  ParseError,
  parseAgenda,
  type AiSuggestion,
  type Meeting,
  type ParsedAgenda,
} from '@/lib/api'

// A field the model filled stays marked "suggested" until the person touches it.
type ItemRow = {
  key: number
  topic: string
  owner: string
  minutes: string
  suggested: { topic?: boolean; owner?: boolean; minutes?: boolean }
}
type ActionRow = {
  key: number
  task: string
  owner: string
  due: string
  suggested: { task?: boolean; owner?: boolean; due?: boolean }
}

let nextKey = 1

const blankItem = (): ItemRow => ({ key: nextKey++, topic: '', owner: '', minutes: '', suggested: {} })
const blankAction = (): ActionRow => ({ key: nextKey++, task: '', owner: '', due: '', suggested: {} })

function itemsFromParsed(parsed: ParsedAgenda): ItemRow[] {
  return parsed.items.map((item) => ({
    key: nextKey++,
    topic: item.topic,
    owner: item.owner ?? '',
    minutes: item.minutes?.toString() ?? '',
    // Only what the model actually filled is marked; empty fields stay empty and unmarked.
    suggested: {
      topic: true,
      owner: item.owner != null,
      minutes: item.minutes != null,
    },
  }))
}

function actionsFromParsed(parsed: ParsedAgenda): ActionRow[] {
  return parsed.action_items.map((item) => ({
    key: nextKey++,
    task: item.task,
    owner: item.owner ?? '',
    due: item.due ?? '',
    suggested: { task: true, owner: item.owner != null, due: item.due != null },
  }))
}

function Suggested({ show }: { show?: boolean }) {
  if (!show) return null
  return (
    <Badge variant="secondary" className="h-5 gap-1 px-2 text-[0.7rem]">
      <SparklesIcon />
      suggested
    </Badge>
  )
}

/** What the text said about the meeting itself; shown as information, the meeting is not changed. */
function describeMeetingHints(parsed: ParsedAgenda): string | null {
  const parts: string[] = []
  if (parsed.starts_at) {
    try {
      parts.push(format(parseISO(parsed.starts_at), 'EEE, d MMM yyyy HH:mm'))
    } catch {
      parts.push(parsed.starts_at)
    }
  }
  if (parsed.duration_minutes) parts.push(`${parsed.duration_minutes} min`)
  if (parsed.title) parts.push(`“${parsed.title}”`)
  return parts.length ? parts.join(' · ') : null
}

type Props = {
  meeting: Meeting | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function AgendaDialog({ meeting, open, onOpenChange }: Props) {
  const meetingId = meeting?.id ?? null
  const agenda = useAgenda(meetingId, open)
  const save = useSaveAgenda()

  const [pasted, setPasted] = useState('')
  const [items, setItems] = useState<ItemRow[]>([])
  const [actions, setActions] = useState<ActionRow[]>([])
  const [suggestion, setSuggestion] = useState<AiSuggestion | null>(null)
  const [meetingHints, setMeetingHints] = useState<string | null>(null)
  const [parsing, setParsing] = useState(false)
  const [seconds, setSeconds] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [saveError, setSaveError] = useState<string | null>(null)
  const abortRef = useRef<AbortController | null>(null)
  const loadedFor = useRef<string | null>(null)

  // Load the saved agenda into the form once per opening.
  useEffect(() => {
    if (!open) {
      loadedFor.current = null
      return
    }
    if (agenda.data && loadedFor.current !== meetingId) {
      loadedFor.current = meetingId
      setItems(
        agenda.data.items.map((item) => ({
          key: nextKey++,
          topic: item.topic,
          owner: item.owner ?? '',
          minutes: item.minutes?.toString() ?? '',
          suggested: {},
        }))
      )
      setActions(
        agenda.data.action_items.map((item) => ({
          key: nextKey++,
          task: item.task,
          owner: item.owner ?? '',
          due: item.due ?? '',
          suggested: {},
        }))
      )
      setPasted('')
      setSuggestion(null)
      setMeetingHints(null)
      setError(null)
      setSaveError(null)
    }
  }, [open, meetingId, agenda.data])

  // Elapsed seconds while waiting, so the page never looks frozen.
  useEffect(() => {
    if (!parsing) return
    setSeconds(0)
    const timer = setInterval(() => setSeconds((s) => s + 1), 1000)
    return () => clearInterval(timer)
  }, [parsing])

  // Closing the dialog cancels a request in flight.
  useEffect(() => {
    if (!open) abortRef.current?.abort()
  }, [open])

  const tooLong = pasted.length > MAX_PASTE_CHARS
  const parserAvailable = PARSER_URL !== ''

  async function onParse() {
    const controller = new AbortController()
    abortRef.current = controller
    setParsing(true)
    setError(null)
    try {
      const result = await parseAgenda(pasted.trim(), controller.signal)
      setItems(itemsFromParsed(result.agenda))
      setActions(actionsFromParsed(result.agenda))
      setMeetingHints(describeMeetingHints(result.agenda))
      setSuggestion({
        model: result.model,
        prompt_version: result.prompt_version,
        agenda: result.agenda,
      })
    } catch (e) {
      if (e instanceof DOMException && e.name === 'AbortError') return // the person pressed Cancel
      setError(e instanceof ParseError ? e.message : 'Something went wrong. Try again.')
    } finally {
      setParsing(false)
    }
  }

  function onCancel() {
    abortRef.current?.abort()
    setParsing(false)
  }

  function updateItem(key: number, field: 'topic' | 'owner' | 'minutes', value: string) {
    setItems((rows) =>
      rows.map((r) =>
        r.key === key ? { ...r, [field]: value, suggested: { ...r.suggested, [field]: false } } : r
      )
    )
  }

  function updateAction(key: number, field: 'task' | 'owner' | 'due', value: string) {
    setActions((rows) =>
      rows.map((r) =>
        r.key === key ? { ...r, [field]: value, suggested: { ...r.suggested, [field]: false } } : r
      )
    )
  }

  async function onSave() {
    if (!meeting) return
    setSaveError(null)
    const cleanItems = items
      .filter((r) => r.topic.trim())
      .map((r) => ({
        topic: r.topic.trim(),
        owner: r.owner.trim() || null,
        minutes: r.minutes.trim() ? Number(r.minutes) : null,
      }))
    const cleanActions = actions
      .filter((r) => r.task.trim())
      .map((r) => ({
        task: r.task.trim(),
        owner: r.owner.trim() || null,
        due: r.due || null,
      }))
    if (cleanItems.some((i) => i.minutes !== null && !(Number.isInteger(i.minutes) && i.minutes >= 1 && i.minutes <= 480))) {
      setSaveError('Minutes must be a whole number between 1 and 480.')
      return
    }
    try {
      await save.mutateAsync({
        meetingId: meeting.id,
        items: cleanItems,
        action_items: cleanActions,
        // The suggestion travels with the save: the difference between it and what the person
        // saved is the quality signal of the feature.
        ai_suggestion: suggestion,
      })
      toast.success('Agenda saved')
      onOpenChange(false)
    } catch (e) {
      setSaveError(e instanceof ApiError ? e.message : 'Could not save the agenda. Try again.')
    }
  }

  const hasContent = items.length > 0 || actions.length > 0

  return (
    <Dialog open={open && meeting !== null} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle className="pr-8 text-2xl leading-tight">
            Agenda{meeting ? `: ${meeting.title}` : ''}
          </DialogTitle>
          <DialogDescription>
            Paste an email, a chat message or notes. The AI suggests an agenda; you check it and
            press Save.
          </DialogDescription>
        </DialogHeader>

        <div className="-mx-6 flex flex-col gap-5 overflow-y-auto px-6">
          {/* ---- Paste */}
          <div className="flex flex-col gap-2">
            <label htmlFor="agenda-paste" className="text-sm font-semibold">
              Paste an agenda
            </label>
            <Textarea
              id="agenda-paste"
              rows={4}
              value={pasted}
              disabled={parsing || !parserAvailable}
              placeholder="Пн 10:00, синк по прайсингу, 45 хв. 1) нові тарифи Pro — Олена, 15 хв …"
              onChange={(e) => setPasted(e.target.value)}
              aria-invalid={tooLong}
            />
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span
                className={`text-xs ${tooLong ? 'text-destructive' : 'text-muted-foreground'}`}
              >
                {pasted.length.toLocaleString('en')} / {MAX_PASTE_CHARS.toLocaleString('en')}
              </span>
              {parsing ? (
                <div className="flex items-center gap-3" role="status">
                  <span className="flex items-center gap-2 text-sm text-muted-foreground">
                    <Loader2Icon className="size-4 animate-spin" />
                    Reading the text… {seconds}s
                  </span>
                  <Button variant="outline" size="sm" onClick={onCancel}>
                    <XIcon />
                    Cancel
                  </Button>
                </div>
              ) : (
                <Button
                  variant="secondary"
                  onClick={onParse}
                  disabled={!parserAvailable || pasted.trim() === '' || tooLong}
                >
                  <SparklesIcon />
                  Parse
                </Button>
              )}
            </div>
            {!parserAvailable && (
              <p className="text-sm text-muted-foreground">
                Paste an agenda is not set up in this environment. You can type the agenda below.
              </p>
            )}
            {error && (
              <Alert variant="destructive" role="alert">
                <AlertDescription>{error}</AlertDescription>
              </Alert>
            )}
          </div>

          <div className="hairline" />

          {agenda.isPending && open ? (
            <p className="flex items-center gap-2 text-muted-foreground">
              <Loader2Icon className="size-4 animate-spin" /> Loading the saved agenda…
            </p>
          ) : agenda.isError ? (
            <Alert variant="destructive">
              <AlertDescription>Could not load the saved agenda.</AlertDescription>
            </Alert>
          ) : (
            <>
              {suggestion && (
                <Alert>
                  <SparklesIcon />
                  <AlertDescription>
                    Filled in by AI. Fields marked “suggested” are guesses from your text: check
                    them. Empty fields were not in the text.
                    {meetingHints && (
                      <span className="mt-1 block">
                        The text also mentioned: {meetingHints}. The meeting itself is not changed.
                      </span>
                    )}
                  </AlertDescription>
                </Alert>
              )}

              {/* ---- Items */}
              <section className="flex flex-col gap-3">
                <h3 className="text-lg">Topics</h3>
                {items.length === 0 && (
                  <p className="text-muted-foreground">No topics yet.</p>
                )}
                {items.map((row) => (
                  <div
                    key={row.key}
                    className="grid grid-cols-[1fr_auto] gap-2 sm:grid-cols-[2fr_1fr_6rem_auto]"
                  >
                    <div className="col-span-2 flex flex-col gap-1 sm:col-span-1">
                      <Input
                        aria-label="Topic"
                        placeholder="Topic"
                        value={row.topic}
                        maxLength={300}
                        onChange={(e) => updateItem(row.key, 'topic', e.target.value)}
                      />
                      <Suggested show={row.suggested.topic} />
                    </div>
                    <div className="flex flex-col gap-1">
                      <Input
                        aria-label="Owner"
                        placeholder="Owner"
                        value={row.owner}
                        maxLength={100}
                        onChange={(e) => updateItem(row.key, 'owner', e.target.value)}
                      />
                      <Suggested show={row.suggested.owner} />
                    </div>
                    <div className="flex flex-col gap-1">
                      <Input
                        aria-label="Minutes"
                        placeholder="Min"
                        inputMode="numeric"
                        value={row.minutes}
                        onChange={(e) => updateItem(row.key, 'minutes', e.target.value)}
                      />
                      <Suggested show={row.suggested.minutes} />
                    </div>
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label="Remove topic"
                      onClick={() => setItems((rows) => rows.filter((r) => r.key !== row.key))}
                    >
                      <Trash2Icon />
                    </Button>
                  </div>
                ))}
                <div>
                  <Button variant="ghost" size="sm" onClick={() => setItems((r) => [...r, blankItem()])}>
                    <PlusIcon />
                    Add topic
                  </Button>
                </div>
              </section>

              <div className="hairline" />

              {/* ---- Action items */}
              <section className="flex flex-col gap-3">
                <h3 className="text-lg">Action items</h3>
                {actions.length === 0 && (
                  <p className="text-muted-foreground">No action items yet.</p>
                )}
                {actions.map((row) => (
                  <div
                    key={row.key}
                    className="grid grid-cols-[1fr_auto] gap-2 sm:grid-cols-[2fr_1fr_9rem_auto]"
                  >
                    <div className="col-span-2 flex flex-col gap-1 sm:col-span-1">
                      <Input
                        aria-label="Task"
                        placeholder="Task"
                        value={row.task}
                        maxLength={500}
                        onChange={(e) => updateAction(row.key, 'task', e.target.value)}
                      />
                      <Suggested show={row.suggested.task} />
                    </div>
                    <div className="flex flex-col gap-1">
                      <Input
                        aria-label="Owner"
                        placeholder="Owner"
                        value={row.owner}
                        maxLength={100}
                        onChange={(e) => updateAction(row.key, 'owner', e.target.value)}
                      />
                      <Suggested show={row.suggested.owner} />
                    </div>
                    <div className="flex flex-col gap-1">
                      <Input
                        aria-label="Due date"
                        type="date"
                        value={row.due}
                        onChange={(e) => updateAction(row.key, 'due', e.target.value)}
                      />
                      <Suggested show={row.suggested.due} />
                    </div>
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label="Remove action item"
                      onClick={() => setActions((rows) => rows.filter((r) => r.key !== row.key))}
                    >
                      <Trash2Icon />
                    </Button>
                  </div>
                ))}
                <div>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => setActions((r) => [...r, blankAction()])}
                  >
                    <PlusIcon />
                    Add action item
                  </Button>
                </div>
              </section>

              {saveError && (
                <Alert variant="destructive" role="alert">
                  <AlertDescription>{saveError}</AlertDescription>
                </Alert>
              )}
            </>
          )}
        </div>

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Close
          </Button>
          <Button onClick={onSave} disabled={save.isPending || parsing || agenda.isPending}>
            {save.isPending && <Loader2Icon className="animate-spin" />}
            {hasContent ? 'Save agenda' : 'Save empty agenda'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
