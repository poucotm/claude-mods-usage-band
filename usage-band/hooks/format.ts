import type { Limit } from '../types'

export const GREEN = '#50BF65'
export const ORANGE = '#FF8C00'
export const RED = 'red'
export const BLUE = '#3B82F6'

export const usageColor = (percent: number) =>
  percent >= 90 ? RED : percent >= 80 ? ORANGE : GREEN

const pct = (n: number) => `${Math.round(n)}%`

// Subscription (Pro): the weekly window; enterprise: the monthly spend limit.
// With neither, the monthly credit figure the usage API reports, when there is one.
export const usageParts = (
  limits: Limit[],
  monthly?: number,
): { text: string; percent: number }[] => {
  const limit =
    limits.find(l => l.kind === 'seven_day') ?? limits.find(l => l.kind === 'spend_limit')

  if (limit) {
    return [{ text: pct(limit.percentUsed), percent: limit.percentUsed }]
  }

  return monthly === undefined ? [] : [{ text: pct(monthly), percent: monthly }]
}

const num = (value: unknown) => (typeof value === 'number' && Number.isFinite(value) ? value : undefined)

// The usage API's answer: the weekly window (subscriptions) and the monthly figure, each as a
// percentage. Monthly is the enterprise spend (`spend.percent`), else the extra-usage credits
// (used / limit, as the desktop app computes them, else the utilization the answer reports).
export const parseUsage = (text: string): { weekly?: number; monthly?: number } => {
  try {
    const body = JSON.parse(text)
    const extra = body?.extra_usage
    const used = num(extra?.used_credits)
    const limit = num(extra?.monthly_limit)
    const monthly =
      num(body?.spend?.percent) ??
      (extra?.is_enabled && used !== undefined && limit !== undefined && limit > 0
        ? (used / limit) * 100
        : num(extra?.utilization))

    return { weekly: num(body?.seven_day?.utilization), monthly }
  } catch {
    return {}
  }
}

const trim = (n: number) => (Math.round(n * 10) / 10).toString()

export const tokens = (n: number) =>
  n >= 1_000_000 ? `${trim(n / 1_000_000)}m` : n >= 1000 ? `${trim(n / 1000)}k` : `${n}`

// The short form leaves out the "Context" label.
export const contextText = (used: number, window: number, percent: number, isShort = false) =>
  `${isShort ? '' : 'Context '}${tokens(used)}/${tokens(window)} (${Math.round(percent)}%)`

// The saved effort level: the model's own entry in modelSettings, else the global one.
export const effortLevel = (settings: Record<string, unknown>, model: string): string | null => {
  const perModel = settings.modelSettings as
    | Record<string, { effortLevel?: unknown } | undefined>
    | undefined
  const level = perModel?.[model.replace(/\[.*\]$/, '')]?.effortLevel ?? settings.effortLevel

  return typeof level === 'string' ? level : null
}

// Effort level: xhigh/max 🡑 red, high 🡑 orange, medium - green, low 🡓 blue; anything else none.
export const effortMark = (level: string | null): { mark: string; color: string } | null =>
  level === 'low'
    ? { mark: '🡓', color: BLUE }
    : level === 'medium'
      ? { mark: '-', color: GREEN }
      : level === 'high'
        ? { mark: '🡑', color: ORANGE }
        : level === 'xhigh' || level === 'max'
          ? { mark: '🡑', color: RED }
          : null

// The prompt cache lives this long after the last request (Claude Code's subscription TTL).
export const CACHE_TTL_MS = 3_600_000

// Minutes the prompt cache has left: none before the first turn, a red 0m once lapsed;
// green above 20 minutes, orange above 5, red below. The short form leaves out the "Cache" label.
export const cacheMark = (
  minutesLeft: number | null,
  isShort = false,
): { text: string; color: string } | null => {
  if (minutesLeft === null) {
    return null
  }

  const label = isShort ? '' : 'Cache '

  if (minutesLeft <= 0) {
    return { text: `${label}0m`, color: RED }
  }

  const color = minutesLeft > 20 ? GREEN : minutesLeft > 5 ? ORANGE : RED

  return { text: `${label}${minutesLeft < 1 ? '<1m' : `${Math.floor(minutesLeft)}m`}`, color }
}

// "claude-sonnet-5-5[1m]" -> "Sonnet 5.5"; a display name passes through.
export const modelName = (raw: string) => {
  const match = /claude-(opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?(?!\d)/i.exec(raw)

  if (!match) {
    return raw.replace(/\s*\(.*\)\s*$/, '').trim()
  }

  const family = match[1][0].toUpperCase() + match[1].slice(1).toLowerCase()

  return match[3] ? `${family} ${match[2]}.${match[3]}` : `${family} ${match[2]}`
}
