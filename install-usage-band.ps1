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
$appKey = 'HKCU:\Software\Classes\AppUserModelId\ClaudeCode.UsageBand'
$focusKey = 'HKCU:\Software\Classes\usageband-focus'
$utf8 = New-Object System.Text.UTF8Encoding $false

$files = @(
@{ Path = '.claude-plugin/plugin.json'; Newline = $false; Text = @'
{
  "name": "usage-band",
  "version": "0.5.2",
  "description": "Shows rate-limit usage, context fill, the current model and a busy/idle dot above the prompt",
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
      "default": "left"
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

// Terminals Claude Code runs in: while one of them is the foreground window, the person is
// taken to be watching and no notification is raised. VS Code is told apart by window: only
// a window whose title names the session's project folder counts as watching.
const TERMINALS = ['WindowsTerminal', 'powershell', 'pwsh', 'conhost', 'OpenConsole']

// The Windows app the toast is sent as: registered under the current user as "Claude Code Notification".
const APP_ID = 'ClaudeCode.UsageBand'

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
    const folder = (await $.session.cwd()).split(/[\\/]/).filter(Boolean).pop() ?? ''
    const logo = `${$.plugin.root}/claude.png`.replace(/'/g, "''")
    const focus = `${$.plugin.root}/focus.vbs`.replace(/'/g, "''")
    const body = `${message} (${folder})`
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/'/g, "''")
    const project = ((await $.session.root()).split(/[\\/]/).filter(Boolean).pop() ?? '').replace(
      /'/g,
      "''",
    )
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
      `if ($logo) { Set-ItemProperty -Path $key -Name IconUri -Value $logo }`,
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

  on('prompt.submit', async ($, e, next) => {
    void rememberWindow($)

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
'@ },
@{ Path = 'hooks/format.ts'; Newline = $true; Text = @'
import type { Limit } from '../types'

export const GREEN = 'green'
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
    'usage-band': { usage: Snapshot | null; monthly: number | null; isBusy: boolean; isBlinkOn: boolean }
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

    if (Test-Path $focusKey) {
        Remove-Item -Recurse -Force $focusKey
        Write-Host '알림 클릭 등록(usageband-focus)을 제거했습니다.'
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
