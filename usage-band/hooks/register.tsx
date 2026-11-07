import { atom, read, update } from 'claude-code'
import type {
  EngineInterface,
  Register,
  ResolveInput,
  SessionContextUsage,
  SessionRateLimit,
  Timer,
} from 'claude-code'

import type { Limit, Snapshot } from '../types'
import {
  BLUE,
  CACHE_TTL_MS,
  GREEN,
  ORANGE,
  RED,
  cacheMark,
  contextText,
  effortLevel,
  effortMark,
  modelName,
  parseUsage,
  usageColor,
  usageParts,
} from './format'

const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage'

// While no answer arrives the usage API is asked as the desktop app asks it: every 5 minutes
// within 30 minutes of the last prompt, every 15 minutes after that. A failure waits 30 seconds,
// doubling up to 10 minutes.
const POLL_TICK_MS = 60_000
const POLL_RECENT_MS = 300_000
const POLL_QUIET_MS = 900_000
const RECENT_PROMPT_MS = 1_800_000
const MIN_RETRY_MS = 30_000
const MAX_RETRY_MS = 600_000

const usage = atom({ plugin: 'usage-band', key: 'usage' } as const, null)
const monthly = atom({ plugin: 'usage-band', key: 'monthly' } as const, null)
const isBusy = atom({ plugin: 'usage-band', key: 'isBusy' } as const, false)
const isBlinkOn = atom({ plugin: 'usage-band', key: 'isBlinkOn' } as const, true)
const effort = atom({ plugin: 'usage-band', key: 'effort' } as const, null)
const modelId = atom({ plugin: 'usage-band', key: 'modelId' } as const, null)
const cacheLeft = atom({ plugin: 'usage-band', key: 'cacheLeft' } as const, null)

const snapshot = (context: SessionContextUsage, rateLimits: SessionRateLimit[]): Snapshot => ({
  limits: rateLimits.map(({ kind, percentUsed }) => ({ kind, percentUsed })),
  tokens: context.tokens ?? 0,
  window: context.window,
  percent: context.percent ?? 0,
})

type Layout = 'left' | 'right' | 'below'

let lastFetchAt = 0
let lastPromptAt = 0
let retryAt = 0
let retryMs = MIN_RETRY_MS

// When the prompt cache is taken to lapse: a TTL after the last main-thread request; 0 once
// something forfeits it, null before the first turn.
let cacheUntil: number | null = null

async function refreshCache($: EngineInterface) {
  const now = await $.clock.now()
  const left = cacheUntil === null ? null : (cacheUntil - now) / 60_000

  await update($, cacheLeft, () => left)
}

async function touchCache($: EngineInterface) {
  cacheUntil = (await $.clock.now()) + CACHE_TTL_MS
  await refreshCache($)
}

async function forfeitCache($: EngineInterface) {
  cacheUntil = 0
  await refreshCache($)
}

// `limits` with the `kind` entry set to `percentUsed`; added when missing only if `add`.
const withLimit = (limits: Limit[], kind: string, percentUsed: number | undefined, add: boolean) =>
  percentUsed === undefined
    ? limits
    : limits.some(l => l.kind === kind)
      ? limits.map(l => (l.kind === kind ? { kind, percentUsed } : l))
      : add
        ? [...limits, { kind, percentUsed }]
        : limits

// Reads the usage API into the band: the weekly window over the answers' seven_day figure, and
// the monthly credits, which also stand for an enterprise plan's spend_limit figure.
async function refreshFromApi($: EngineInterface) {
  const now = await $.clock.now()
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
      retryAt = now + retryMs
      retryMs = Math.min(retryMs * 2, MAX_RETRY_MS)

      return
    }

    retryMs = MIN_RETRY_MS
    const { weekly, monthly: credits } = parseUsage(res.text)

    await update($, usage, snap =>
      snap
        ? {
            ...snap,
            limits: withLimit(withLimit(snap.limits, 'seven_day', weekly, true), 'spend_limit', credits, false),
          }
        : snap,
    )

    if (credits !== undefined) {
      await update($, monthly, () => credits)
      await $.store.set('monthly', credits)
    }
  } catch {
    retryAt = now + retryMs
    retryMs = Math.min(retryMs * 2, MAX_RETRY_MS)
  }
}

