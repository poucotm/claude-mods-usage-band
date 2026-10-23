export type Limit = { kind: string; percentUsed: number }

export type Snapshot = {
  limits: Limit[]
  tokens: number
  window: number
  percent: number
}

declare module 'claude-code' {
  interface PluginState {
    'usage-band': {
      usage: Snapshot | null
      monthly: number | null
      isBusy: boolean
      isBlinkOn: boolean
      effort: string | null
    }
  }
}
