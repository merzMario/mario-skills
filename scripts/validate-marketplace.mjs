#!/usr/bin/env node
// Validates .claude-plugin/marketplace.json against the skills/ tree.
//
// The marketplace manifest is the single source of truth for what ships.
// Claude Code installs exactly what is listed there — a skill sitting in
// skills/ but missing from the manifest is silently invisible to users.
// This script fails loudly on that drift, plus on malformed skill frontmatter.
//
// Usage: node scripts/validate-marketplace.mjs [--repo-root <path>]

import { readdir, readFile, stat } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { join, resolve, basename } from 'node:path'

const SEMVER = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/
const SKILL_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

const errors = []
const warnings = []

const fail = (msg) => errors.push(msg)
const warn = (msg) => warnings.push(msg)

function parseArgs(argv) {
  const root = { repoRoot: process.cwd() }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--repo-root' && argv[i + 1]) {
      root.repoRoot = argv[i + 1]
      i++
    } else if (argv[i].startsWith('--repo-root=')) {
      root.repoRoot = argv[i].slice('--repo-root='.length)
    }
  }
  return root
}

/** Minimal YAML frontmatter reader: top-level `key: value` pairs only. */
function parseFrontmatter(text) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text)
  if (!match) return null
  const fields = {}
  for (const line of match[1].split(/\r?\n/)) {
    const kv = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line)
    if (kv) fields[kv[1]] = kv[2].trim().replace(/^["']|["']$/g, '')
  }
  return fields
}

async function listSkillDirs(skillsRoot) {
  if (!existsSync(skillsRoot)) return []
  const entries = await readdir(skillsRoot, { withFileTypes: true })
  const dirs = []
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.') || entry.name === 'node_modules') continue
    dirs.push(entry.name)
  }
  return dirs.sort()
}

async function main() {
  const { repoRoot } = parseArgs(process.argv.slice(2))
  const manifestPath = resolve(repoRoot, '.claude-plugin/marketplace.json')

  if (!existsSync(manifestPath)) {
    fail(`missing marketplace manifest: ${manifestPath}`)
    return report()
  }

  let manifest
  try {
    manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
  } catch (err) {
    fail(`marketplace.json is not valid JSON: ${err.message}`)
    return report()
  }

  // --- marketplace-level fields ---
  if (!manifest.name) fail('marketplace.json: missing "name"')
  if (!manifest.owner?.name) fail('marketplace.json: missing "owner.name"')
  if (!Array.isArray(manifest.plugins) || manifest.plugins.length === 0) {
    fail('marketplace.json: "plugins" must be a non-empty array')
    return report()
  }

  const version = manifest.metadata?.version
  if (!version) {
    fail('marketplace.json: missing "metadata.version"')
  } else if (!SEMVER.test(version)) {
    fail(`marketplace.json: metadata.version "${version}" is not valid semver (x.y.z)`)
  }
  if (!manifest.metadata?.description) {
    warn('marketplace.json: missing "metadata.description" (shown in the marketplace listing)')
  }

  // --- plugin + skill entries ---
  const registered = new Set()
  const seenPluginNames = new Set()
  const skillsRoot = resolve(repoRoot, 'skills')

  for (const [index, plugin] of manifest.plugins.entries()) {
    const at = `plugins[${index}]`

    if (!plugin.name) fail(`${at}: missing "name"`)
    if (seenPluginNames.has(plugin.name)) {
      fail(`${at}: duplicate plugin name "${plugin.name}"`)
    }
    seenPluginNames.add(plugin.name)
    if (!plugin.description) fail(`${at} (${plugin.name}): missing "description"`)

    if (!plugin.source) {
      fail(`${at} (${plugin.name}): missing "source" (use "./" for a repo-root plugin)`)
    } else if (!existsSync(resolve(repoRoot, plugin.source))) {
      fail(`${at} (${plugin.name}): source "${plugin.source}" does not exist`)
    }

    if (!Array.isArray(plugin.skills) || plugin.skills.length === 0) {
      fail(`${at} (${plugin.name}): "skills" must be a non-empty array of relative paths`)
      continue
    }

    for (const skillPath of plugin.skills) {
      const dirName = basename(skillPath.replace(/\/+$/, ''))
      registered.add(dirName)

      const absDir = resolve(repoRoot, skillPath)
      const info = await stat(absDir).catch(() => null)
      if (!info?.isDirectory()) {
        fail(`${at} (${plugin.name}): skill path "${skillPath}" is not a directory on disk`)
        continue
      }

      const skillMd = join(absDir, 'SKILL.md')
      if (!existsSync(skillMd)) {
        fail(`skills/${dirName}: missing SKILL.md`)
        continue
      }

      const fields = parseFrontmatter(await readFile(skillMd, 'utf8'))
      if (!fields) {
        fail(`skills/${dirName}: SKILL.md has no YAML frontmatter (--- ... ---)`)
        continue
      }
      if (!fields.name) {
        fail(`skills/${dirName}: SKILL.md frontmatter missing "name"`)
      } else if (fields.name !== dirName) {
        fail(`skills/${dirName}: frontmatter name "${fields.name}" must match the directory name`)
      } else if (!SKILL_NAME.test(fields.name)) {
        fail(`skills/${dirName}: name must be lowercase letters/digits/hyphens only`)
      }

      if (!fields.description) {
        fail(`skills/${dirName}: SKILL.md frontmatter missing "description"`)
      } else if (fields.description.length > 1024) {
        fail(`skills/${dirName}: description is ${fields.description.length} chars (max 1024)`)
      }

      const body = await readFile(skillMd, 'utf8')
      if (body.split('\n').length > 500) {
        warn(`skills/${dirName}: SKILL.md is over 500 lines — move detail into references/`)
      }

      // Self-containment: a shipped skill may be copied out of this repo alone,
      // so links escaping the skill directory break on install.
      const escaping = [...body.matchAll(/\]\((\.\.\/[^)]+)\)/g)].map((m) => m[1])
      for (const rel of escaping) {
        fail(`skills/${dirName}: SKILL.md links outside its own directory (${rel}) — inline the content instead`)
      }
    }
  }

  // --- drift: skill directories that exist but are not registered ---
  for (const dirName of await listSkillDirs(skillsRoot)) {
    if (!registered.has(dirName)) {
      fail(`skills/${dirName}: exists on disk but is not registered in .claude-plugin/marketplace.json`)
    }
  }

  return report()
}

function report() {
  for (const w of warnings) console.warn(`warn: ${w}`)
  for (const e of errors) console.error(`error: ${e}`)

  if (errors.length === 0) {
    console.log('marketplace.json OK')
    return 0
  }
  console.error(`\n${errors.length} problem(s) found`)
  return 1
}

process.exitCode = await main()