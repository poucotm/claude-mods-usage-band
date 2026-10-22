import { atom, read, update } from 'claude-code'
import type {
  EngineInterface,
  Register,
  ResolveInput,
  SessionContextUsage,
  SessionRateLimit,
  Timer,
} from 'claude-code'

import type { Snapshot } from '../types'
import {
  BLUE,
  GREEN,
  ORANGE,
  RED,
  contextText,
  modelName,
  parseMonthly,
  usageColor,
  usageParts,
} from './format'

const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage'
const MIN_REFRESH_MS = 30_000
const MAX_REFRESH_MS = 600_000

const usage = atom({ plugin: 'usage-band', key: 'usage' } as const, null)
const monthly = atom({ plugin: 'usage-band', key: 'monthly' } as const, null)
const isBusy = atom({ plugin: 'usage-band', key: 'isBusy' } as const, false)
const isBlinkOn = atom({ plugin: 'usage-band', key: 'isBlinkOn' } as const, true)

const snapshot = (context: SessionContextUsage, rateLimits: SessionRateLimit[]): Snapshot => ({
  limits: rateLimits.map(({ kind, percentUsed }) => ({ kind, percentUsed })),
  tokens: context.tokens ?? 0,
  window: context.window,
  percent: context.percent ?? 0,
})

type Justify = 'flex-start' | 'flex-end'

let lastFetchAt = 0
let refreshMs = MIN_REFRESH_MS

// A rate limit the engine does not report (monthly credits) comes from the usage API. Asked
// at most every refreshMs: a failure doubles the wait, a success restores it.
async function refreshMonthly($: EngineInterface) {
  const now = await $.clock.now()

  if (now - lastFetchAt < refreshMs) {
    return
  }

  lastFetchAt = now

  try {
    const auth = (await $.session.authorize())?.handle

    if (!auth) {
      return
    }

    const res = await $.http.fetch(USAGE_URL, {
      auth,
      headers: { 'anthropic-beta': 'oauth-2025-04-20' },
    })

    if (!res.ok) {
      refreshMs = Math.min(refreshMs * 2, MAX_REFRESH_MS)

      return
    }

    refreshMs = MIN_REFRESH_MS
    const percent = parseMonthly(res.text)

    if (percent !== undefined) {
      await update($, monthly, () => percent)
      await $.store.set('monthly', percent)
    }
  } catch {
    refreshMs = Math.min(refreshMs * 2, MAX_REFRESH_MS)
  }
}

// Programs Claude Code runs in: while one of them is the foreground window, the person is
// taken to be watching and no notification is raised.
const WATCHING = ['Code', 'WindowsTerminal', 'powershell', 'pwsh', 'conhost', 'OpenConsole']

// The Windows app the toast is sent as: registered under the current user as "Claude Code Notification".
const APP_ID = 'ClaudeCode.UsageBand'

