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
  effortLevel,
  effortMark,
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
const effort = atom({ plugin: 'usage-band', key: 'effort' } as const, null)

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

// Terminals Claude Code runs in: while one of them is the foreground window, the person is
// taken to be watching and no notification is raised. VS Code is told apart by window: only
// a window whose title names the session's project folder counts as watching.
const TERMINALS = ['WindowsTerminal', 'powershell', 'pwsh', 'conhost', 'OpenConsole']

// The Windows app the toast is sent as: registered under the current user as "Claude Code Notification".
const APP_ID = 'ClaudeCode.Usage-Band'

// The notification lines: an answer that finished, and a prompt that waits on the person.
const ANSWER_COMPLETE = 'Answer Complete'
const WAITING = 'Waiting for your answer'

// A permission prompt and a question dialog can both stand for one ask: the second within
// this many milliseconds of the first raises no toast of its own.
const ASK_QUIET_MS = 3000
let lastAskAt = 0

// Claude Code's window handle, from the last prompt; '' until one was typed.
let claudeWindow = ''

// A permission prompt (Yes/No) or a question dialog: Claude waits on the person.
async function notifyAsk($: EngineInterface) {
  const now = await $.clock.now()

  if (now - lastAskAt >= ASK_QUIET_MS) {
    lastAskAt = now
    void notifyIfAway($, WAITING)
  }
}

