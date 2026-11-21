# usage-band 설치 스크립트
# Claude Code 입력창 주변에 Usage / Context / Model / 작업 상태를 표시하는 모드를 설치합니다.
#
#   설치: install-usage-band.cmd 더블클릭, 또는
#         powershell -NoProfile -ExecutionPolicy Bypass -File install-usage-band.ps1
#   제거: ... install-usage-band.ps1 -Uninstall

param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$modDir = Join-Path $claudeDir 'mods\usage-band'
$settingsPath = Join-Path $claudeDir 'settings.json'
$appKey = 'HKCU:\Software\Classes\AppUserModelId\ClaudeCode.Usage-Band'
$oldAppKey = 'HKCU:\Software\Classes\AppUserModelId\ClaudeCode.UsageBand'
$focusKey = 'HKCU:\Software\Classes\usageband-focus'
$utf8 = New-Object System.Text.UTF8Encoding $false

# VS Code 단축키: 터미널에서 ctrl+; 가 "§btw§"를 입력하면 모드가 입력창을 "/btw "로 바꿈
$vscodeKeys = Join-Path $env:APPDATA 'Code\User\keybindings.json'
$btwEntry = @'
    {
        "key": "ctrl+;",
        "command": "workbench.action.terminal.sendSequence",
        "args": { "text": "§btw§" },
        "when": "terminalFocus"
    }
'@ -replace "`r`n", "`n"

