import os, sys

src, out = sys.argv[1], sys.argv[2]
files = [
    '.claude-plugin/plugin.json',
    'hooks/hooks.json',
    'hooks/register.tsx',
    'hooks/format.ts',
    'types/index.d.ts',
]

embedded = []
for rel in files:
    text = open(os.path.join(src, rel), encoding='utf-8').read().replace('\r\n', '\n')
    assert not any(line.startswith("'@") for line in text.split('\n')), rel
    body = text[:-1] if text.endswith('\n') else text
    trailing = '$true' if text.endswith('\n') else '$false'
    embedded.append(f"@{{ Path = '{rel}'; Newline = {trailing}; Text = @'\n{body}\n'@ }}")

script = r'''# usage-band 설치 스크립트
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
$utf8 = New-Object System.Text.UTF8Encoding $false

$files = @(
__FILES__
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
'''.replace('__FILES__', ',\n'.join(embedded))

with open(out, 'w', encoding='utf-8-sig', newline='\r\n') as f:
    f.write(script)