// A Windows toast that the answer is done, unless Claude Code's window is in front. The
// logo is claude.png in the mod's folder; without it the toast has no logo.
async function notifyIfAway($: EngineInterface) {
  try {
    const folder = (await $.session.cwd()).split(/[\\/]/).filter(Boolean).pop() ?? ''
    const logo = `${$.plugin.root}/claude.png`.replace(/'/g, "''")
    const body = `Answer complete (${folder})`
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/'/g, "''")
    const watching = WATCHING.map(name => `'${name}'`).join(',')
    const script = [
      `Add-Type -Namespace W -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint p);'`,
      `$fgPid = 0`,
      `[void][W.U]::GetWindowThreadProcessId([W.U]::GetForegroundWindow(), [ref]$fgPid)`,
      `$name = (Get-Process -Id $fgPid -ErrorAction SilentlyContinue).ProcessName`,
      `if (@(${watching}) -contains $name) { exit }`,
      `$logo = '${logo}'`,
      `if (-not (Test-Path $logo)) { $logo = $null }`,
      `$key = 'HKCU:\\Software\\Classes\\AppUserModelId\\${APP_ID}'`,
      `if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }`,
      `Set-ItemProperty -Path $key -Name DisplayName -Value 'Claude Code Notification'`,
      `if ($logo) { Set-ItemProperty -Path $key -Name IconUri -Value $logo }`,
      `$image = if ($logo) { "<image placement='appLogoOverride' src='" + ([Uri]$logo).AbsoluteUri + "'/>" } else { '' }`,
      `$body = '${body}'`,
      `[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]`,
      `[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]`,
      `$xml = New-Object Windows.Data.Xml.Dom.XmlDocument`,
      `$xml.LoadXml("<toast><visual><binding template='ToastGeneric'>$image<text>Claude Code</text><text>$body</text></binding></visual></toast>")`,
      `[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('${APP_ID}').Show([Windows.UI.Notifications.ToastNotification]::new($xml))`,
    ].join('; ')

    // -EncodedCommand (Base64 of UTF-16LE) so Windows argument quoting cannot strip the script's quotes.
    let utf16 = ''

    for (let i = 0; i < script.length; i++) {
      const code = script.charCodeAt(i)
      utf16 += String.fromCharCode(code & 0xff, code >> 8)
    }

    await $.process.run(['powershell', '-NoProfile', '-NonInteractive', '-EncodedCommand', btoa(utf16)])
  } catch {
    // No notification is better than a failed turn.
  }
}

// The band itself: usage, context, model and the busy/idle dot, in one row.
async function drawBand($: EngineInterface, e: ResolveInput, justifyContent: Justify) {
  const snap = await read($, usage)
  const busy = await read($, isBusy)
  const blinkOn = await read($, isBlinkOn)
  const model = modelName(await $.session.model())
  const monthlyPercent = await read($, monthly)
  const parts = usageParts(snap?.limits ?? [], monthlyPercent ?? undefined)
  const { Box, Text } = $.ui.resolve(e)

  const dotColor = busy ? RED : GREEN
  const dot = busy && !blinkOn ? ' ' : '⬤'

  return (
    <Box flexDirection="row" justifyContent={justifyContent} width="100%">
      {parts.length > 0 ? (
        <Text>
          <Text color={usageColor(parts[0]?.percent ?? 0)}>Usage </Text>
          {parts.map((part, i) => (
            <Text key={`u${i}`} color={usageColor(part.percent)}>
              {i > 0 ? ' ' : ''}
              {part.text}
            </Text>
          ))}
          <Text>{' '}</Text>
        </Text>
      ) : null}
      <Text color={BLUE}>
        {contextText(snap?.tokens ?? 0, snap?.window ?? 0, snap?.percent ?? 0)}
        {' '}
      </Text>
      <Text color={ORANGE}>{model} </Text>
      <Text color={dotColor}>{dot}</Text>
    </Box>
  )
}

export const register: Register = (on, options) => {
  const justify: Justify = options.position === 'right' ? 'flex-end' : 'flex-start'
  const isBelow = options.position === 'below'

  let blink: Timer | undefined

  const stopBlink = () => {
    blink?.cancel()
    blink = undefined
  }

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    const { context, rateLimits } = await $.session.usage()
    await update($, usage, () => snapshot(context, rateLimits))
    await update($, isBusy, () => false)

    const saved = await $.store.get('monthly')

    if (typeof saved === 'number') {
      await update($, monthly, value => value ?? saved)
    }

    void refreshMonthly($)

    return result
  })

  on('session.measure', async ($, e, next) => {
    await update($, usage, () => snapshot(e.context, e.rateLimits))
    await refreshMonthly($)

    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      stopBlink()
      await update($, isBusy, () => true)
      await update($, isBlinkOn, () => true)
      blink = $.clock.every(500, () => {
        void update($, isBlinkOn, lit => !lit)
      })
    }

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      stopBlink()
      await update($, isBusy, () => false)
      void notifyIfAway($)
      await refreshMonthly($)
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || isBelow) {
      return next(e)
    }

    return drawBand($, e, justify)
  })

  // Below the prompt: the footer's right-hand mode labels, then the band.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    if (!isBelow) {
      return next(e)
    }

    const modes = await next(e)
    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="row">
        {e.props.modes.length > 0 ? modes : null}
        {e.props.modes.length > 0 ? <Text> </Text> : null}
        {await drawBand($, e, 'flex-end')}
        <Text> </Text>
      </Box>
    )
  })
}