$files = @(
@{ Path = '.claude-plugin/plugin.json'; Newline = $false; Text = @'
{
  "name": "usage-band",
  "version": "0.5.25",
  "description": "Shows rate-limit usage, context fill, the current model and a busy/idle icon above the prompt",
  "types": "./types/index.d.ts",
  "author": {
    "name": "pouco"
  },
  "userConfig": {
    "position": {
      "type": "string",
      "title": "Band position",
      "description": "left / right: above the prompt on that side; below: under the prompt, at the right",
      "options": ["left", "right", "below"],
      "default": "below"
    },
    "showPath": {
      "type": "boolean",
      "title": "Show path",
      "description": "Show the session's folder path on the other side of the band",
      "default": true
    },
    "showCache": {
      "type": "boolean",
      "title": "Show cache",
      "description": "Show the minutes the prompt cache has left (estimated, 1 hour after the last request)",
      "default": true
    },
    "form": {
      "type": "string",
      "title": "Band form",
      "description": "short: numbers only; long: with the Context / Cache labels",
      "options": ["short", "long"],
      "default": "short"
    },
    "notify": {
      "type": "boolean",
      "title": "Notifications",
      "description": "Show a Windows notification when an answer finishes or Claude waits for you while another app is in front",
      "default": true
    },
    "guardPaths": {
      "type": "boolean",
      "title": "Guard outside paths",
      "description": "Ask before a tool touches files outside the project and the folders listed under Allowed External Directories in its CLAUDE.md",
      "default": false
    }
  }
}
'@ },
@{ Path = 'hooks/hooks.json'; Newline = $true; Text = @'
{ "modules": ["./register.tsx"] }
'@ },
@{ Path = 'hooks/register.tsx'; Newline = $true; Text = @'
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
  cacheMark,
  contextText,
  effortLevel,
  effortMark,
  modelName,
  parseUsage,
  usageColor,
  usageParts,
} from './format'
import {
  READ_TOOLS,
  callCandidates,
  classify,
  editedText,
  guardText,
  loadAllowedDirs,
  normPath,
  projectDataDir,
} from './guard'
import type { Scope } from './guard'

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
const spinFrame = atom({ plugin: 'usage-band', key: 'spinFrame' } as const, 0)

// Claude Code's own working spinner: the stars grow, then shrink back.
const SPIN = ['·', '✢', '*', '✶', '✻', '✽']
const SPIN_FRAMES = [...SPIN, ...SPIN.slice().reverse()]
const SPIN_MS = 250
const effort = atom({ plugin: 'usage-band', key: 'effort' } as const, null)
const modelId = atom({ plugin: 'usage-band', key: 'modelId' } as const, null)
const cacheLeft = atom({ plugin: 'usage-band', key: 'cacheLeft' } as const, null)

// The guard's words as of its last check, so its error handler speaks the same language.
let text = guardText(undefined)

// The project's folder, the folders its CLAUDE.md allows, and the ones allowed this session.
async function guardScope($: EngineInterface, session: string[]) {
  text = guardText((await $.settings.read()).language)
  const home = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? ''
  const rootDir = await $.session.root()
  const cwd = await $.session.cwd()
  const claudeMd = await $.fs.read(`${rootDir}/CLAUDE.md`).catch(() => '')
  const listed = loadAllowedDirs(claudeMd)
  const configDir = (await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${home}/.claude`
  const scope: Scope = {
    root: normPath(rootDir, rootDir, home),
    // Claude Code's own folder for this project (memory, transcripts) counts as allowed.
    allowed: [...listed, projectDataDir(configDir, rootDir)].map(dir => normPath(dir, rootDir, home)),
    session,
    home,
  }

  return { scope, cwd, claudeMd, listed, claudeMdPath: normPath(`${rootDir}/CLAUDE.md`, rootDir, home) }
}

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
// The session `cacheUntil` belongs to; another id (a resume) reads its own from the store.
let cacheSession: string | null = null

// The store keeps each session's `cacheUntil`, so a resumed session shows its cache at once.
const CACHE_KEY = 'cacheUntil'
const CACHE_SESSIONS = 20

const savedCaches = async ($: EngineInterface) => {
  const saved = await $.store.get(CACHE_KEY)
  return (saved !== null && typeof saved === 'object' ? saved : {}) as Record<string, number>
}

async function refreshCache($: EngineInterface) {
  const id = await $.session.id()

  if (id !== cacheSession) {
    const until = (await savedCaches($))[id]
    cacheUntil = typeof until === 'number' ? until : null
    cacheSession = id
  }

  const now = await $.clock.now()
  const left = cacheUntil === null ? null : (cacheUntil - now) / 60_000

  await update($, cacheLeft, () => left)
}

async function setCache($: EngineInterface, until: number) {
  const id = await $.session.id()
  cacheUntil = until
  cacheSession = id

  const kept = Object.entries({ ...(await savedCaches($)), [id]: until })
    .sort(([, a], [, b]) => b - a)
    .slice(0, CACHE_SESSIONS)
  await $.store.set(CACHE_KEY, Object.fromEntries(kept))
  await refreshCache($)
}

async function touchCache($: EngineInterface) {
  await setCache($, (await $.clock.now()) + CACHE_TTL_MS)
}

async function forfeitCache($: EngineInterface) {
  await setCache($, 0)
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

// The band itself: usage, context, model, effort and the busy/idle icon, in one row, with the
// session's folder at the other end (below the prompt the band is at the right).
// What the band shows: the path, the cache minutes, and the short form (no Context/Cache labels).
type Look = { showPath: boolean; showCache: boolean; isShort: boolean }

async function drawBand($: EngineInterface, e: ResolveInput, layout: Layout, look: Look) {
  const { showPath, showCache, isShort } = look
  const snap = await read($, usage)
  const busy = await read($, isBusy)
  const frame = await read($, spinFrame)
  const model = modelName((await read($, modelId)) ?? (await $.session.model()))
  const level = effortMark(await read($, effort))
  const cache = showCache ? cacheMark(await read($, cacheLeft), isShort) : null
  const monthlyPercent = await read($, monthly)
  const parts = usageParts(snap?.limits ?? [], monthlyPercent ?? undefined)
  const { Box, Text } = $.ui.resolve(e)

  const iconColor = busy ? 'claude' : GREEN
  const icon = busy ? SPIN_FRAMES[frame % SPIN_FRAMES.length] : SPIN[SPIN.length - 1]

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
      <Text color={iconColor}>{icon}</Text>
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
  const guard = options.guardPaths === true || options.guardPaths === 'true'
  // Folders the person allowed for this session, and the calls they allowed one by one.
  const sessionDirs: string[] = []
  const allowedCalls = new Set<string>()

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
    void refreshCache($)

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
      await update($, spinFrame, () => 0)
      blink = $.clock.every(SPIN_MS, () => {
        void update($, spinFrame, i => (i + 1) % SPIN_FRAMES.length)
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

  // Path guard: a tool reaching beyond the project and the CLAUDE.md list waits for the person.
  // It only asks or refuses; whatever they allow still goes through the normal permission check.
  on('tool.call', async ($, e, next) => {
    if (!guard) {
      return next(e)
    }

    const input = e as unknown as Record<string, unknown>
    const { scope, cwd, claudeMd, listed, claudeMdPath } = await guardScope($, sessionDirs)
    const candidates = callCandidates(e.tool, input, cwd, scope.home)

    if (candidates === null) {
      return next(e)
    }

    // A change to CLAUDE.md's allowed list is asked, so the list can't be widened silently.
    const filePath = input.file_path
    if (typeof filePath === 'string' && normPath(filePath, cwd, scope.home) === claudeMdPath) {
      const after = editedText(e.tool, input, claudeMd)

      if (after !== null && JSON.stringify(loadAllowedDirs(after)) !== JSON.stringify(listed)) {
        const answer = await $.ui.ask(
          text.listAsk(JSON.stringify(listed), JSON.stringify(loadAllowedDirs(after))),
          [text.allowOnce, text.refuse],
        )

        return answer === text.allowOnce ? next(e) : { deny: text.listRefused }
      }
    }

    const { outside } = classify(candidates, scope)

    if (outside.length === 0) {
      return next(e)
    }

    const paths = outside.map(o => o.path).join(', ')
    const answer = await $.ui.ask(text.ask(paths, scope.root), {
      header: text.header,
      options: [text.allowOnce, text.allowSession, text.refuse],
    })

    if (answer !== text.allowOnce && answer !== text.allowSession) {
      return { deny: text.refused(paths) }
    }
    if (answer === text.allowSession) {
      sessionDirs.push(...outside.map(o => o.dir))
    }
    if (e.tool_use_id !== undefined && READ_TOOLS.includes(e.tool)) {
      allowedCalls.add(e.tool_use_id)
    }

    return next(e)
  }).catch(($, e, next) => (next.called ? next(e) : { deny: text.failed }))

  // Reads the person has already allowed (CLAUDE.md's list, this session, or this call) skip Claude
  // Code's own prompt for reading outside the project. Only an ask with no settings rule behind it
  // is lifted; writes and shell commands keep the normal check.
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)

    if (!guard || !READ_TOOLS.includes(e.tool) || verdict.decision !== 'ask' || verdict.rule !== undefined) {
      return verdict
    }
    if (e.tool_use_id !== undefined && allowedCalls.delete(e.tool_use_id)) {
      return { ...verdict, decision: 'allow', reason: text.allowedCall }
    }

    const { scope, cwd } = await guardScope($, sessionDirs)
    const candidates = callCandidates(e.tool, (e.input ?? {}) as Record<string, unknown>, cwd, scope.home)

    const verdictOf = candidates === null ? null : classify(candidates, scope)

    if (verdictOf === null || verdictOf.outside.length > 0 || verdictOf.external.length === 0) {
      return verdict
    }

    return { ...verdict, decision: 'allow', reason: text.allowedDir }
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
'@ },
@{ Path = 'hooks/format.ts'; Newline = $true; Text = @'
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
'@ },
@{ Path = 'hooks/guard.ts'; Newline = $true; Text = @'
// Path guard: which paths a tool call touches, and whether each lies inside the project, a
// folder the project's CLAUDE.md allows, or a folder allowed for this session.
// Ported from the settings hook confirm_outside_dir.py, so both read the same CLAUDE.md list.

export const FILE_TOOLS = ['Read', 'Edit', 'Write', 'Glob', 'Grep', 'NotebookEdit']
export const SHELL_TOOLS = ['Bash', 'PowerShell']
export const READ_TOOLS = ['Read', 'Glob', 'Grep']

const PATH_KEYS = ['file_path', 'path', 'notebook_path']
const IGNORED_PATHS = new Set(['/dev/null', 'nul', '$null'])
const CD_COMMANDS = new Set(['cd', 'chdir', 'pushd', 'set-location', 'sl'])

// Bare tokens may contain backslash-escaped spaces (`Claude\ Project`).
const TOKEN_PATTERN = /"([^"]*)"|'([^']*)'|((?:\\ |\S)+)/g
const SPLIT_PATTERN = /[=<>|;&()]/
const DRIVE_PATTERN = /^[A-Za-z]:[\\/]/
const HOME_PATTERN = /^(~|\$HOME|%USERPROFILE%|\$env:USERPROFILE)(?=[\\/]|$)/i
const GIT_BASH_DRIVE_PATTERN = /^\/([A-Za-z])(\/|$)/

const ALLOWED_SECTION_PATTERN = /^#+\s*(Allowed External Directories|외부 허용 디렉토리)\s*$/i
const HEADING_PATTERN = /^#+\s/
const ALLOWED_ITEM_PATTERN = /^\s*-\s+`([^`]+)`/

/** The guard's words, in Korean when the settings' `language` is Korean, otherwise English. */
const GUARD_TEXT = {
  en: {
    allowOnce: 'Allow once',
    allowSession: 'Allow for this session',
    refuse: 'Refuse',
    header: 'Path check',
    ask: (paths: string, root: string) => `[Outside the project] ${paths} is outside the project folder (${root}). Allow access?`,
    refused: (paths: string) => `The user refused access outside the project (${paths}).`,
    listAsk: (before: string, after: string) =>
      `[Allowed list change] CLAUDE.md's Allowed External Directories would change from ${before} to ${after}. Go ahead?`,
    listRefused: "The user refused the change to CLAUDE.md's Allowed External Directories.",
    failed: "The path check failed (or the question was closed), so the call didn't run.",
    allowedCall: 'Read allowed at the path check',
    allowedDir: 'Read in an allowed external folder',
  },
  ko: {
    allowOnce: '이번만 허용',
    allowSession: '이번 세션 동안 허용',
    refuse: '거부',
    header: '경로 확인',
    ask: (paths: string, root: string) => `[프로젝트 외부 접근] ${paths} 은(는) 프로젝트 디렉토리(${root}) 밖입니다. 접근해도 될까요?`,
    refused: (paths: string) => `사용자가 프로젝트 밖 경로 접근(${paths})을 거부했습니다.`,
    listAsk: (before: string, after: string) =>
      `[예외 디렉토리 변경] CLAUDE.md 의 Allowed External Directories 목록이 ${before} → ${after} 로 바뀝니다. 진행할까요?`,
    listRefused: '사용자가 CLAUDE.md 의 Allowed External Directories 변경을 거부했습니다.',
    failed: '경로 확인 중 오류가 나서(또는 질문이 닫혀서) 실행하지 않았습니다.',
    allowedCall: '경로 확인에서 허용한 읽기',
    allowedDir: '허용된 외부 디렉토리 읽기',
  },
}

export type GuardText = (typeof GUARD_TEXT)['en']

export function guardText(language: unknown): GuardText {
  return typeof language === 'string' && /korean|한국어|한국말|한글/i.test(language) ? GUARD_TEXT.ko : GUARD_TEXT.en
}

/** A path touched by a call; `isDir` when the tool names a folder rather than a file. */
export type Candidate = { path: string; base: string; isDir: boolean }

/**
 * An absolute, `/`-separated path with `.` and `..` folded: `~` and the home variables expand,
 * Git Bash's `/d/x` reads as `d:/x`, and Windows paths are lower-cased (their case doesn't matter).
 */
export function normPath(path: string, base: string, home: string): string {
  let s = path.replace(HOME_PATTERN, home).replace(/\\/g, '/')
  s = s.replace(GIT_BASH_DRIVE_PATTERN, (_, drive: string) => `${drive}:/`)

  if (!/^[A-Za-z]:\//.test(s) && !s.startsWith('/')) {
    s = `${base.replace(/\\/g, '/')}/${s}`
  }

  const prefix = /^[A-Za-z]:\//.test(s) ? s.slice(0, 3) : s.startsWith('//') ? '//' : '/'
  const parts: string[] = []

  for (const part of s.slice(prefix.length).split('/')) {
    if (part === '..') {
      parts.pop()
    } else if (part !== '' && part !== '.') {
      parts.push(part)
    }
  }

  const joined = prefix + parts.join('/')
  return prefix === '/' ? joined : joined.toLowerCase()
}

export function isInside(path: string, dir: string): boolean {
  return path === dir || path.startsWith(dir.endsWith('/') ? dir : `${dir}/`)
}

export function parentDir(path: string): string {
  const cut = path.lastIndexOf('/')
  return cut <= 0 || path.slice(0, cut).endsWith(':') ? path.slice(0, cut + 1) : path.slice(0, cut)
}

function looksLikePath(token: string): boolean {
  return (
    DRIVE_PATTERN.test(token) ||
    /^(\/|\\\\|~|\$HOME|%USERPROFILE%|\$env:USERPROFILE)/i.test(token) ||
    token.replace(/\\/g, '/').split('/').includes('..')
  )
}

/**
 * The folder Claude Code keeps this project's own data in (memory, transcripts, tool results):
 * `<config>/projects/<the project path with every character but letters and digits as '-'>`.
 */
export function projectDataDir(configDir: string, root: string): string {
  return `${configDir}/projects/${root.replace(/[^A-Za-z0-9]/g, '-')}`
}

/** Paths listed as "- `<path>`" under the Allowed External Directories heading. */
export function loadAllowedDirs(text: string): string[] {
  const dirs: string[] = []
  let inSection = false

  for (const line of text.split(/\r?\n/)) {
    if (ALLOWED_SECTION_PATTERN.test(line)) {
      inSection = true
    } else if (HEADING_PATTERN.test(line)) {
      inSection = false
    } else if (inSection) {
      const item = ALLOWED_ITEM_PATTERN.exec(line)?.[1]
      if (item !== undefined) {
        dirs.push(item.trim())
      }
    }
  }

  return dirs
}

/** The file's content after this Edit or Write, or null for other tools. */
export function editedText(tool: string, input: Record<string, unknown>, current: string): string | null {
  const str = (key: string) => (typeof input[key] === 'string' ? (input[key] as string) : '')

  if (tool === 'Write') {
    return str('content')
  }
  if (tool === 'Edit') {
    const [old, replacement] = [str('old_string'), str('new_string')]
    if (!old) {
      return current
    }
    return input.replace_all === true ? current.split(old).join(replacement) : current.replace(old, () => replacement)
  }
  return null
}

/**
 * Path-like tokens of a shell command, each with the folder it is relative to: a `cd <dir>`
 * moves that folder for the tokens after it, until a `)` leaves the subshell.
 */
export function shellCandidates(command: string, cwd: string, home: string): Candidate[] {
  const found: Candidate[] = []
  let base = cwd
  let expectCdTarget = false

  for (const [, dq, sq, bare] of command.matchAll(TOKEN_PATTERN)) {
    const parts = bare ? bare.replace(/\\ /g, ' ').split(SPLIT_PATTERN) : [dq ?? sq ?? '']

    parts.forEach((raw, i) => {
      if (i > 0) {
        expectCdTarget = false // a separator (; & | ...) ended the cd command
      }
      const part = raw.trim()
      if (!part) {
        return
      }
      if (expectCdTarget) {
        if (part.startsWith('-')) {
          return // cd option such as -L or PowerShell -Path
        }
        expectCdTarget = false
        if (!IGNORED_PATHS.has(part.toLowerCase()) && looksLikePath(part)) {
          found.push({ path: part, base, isDir: true })
        }
        base = normPath(part, base, home)
        return
      }
      if (bare && CD_COMMANDS.has(part.toLowerCase())) {
        expectCdTarget = true
        return
      }
      if (!IGNORED_PATHS.has(part.toLowerCase()) && looksLikePath(part)) {
        found.push({ path: part, base, isDir: false })
      }
    })

    if (bare && bare.includes(')')) {
      base = cwd // leaving a subshell: its cd no longer applies
    }
  }

  return found
}

/** The paths a call touches, or null for a tool the guard doesn't check. */
export function callCandidates(
  tool: string,
  input: Record<string, unknown>,
  cwd: string,
  home: string,
): Candidate[] | null {
  if (SHELL_TOOLS.includes(tool)) {
    return shellCandidates(typeof input.command === 'string' ? input.command : '', cwd, home)
  }
  if (!FILE_TOOLS.includes(tool)) {
    return null
  }

  const named = PATH_KEYS.filter(key => typeof input[key] === 'string' && input[key] !== '').map(key => ({
    path: input[key] as string,
    base: cwd,
    isDir: key === 'path',
  }))

  // Glob and Grep without a path search the working directory.
  return named.length > 0 ? named : [{ path: cwd, base: cwd, isDir: true }]
}

/** Where the guard lets a call go. All paths are normPath'd. */
export type Scope = { root: string; allowed: string[]; session: string[]; home: string }

/**
 * `outside`: the paths beyond the project and every allowed folder, as the call wrote them, with
 * the folder each would be allowed under; `external`: the allowed ones beyond the project.
 */
export function classify(candidates: Candidate[], scope: Scope) {
  const outside: { path: string; dir: string }[] = []
  const external: string[] = []

  for (const { path, base, isDir } of candidates) {
    const full = normPath(path, base, scope.home)

    if (isInside(full, scope.root)) {
      continue
    }
    if ([...scope.allowed, ...scope.session].some(dir => isInside(full, dir))) {
      external.push(path)
    } else {
      outside.push({ path, dir: isDir ? full : parentDir(full) })
    }
  }

  return { outside, external }
}
'@ },
@{ Path = 'types/index.d.ts'; Newline = $true; Text = @'
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
      spinFrame: number
      effort: string | null
      modelId: string | null
      cacheLeft: number | null
    }
  }
}
'@ },
@{ Path = 'focus.ps1'; Newline = $true; Text = @'
# Brings a window to the front: opened by a click on a usage-band notification as
#   usageband-focus:<window handle>
param([string]$Uri)

$handle = 0L

if (-not [Int64]::TryParse(($Uri -replace '^usageband-focus:/*', '').TrimEnd('/'), [ref]$handle)) {
    exit
}

Add-Type -Namespace W -Name F -MemberDefinition (@(
    '[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr h);'
    '[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);'
    '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);'
    '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);'
    '[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);'
    '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();'
    '[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, System.IntPtr p);'
    '[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();'
    '[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);'
    '[DllImport("user32.dll")] public static extern void SwitchToThisWindow(System.IntPtr h, bool altTab);'
    '[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);'
) -join "`n")

$window = [System.IntPtr]$handle

if (-not [W.F]::IsWindow($window)) {
    exit
}

if ([W.F]::IsIconic($window)) {
    [void][W.F]::ShowWindow($window, 9) # SW_RESTORE
}

# Windows lets a process take the foreground only under conditions: a released Alt key
# counts as input, and joining the current foreground window's input thread lifts the lock.
[W.F]::keybd_event(0x12, 0, 0, [System.UIntPtr]::Zero)
[W.F]::keybd_event(0x12, 0, 2, [System.UIntPtr]::Zero)

$front = [W.F]::GetWindowThreadProcessId([W.F]::GetForegroundWindow(), [System.IntPtr]::Zero)
$self = [W.F]::GetCurrentThreadId()
$attached = [W.F]::AttachThreadInput($self, $front, $true)
[void][W.F]::BringWindowToTop($window)
$ok = [W.F]::SetForegroundWindow($window)

if ($attached) {
    [void][W.F]::AttachThreadInput($self, $front, $false)
}

if (-not $ok) {
    [W.F]::SwitchToThisWindow($window, $true)
}
'@ },
@{ Path = 'focus.vbs'; Newline = $true; Text = @'
' Opened by a click on a usage-band notification (usageband-focus:<window handle>).
' Runs focus.ps1 with no window, so no console flashes on screen.
Dim folder
folder = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & folder & "\focus.ps1"" """ & WScript.Arguments(0) & """", 0, False
'@ }
)

# settings.json 읽기: 없으면 빈 설정, 형식이 깨졌으면 아무것도 바꾸지 않고 종료.
function Read-Settings {
    if (-not (Test-Path $settingsPath)) {
        return New-Object PSObject
    }

    $raw = [System.IO.File]::ReadAllText($settingsPath, $utf8)

    if ($raw.Trim() -eq '') {
        return New-Object PSObject
    }

    try {
        return $raw | ConvertFrom-Json
    } catch {
        Write-Host "settings.json 형식이 올바르지 않아 중단합니다: $settingsPath" -ForegroundColor Red
        Write-Host '(예: 마지막 항목 뒤 쉼표) 파일을 고친 뒤 다시 실행해 주세요.' -ForegroundColor Red
        exit 1
    }
}

function Write-Settings($settings) {
    if (Test-Path $settingsPath) {
        $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $settingsPath $backup
        Write-Host "기존 settings.json 백업: $backup"
    }

    New-Item -ItemType Directory -Force $claudeDir | Out-Null
    [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 50), $utf8)
}

function Get-PluginDirs($settings) {
    if ($settings.env -and $settings.env.CLAUDE_CODE_PLUGIN_DIRS) {
        return @($settings.env.CLAUDE_CODE_PLUGIN_DIRS -split ';' | Where-Object { $_.Trim() -ne '' })
    }

    return @()
}

function Set-PluginDirs($settings, $dirs) {
    if (-not $settings.env) {
        $settings | Add-Member -NotePropertyName env -NotePropertyValue (New-Object PSObject) -Force
    }

    if ($dirs.Count -gt 0) {
        $settings.env | Add-Member -NotePropertyName CLAUDE_CODE_PLUGIN_DIRS -NotePropertyValue ($dirs -join ';') -Force
    } else {
        $settings.env.PSObject.Properties.Remove('CLAUDE_CODE_PLUGIN_DIRS')
    }
}

# keybindings.json 목록 읽기: 줄 전체가 // 주석인 줄과 /* */ 주석은 빼고 읽음. 읽을 수 없으면 $null.
function Read-Keybindings($raw) {
    $plain = (($raw -split "`n") | ForEach-Object { $_ -replace '^\s*//.*$', '' }) -join "`n"
    $plain = $plain -replace '(?s)/\*.*?\*/', ''

    if ($plain.Trim() -eq '') {
        return @{ List = @() }
    }

    try {
        return @{ List = @(($plain | ConvertFrom-Json) | ForEach-Object { $_ }) }
    } catch {
        return $null
    }
}

$settings = Read-Settings
$dirs = Get-PluginDirs $settings
$isListed = @($dirs | Where-Object { $_.TrimEnd('\') -ieq $modDir }).Count -gt 0

if ($Uninstall) {
    if (Test-Path $modDir) {
        Remove-Item -Recurse -Force $modDir
        Write-Host "삭제: $modDir"
    }

    if (Test-Path $appKey) {
        Remove-Item -Recurse -Force $appKey
        Write-Host '알림 앱 등록(Claude Code)을 제거했습니다.'
    }

    if (Test-Path $oldAppKey) {
        Remove-Item -Recurse -Force $oldAppKey
    }

    if (Test-Path $focusKey) {
        Remove-Item -Recurse -Force $focusKey
        Write-Host '알림 클릭 등록(usageband-focus)을 제거했습니다.'
    }

    if (Test-Path $vscodeKeys) {
        $raw = [System.IO.File]::ReadAllText($vscodeKeys, $utf8)
        $left = $raw.Replace(",`n$btwEntry", '').Replace("`n$btwEntry", '')

        if ($left -ne $raw) {
            Copy-Item $vscodeKeys "$vscodeKeys.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            [System.IO.File]::WriteAllText($vscodeKeys, $left, $utf8)
            Write-Host 'VS Code 단축키(ctrl+; → /btw)를 제거했습니다.'
        }
    }

    if ($isListed) {
        Set-PluginDirs $settings @($dirs | Where-Object { $_.TrimEnd('\') -ine $modDir })
        Write-Settings $settings
        Write-Host 'settings.json에서 usage-band 경로를 제거했습니다.'
    }

    Write-Host 'usage-band 제거 완료. Claude Code를 새로 시작하면 적용됩니다.' -ForegroundColor Green
    exit 0
}

foreach ($file in $files) {
    $path = Join-Path $modDir $file.Path
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    $text = $file.Text -replace "`r`n", "`n"

    if ($file.Newline) {
        $text += "`n"
    }

    [System.IO.File]::WriteAllText($path, $text, $utf8)
}

Write-Host "설치: $modDir"

# 알림 로고: 스크립트 옆의 claude.ico를 PNG로 바꿔 모드 폴더에 둠 (없으면 로고 없이 알림)
$ico = Join-Path $PSScriptRoot 'claude.ico'

if (Test-Path $ico) {
    Add-Type -AssemblyName System.Drawing
    $icon = New-Object System.Drawing.Icon($ico, 256, 256)
    $bitmap = $icon.ToBitmap()
    $bitmap.Save((Join-Path $modDir 'claude.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $icon.Dispose()
    Write-Host '알림 로고(claude.png)를 설치했습니다.'
} else {
    Write-Host 'claude.ico가 스크립트 옆에 없어 알림 로고 없이 설치합니다.' -ForegroundColor Yellow
}

# 알림 앱 등록(이름, 머리글 아이콘): 첫 알림 전에 Windows가 아이콘을 읽도록 미리 기록
$logo = Join-Path $modDir 'claude.png'

if (Test-Path $oldAppKey) {
    Remove-Item -Recurse -Force $oldAppKey
}

if (-not (Test-Path $appKey)) {
    New-Item -Path $appKey -Force | Out-Null
}

Set-ItemProperty -Path $appKey -Name DisplayName -Value 'Claude Code Notification'

if (Test-Path $logo) {
    Set-ItemProperty -Path $appKey -Name IconUri -Value $logo
}

Write-Host '알림 앱(Claude Code Notification)을 등록했습니다.'

# VS Code 단축키 추가: VS Code가 없거나, ctrl+; 가 이미 있거나, 파일을 읽을 수 없으면 건드리지 않음
if (Test-Path (Split-Path $vscodeKeys)) {
    if (-not (Test-Path $vscodeKeys)) {
        [System.IO.File]::WriteAllText($vscodeKeys, "[`n$btwEntry`n]`n", $utf8)
        Write-Host 'VS Code 단축키(ctrl+; → /btw)를 추가했습니다.'
    } else {
        $raw = [System.IO.File]::ReadAllText($vscodeKeys, $utf8)
        $parsed = Read-Keybindings $raw
        $end = $raw.LastIndexOf(']')

        if ($null -eq $parsed -or $end -lt 0) {
            Write-Host "VS Code keybindings.json을 읽을 수 없어 ctrl+; 단축키는 추가하지 않았습니다. 직접 넣어 주세요:" -ForegroundColor Yellow
            Write-Host $btwEntry
        } elseif (@($parsed.List | Where-Object { $_.key -eq 'ctrl+;' }).Count -gt 0) {
            Write-Host 'VS Code에 ctrl+; 단축키가 이미 있어 그대로 둡니다.'
        } else {
            $sep = if ($parsed.List.Count -gt 0) { ',' } else { '' }
            $backup = "$vscodeKeys.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $vscodeKeys $backup
            [System.IO.File]::WriteAllText($vscodeKeys, $raw.Substring(0, $end).TrimEnd() + "$sep`n$btwEntry`n" + $raw.Substring($end), $utf8)
            Write-Host "VS Code 단축키(ctrl+; → /btw)를 추가했습니다. 백업: $backup"
        }
    }
}

if ($isListed) {
    Write-Host 'settings.json에 이미 등록되어 있습니다.'
} else {
    Set-PluginDirs $settings (@($dirs) + $modDir)
    Write-Settings $settings
    Write-Host 'settings.json에 usage-band 경로를 등록했습니다.'
}

Write-Host ''
Write-Host 'usage-band 설치 완료. Claude Code를 새로 시작하면 표시됩니다.' -ForegroundColor Green
Write-Host '표시 위치는 /config 의 Band position (left / right / below) 에서 바꿀 수 있습니다.'
