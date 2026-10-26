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

export const parseMonthly = (text: string): number | undefined => {
  try {
    const percent = JSON.parse(text)?.extra_usage?.utilization

    return typeof percent === 'number' ? percent : undefined
  } catch {
    return undefined
  }
}

const trim = (n: number) => (Math.round(n * 10) / 10).toString()

export const tokens = (n: number) =>
  n >= 1_000_000 ? `${trim(n / 1_000_000)}m` : n >= 1000 ? `${trim(n / 1000)}k` : `${n}`

export const contextText = (used: number, window: number, percent: number) =>
  `Context ${tokens(used)}/${tokens(window)} (${Math.round(percent)}%)`

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

// "claude-sonnet-5-5[1m]" -> "Sonnet 5.5"; a display name passes through.
export const modelName = (raw: string) => {
  const match = /claude-(opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?(?!\d)/i.exec(raw)

  if (!match) {
    return raw.replace(/\s*\(.*\)\s*$/, '').trim()
  }

  const family = match[1][0].toUpperCase() + match[1].slice(1).toLowerCase()

  return match[3] ? `${family} ${match[2]}.${match[3]}` : `${family} ${match[2]}`
}
