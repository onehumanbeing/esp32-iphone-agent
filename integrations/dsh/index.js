/** Registers the handsy skill that teaches the agent the see-act loop for the esp32agent MCP tools. */

import { readFile } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-esp32agent'
export const inject = ['skills']

const SKILL_DIR = fileURLToPath(new URL('./skills/handsy/', import.meta.url))
const SKILL_PATH = `${SKILL_DIR}SKILL.md`
// Same rank as dsh's bundled skills (BUNDLED_SKILL_RANK), so a user's own handsy skill wins.
const RANK = 600

function parse(raw) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/u.exec(raw)
  if (!match) throw new Error(`dsh-esp32agent: ${SKILL_PATH} has no frontmatter`)
  const description = /^description:\s*(.+)$/mu.exec(match[1])?.[1]?.trim()
  if (!description) throw new Error(`dsh-esp32agent: ${SKILL_PATH} has no description`)
  return { description, content: raw.slice(match[0].length).trim() }
}

export function apply(ctx) {
  const { description } = parse(readFileSync(SKILL_PATH, 'utf8'))
  const candidate = {
    name: 'handsy', description,
    invocation: { modelInvocable: true, userInvocable: true },
    provider: name, source: 'bundled', rank: RANK,
    resourceBase: { kind: 'directory', path: SKILL_DIR },
    locator: SKILL_PATH,
  }
  ctx.skills.registerProvider(() => ({
    name,
    list: () => Promise.resolve([candidate]),
    async get(c, options) {
      const { rank: _rank, locator, ...summary } = c
      const raw = await readFile(locator, { encoding: 'utf8', signal: options?.signal })
      return { ...summary, content: parse(raw).content }
    },
  }))
}
