#!/usr/bin/env node
/**
 * Generates the DSH plugin-market index (format 1) for this bundle.
 *
 * An index is a single JSON document listing installable bundles. Host it
 * anywhere reachable over HTTPS, then add its URL as an index source in the
 * plugin market. Nothing is uploaded to DeepSeek.
 *
 * Usage:
 *   node market/build-index.mjs --repo https://github.com/<you>/dsh-screenshot
 *   node market/build-index.mjs --commit <sha> --timestamp <unix-seconds>
 *   node market/build-index.mjs --npm --registry https://registry.npmjs.org
 *
 * Git repositories need no commit/timestamp flags: they are read from
 * `git rev-parse HEAD` and the commit's authored date, and the repository URL
 * defaults to the `origin` remote.
 */
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..')

const PACKAGE_NAME = /^(?:@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/u
const SEMVER = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:\d*[a-zA-Z-][0-9a-zA-Z-]*|0|[1-9]\d*)(?:\.[0-9a-zA-Z-]*)*)?(?:\+[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*)?$/u
const COMMIT = /^[0-9a-f]{40}$/u
const MAX_INLINE_ICON_BYTES = 32 * 1024

function arg(name, fallback = undefined) {
  const hit = process.argv.find((value) => value === `--${name}` || value.startsWith(`--${name}=`))
  if (hit === undefined) return fallback
  if (hit.includes('=')) return hit.slice(hit.indexOf('=') + 1)
  const next = process.argv[process.argv.indexOf(hit) + 1]
  return next !== undefined && !next.startsWith('--') ? next : true
}

function git(...args) {
  return execFileSync('git', args, {
    cwd: ROOT,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim()
}

// A missing remote or a non-git checkout should read as one line of advice, not
// as a stack trace with git's own chatter in front of it.
process.on('uncaughtException', (error) => {
  console.error(`build-index: ${error && error.message ? error.message : String(error)}`)
  process.exit(1)
})

function canonicalRepo(url) {
  const parsed = new URL(url.replace(/^git\+/, '').replace(/\.git$/, ''))
  if (parsed.protocol !== 'https:') throw new Error(`repository URL must be https, got ${url}`)
  return `${parsed.origin}${parsed.pathname.replace(/\.git$/, '')}`
}

const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'))
if (!PACKAGE_NAME.test(pkg.name)) throw new Error(`package.json name is not a valid npm name: ${pkg.name}`)
if (!SEMVER.test(pkg.version)) throw new Error(`package.json version is not exact SemVer: ${pkg.version}`)

const iconBytes = readFileSync(join(ROOT, 'icon.svg'))
if (iconBytes.length > MAX_INLINE_ICON_BYTES) throw new Error('icon.svg exceeds 32 KiB once inlined')
const icon = `data:image/svg+xml;base64,${iconBytes.toString('base64')}`

const npmSource = arg('npm', false) === true
let source
if (npmSource) {
  const registry = arg('registry')
  source = { type: 'npm', ...(registry ? { registry: String(registry) } : {}) }
} else {
  let repo = arg('repo')
  if (repo === undefined) {
    try {
      repo = git('remote', 'get-url', 'origin')
    } catch {
      throw new Error('no --repo given and no git remote "origin"; pass --repo https://host/owner/repo')
    }
  }
  const url = canonicalRepo(String(repo))
  let commit = arg('commit')
  if (commit === undefined) {
    try {
      commit = git('rev-parse', 'HEAD')
    } catch {
      throw new Error('no --commit given and this directory is not a git checkout')
    }
  }
  commit = String(commit).toLowerCase()
  if (!COMMIT.test(commit)) throw new Error(`commit must be a lowercase 40-hex SHA, got ${commit}`)
  const path = arg('path')
  source = { type: 'git', url, commit, ...(path ? { path: String(path) } : {}) }
}

let timestamp = arg('timestamp')
if (timestamp !== undefined) {
  timestamp = Number(timestamp)
} else {
  try {
    timestamp = Number(git('log', '-1', '--format=%ct'))
  } catch {
    timestamp = Math.floor(Date.now() / 1000)
  }
}
if (!Number.isInteger(timestamp) || timestamp < 0 || timestamp >= 1e11) {
  throw new Error(`publishTimestamp must be integer Unix seconds, got ${String(timestamp)}`)
}

const staged = process.env.DSH_MARKET_STAGED === '1'
const index = {
  format: 1,
  title: { en: 'Local DSH plugins', zh: '本地 DSH 插件' },
  description: {
    en: 'Bundles published from this workspace. Add this index URL in the plugin market to list them.',
    zh: '从本工作区发布的组合包。在插件市场里添加本索引地址即可看到。',
  },
  metadata: {
    categories: { tools: { title: { en: 'Tools', zh: '工具' } } },
    labels: {
      windows: { title: { en: 'Windows only', zh: '仅 Windows' } },
      screenshot: { title: { en: 'Screenshot', zh: '截屏' } },
    },
    sortKeys: {},
  },
  plugins: [
    {
      name: pkg.name,
      title: { en: 'Screenshot to chat', zh: '对话截屏' },
      description: {
        en: 'Screenshot entry for the composer, in the tool row and the “+” menu (both switchable): drag a region (Doubao-style chrome), adjust it, and the PNG lands in the draft as an attachment. Windows only.',
        zh: '输入框截屏入口，工具栏按钮与「+」菜单两种位置可切换：拖出选区（豆包同款界面）、可微调，确认后 PNG 作为附件插入当前草稿。仅 Windows。',
      },
      icon,
      author: pkg.author,
      ...(arg('homepage') ? { homepage: String(arg('homepage')) } : {}),
      ...(source.type === 'git' ? { repository: { url: source.url } } : {}),
      metadata: {
        category: 'tools',
        keywords: pkg.keywords ?? [],
        labels: staged ? ['windows'] : ['windows', 'screenshot'],
        sortKeys: {},
      },
      versions: [
        {
          version: pkg.version,
          publishTimestamp: timestamp,
          source,
        },
      ],
    },
  ],
}

const out = resolve(ROOT, String(arg('out', 'market/index.json')))
mkdirSync(dirname(out), { recursive: true })
writeFileSync(out, `${JSON.stringify(index, null, 2)}\n`)
console.log(`wrote ${out}`)
console.log(`  plugin   ${pkg.name}@${pkg.version}`)
console.log(`  source   ${source.type === 'git' ? `${source.url}#${source.commit}` : `npm${source.registry ? ' @ ' + source.registry : ''}`}`)
console.log(`  icon     ${(icon.length / 1024).toFixed(1)} KiB inlined`)