// Once a minute: ask the usage API when its interval has passed, the short one while an
// answer runs or after a recent prompt.
async function pollUsage($: EngineInterface) {
  const now = await $.clock.now()
  const isRecent = (await read($, isBusy)) || now - lastPromptAt < RECENT_PROMPT_MS
  const every = isRecent ? POLL_RECENT_MS : POLL_QUIET_MS

  if (now < retryAt || now - lastFetchAt < every) {
    return
  }

  await refreshFromApi($)
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

const BTW_MARK = '§btw§'

const EFFORT_LEVELS =['low', 'medium', 'high', 'xhigh', 'max']

// The level the last `/effort <level>` set, which the settings do not hold when it was for
// this session only; null until one was typed.
let typedEffort: string | null = null

// The model and the effort level in use: the effort is the last one typed, else the one saved
// in the settings. Both are kept as values so that a change redraws the band.
async function refreshEffort($: EngineInterface) {
  try {
    const settings = await $.settings.read()
    const model = await $.session.model()
    await update($, modelId, () => model)
    await update($, effort, () => typedEffort ?? effortLevel(settings, model))
  } catch {
    // No effort mark is better than a failed turn.
  }
}

// The band itself: usage, context, model, effort and the busy/idle dot, in one row, with the
// session's folder at the other end (below the prompt the band is at the right).
// What the band shows: the path, the cache minutes, and the short form (no Context/Cache labels).
type Look = { showPath: boolean; showCache: boolean; isShort: boolean }

async function drawBand($: EngineInterface, e: ResolveInput, layout: Layout, look: Look) {
  const { showPath, showCache, isShort } = look
  const snap = await read($, usage)
  const busy = await read($, isBusy)
  const blinkOn = await read($, isBlinkOn)
  const model = modelName((await read($, modelId)) ?? (await $.session.model()))
  const level = effortMark(await read($, effort))
  const cache = showCache ? cacheMark(await read($, cacheLeft), isShort) : null
  const monthlyPercent = await read($, monthly)
  const parts = usageParts(snap?.limits ?? [], monthlyPercent ?? undefined)
  const { Box, Text } = $.ui.resolve(e)

  const dotColor = busy ? RED : GREEN
  const dot = busy && !blinkOn ? ' ' : '⬤'

  // The folder the session runs in.
  const folder = showPath ? (
    <Text wrap="truncate-middle">
      <Text color="#4C9DA6" bold>
        ╰──{' '}
      </Text>
      <Text color="#4C9DA6">{await $.session.cwd()}</Text>
      <Text color="#4C9DA6" bold>
        {' '}──╮
      </Text>
    </Text>
  ) : null

  const band = (
    <Box flexDirection="row" flexShrink={0}>
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
        {contextText(snap?.tokens ?? 0, snap?.window ?? 0, snap?.percent ?? 0, isShort)}
        {' '}
      </Text>
      {cache ? <Text color={cache.color}>{cache.text} </Text> : null}
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

  if (!folder) {
    return (
      <Box flexDirection="row" justifyContent={layout === 'left' ? 'flex-start' : 'flex-end'} width="100%">
        {band}
      </Box>
    )
  }

  return (
    <Box flexDirection="row" justifyContent="space-between" width="100%">
      {layout === 'left' ? band : folder}
      <Text> </Text>
      {layout === 'left' ? folder : band}
    </Box>
  )
}

export const register: Register = (on, options) => {
  // Below the prompt unless the person chose left or right; the path shows unless turned off.
  const layout: Layout = options.position === 'right' ? 'right' : 'left'
  const isBelow = options.position !== 'left' && options.position !== 'right'
  const showPath = options.showPath !== false && options.showPath !== 'false'
  const notify = options.notify !== false && options.notify !== 'false'
  const look: Look = {
    showPath,
    showCache: options.showCache !== false && options.showCache !== 'false',
    isShort: options.form !== 'long',
  }

  let blink: Timer | undefined
  let poll: Timer | undefined

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

    void refreshFromApi($)
    void refreshEffort($)

    poll?.cancel()
    poll = $.clock.every(POLL_TICK_MS, () => {
      void pollUsage($)
      void refreshCache($)
    })

    return result
  })

  // An answer's own figures; the usage API is asked only while no answer arrives.
  on('session.measure', async ($, e, next) => {
    await update($, usage, () => snapshot(e.context, e.rateLimits))

    return next(e)
  })

  // A compaction shrinks the context at once; the next measure comes only after a turn.
  on('session.compact', async ($, e, next) => {
    const result = await next(e)
    const after = result.messages ? result.tokensAfter : undefined

    if (e.agentId === undefined && after !== undefined) {
      await update($, usage, snap =>
        snap && snap.window ? { ...snap, tokens: after, percent: (after / snap.window) * 100 } : snap,
      )
    }

    // The compacted conversation is a new prompt: the next request writes the cache anew.
    if (e.agentId === undefined && e.trigger !== 'precompute' && result.messages) {
      void forfeitCache($)
    }

    return result
  })

  on('prompt.submit', async ($, e, next) => {
    lastPromptAt = await $.clock.now()
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

  // `/model` shows the new model and the effort saved for it at once; another model can't use
  // the prompt cache.
  on('command.run', { command: 'model' }, async ($, e, next) => {
    const before = await $.session.model()
    const result = await next(e)

    typedEffort = null
    void refreshEffort($)

    if ((await $.session.model()) !== before) {
      void forfeitCache($)
    }

    return result
  })

  // A terminal key mapped to type BTW_MARK (VS Code: ctrl+; → sendSequence) replaces the
  // whole draft with "/btw ", the start of a side question.
  on('prompt.edit', async ($, e, next) => {
    const draft = e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end)

    if (draft.includes(BTW_MARK)) {
      return { text: '/btw ', cursor: 5 }
    }

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
      void touchCache($)
    }

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      stopBlink()
      await update($, isBusy, () => false)
      void touchCache($)
      if (notify) {
        void notifyIfAway($, ANSWER_COMPLETE)
      }
    }

    return next(e)
  })

  on('classic.PermissionRequest', async ($, e, next) => {
    if (notify && e.agent_id === undefined) {
      await notifyAsk($)
    }

    return next(e)
  })

  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    if (notify) {
      await notifyAsk($)
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || isBelow) {
      return next(e)
    }

    return drawBand($, e, layout, look)
  })

  // Below the prompt: the footer's right-hand mode labels, then the band.
  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    if (!isBelow) {
      return next(e)
    }

    const modes = await next(e)
    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="row" width="100%">
        {e.props.modes.length > 0 ? modes : null}
        {e.props.modes.length > 0 ? <Text> </Text> : null}
        {await drawBand($, e, 'below', look)}
        <Text> </Text>
      </Box>
    )
  })
}
