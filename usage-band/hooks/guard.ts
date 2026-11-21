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