// A Windows toast of `message`, unless Claude Code's window is in front. The logo is
// claude.png in the mod's folder; without it the toast has no logo.
async function notifyIfAway($: EngineInterface, message: string) {
  try {
    const folder = (await $.session.root()).split(/[\\/]/).filter(Boolean).pop() ?? ''
    const logo = `${$.plugin.root}/claude.png`.replace(/'/g, "''")
    const focus = `${$.plugin.root}/focus.vbs`.replace(/'/g, "''")
    const body = `${message} (${folder})`
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/'/g, "''")
    const project = folder.replace(/'/g, "''")
    const terminals = TERMINALS.map(name => `'${name}'`).join(',')
    const script = [
      `Add-Type -Namespace W -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow(); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint p); [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);'`,
      `$hwnd = [W.U]::GetForegroundWindow()`,
      `$fgPid = 0`,
      `[void][W.U]::GetWindowThreadProcessId($hwnd, [ref]$fgPid)`,
      `$name = (Get-Process -Id $fgPid -ErrorAction SilentlyContinue).ProcessName`,
      `$title = New-Object System.Text.StringBuilder 512`,
      `[void][W.U]::GetWindowText($hwnd, $title, 512)`,
      `$project = '${project}'`,
      `if ($name -eq 'Code' -and $project -and $title.ToString().IndexOf($project, [StringComparison]::OrdinalIgnoreCase) -ge 0) { exit }`,
      `if (@(${terminals}) -contains $name) { exit }`,
      `$logo = '${logo}'`,
      `if (-not (Test-Path $logo)) { $logo = $null }`,
      `$key = 'HKCU:\\Software\\Classes\\AppUserModelId\\${APP_ID}'`,
      `if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }`,
      `Set-ItemProperty -Path $key -Name DisplayName -Value 'Claude Code Notification'`,
      `if ($logo) { Set-ItemProperty -Path $key -Name IconUri -Value ($logo -replace '/', '\\') }`,
      `$image = if ($logo) { "<image placement='appLogoOverride' src='" + ([Uri]$logo).AbsoluteUri + "'/>" } else { '' }`,
      `$body = '${body}'`,
      `[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]`,
      `[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]`,
      `$xml = New-Object Windows.Data.Xml.Dom.XmlDocument`,
      `$focus = '${focus}'`,
      `$launch = ''`,
      `$protocol = 'HKCU:\\Software\\Classes\\usageband-focus'`,
      `if ('${claudeWindow}' -and (Test-Path $focus)) { New-Item -Path "$protocol\\shell\\open\\command" -Force | Out-Null; Set-ItemProperty -Path $protocol -Name '(default)' -Value 'URL:usage-band focus'; Set-ItemProperty -Path $protocol -Name 'URL Protocol' -Value ''; Set-ItemProperty -Path "$protocol\\shell\\open\\command" -Name '(default)' -Value ('wscript.exe "' + $focus + '" "%1"'); $launch = " activationType='protocol' launch='usageband-focus:${claudeWindow}'" }`,
      `$xml.LoadXml("<toast$launch><visual><binding template='ToastGeneric'>$image<text>Claude Code</text><text>$body</text></binding></visual></toast>")`,
      `[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('${APP_ID}').Show([Windows.UI.Notifications.ToastNotification]::new($xml))`,
    ].join('; ')

    await runPowerShell($, script)
  } catch {
    // No notification is better than a failed turn.
  }
}

// Runs a PowerShell script and returns what it printed. -EncodedCommand (Base64 of
// UTF-16LE) so Windows argument quoting cannot strip the script's quotes.
async function runPowerShell($: EngineInterface, script: string) {
  let utf16 = ''

  for (let i = 0; i < script.length; i++) {
    const code = script.charCodeAt(i)
    utf16 += String.fromCharCode(code & 0xff, code >> 8)
  }

  const { stdout } = await $.process.run([
    'powershell',
    '-NoProfile',
    '-NonInteractive',
    '-EncodedCommand',
    btoa(utf16),
  ])

  return stdout
}

// The window the person typed the prompt in, which is Claude Code's: a click on the
// notification brings it back to the front.
async function rememberWindow($: EngineInterface) {
  try {
    const handle = await runPowerShell(
      $,
      `Add-Type -Namespace W -Name H -MemberDefinition '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();'; [W.H]::GetForegroundWindow().ToInt64()`,
    )

    if (/^\d+$/.test(handle.trim())) {
      claudeWindow = handle.trim()
    }
  } catch {
    // Without it the notification just isn't clickable.
  }
}

const EFFORT_LEVELS = ['low', 'medium', 'high', 'xhigh', 'max']

// The level the last `/effort <level>` set, which the settings do not hold when it was for
// this session only; null until one was typed.
let typedEffort: string | null = null

// The effort level in use: the last one typed, else the one saved in the settings.
async function refreshEffort($: EngineInterface) {
  try {
    const settings = await $.settings.read()
    const model = await $.session.model()
    await update($, effort, () => typedEffort ?? effortLevel(settings, model))
  } catch {
    // No effort mark is better than a failed turn.
  }
}

// The band itself: usage, context, model, effort and the busy/idle dot, in one row.
async function drawBand($: EngineInterface, e: ResolveInput, justifyContent: Justify) {
  const snap = await read($, usage)
  const busy = await read($, isBusy)
  const blinkOn = await read($, isBlinkOn)
  const model = modelName(await $.session.model())
  const level = effortMark(await read($, effort))
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
      {level ? (
        <Text>
          <Text color={level.color}>[{level.mark}]</Text>
          <Text> </Text>
        </Text>
      ) : null}
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
    void refreshEffort($)

    return result
  })

  on('session.measure', async ($, e, next) => {
    await update($, usage, () => snapshot(e.context, e.rateLimits))
    await refreshMonthly($)

    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    void rememberWindow($)
    void refreshEffort($)

    return next(e)
  })

  // `/effort <level>` shows at once; `/effort` alone opens a menu, whose pick the settings hold.
  on('command.run', { command: 'effort' }, async ($, e, next) => {
    const result = await next(e)
    const level = e.args.trim().toLowerCase()

    typedEffort = EFFORT_LEVELS.includes(level) ? level : null
    void refreshEffort($)

    return result
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
      void notifyIfAway($, ANSWER_COMPLETE)
      await refreshMonthly($)
    }

    return next(e)
  })

  on('classic.PermissionRequest', async ($, e, next) => {
    if (e.agent_id === undefined) {
      await notifyAsk($)
    }

    return next(e)
  })

  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    await notifyAsk($)

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
