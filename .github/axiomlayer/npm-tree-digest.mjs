import { createHash } from 'node:crypto'
import { readFile, readdir } from 'node:fs/promises'
import { join } from 'node:path'

const root = process.argv[2]

if (!root) {
  throw new Error('usage: node npm-tree-digest.mjs <npm-root>')
}

const files = []

const visit = async (directory, parts = []) => {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const nextParts = [...parts, entry.name]
    const path = join(directory, entry.name)

    if (entry.isDirectory()) {
      await visit(path, nextParts)
    } else if (entry.isFile()) {
      files.push({ path, relative: nextParts.join('/') })
    }
  }
}

await visit(root)
files.sort((left, right) =>
  left.relative < right.relative ? -1 : left.relative > right.relative ? 1 : 0
)

const records = []
for (const file of files) {
  const digest = createHash('sha256').update(await readFile(file.path)).digest('hex')
  records.push(`${digest}  npm/${file.relative}\n`)
}

process.stdout.write(`${createHash('sha256').update(records.join('')).digest('hex')}\n`)
