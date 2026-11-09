import { expect, test } from 'claude-code/testing'

const SETUP = JSON.stringify({ url: 'http://quota.test:8318/quota', keyFile: '/keys/claudepro.key' })

function fakeFiles(on: Parameters<Parameters<typeof test>[1]>[1], files: Record<string, string>) {
  on('fs.read', ($, e) => {
    const hit = Object.entries(files).find(([suffix]) => e.path.endsWith(suffix))
    if (!hit) throw new Error(`ENOENT: ${e.path}`)
    return { value: hit[1] }
  })
}

test('/quota prints the server table, sending the key from keyFile', async ($, on) => {
  fakeFiles(on, { '/quota.json': SETUP, '/keys/claudepro.key': 'sk-test\n' })
  const seen: { url: string; auth?: string }[] = []
  on('http.fetch', ($, e) => {
    seen.push({ url: e.url, auth: e.init?.headers?.Authorization })
    return { value: { status: 200, ok: true, headers: {}, text: 'Quota on test\nClaude  a@b  5-hour 10%' } }
  })
  const { text } = await $.command.run({ command: 'quota' })
  expect(text).toBe('Quota on test\nClaude  a@b  5-hour 10%')
  expect(seen).toEqual([{ url: 'http://quota.test:8318/quota', auth: 'Bearer sk-test' }])
})

test('/quota shows the HTTP status when the server refuses the key', async ($, on) => {
  fakeFiles(on, { '/quota.json': SETUP, '/keys/claudepro.key': 'sk-old' })
  on('http.fetch', () => ({ value: { status: 401, ok: false, headers: {}, text: 'invalid key' } }))
  const { text } = await $.command.run({ command: 'quota' })
  expect(text).toBe('quota: the server answered HTTP 401: invalid key')
})

test('/quota says to rerun the installer when quota.json is missing', async ($, on) => {
  fakeFiles(on, {})
  const { text } = await $.command.run({ command: 'quota' })
  expect(text).toMatch(/^quota: cannot read the claudepro setup .*run the claudepro installer again$/)
})

test('/quota names the URL when the server is unreachable', async ($, on) => {
  fakeFiles(on, { '/quota.json': SETUP, '/keys/claudepro.key': 'sk-test' })
  on('http.fetch', () => ({ deny: 'connect ETIMEDOUT' }))
  const { text } = await $.command.run({ command: 'quota' })
  expect(text).toMatch(/^quota: cannot reach http:\/\/quota\.test:8318\/quota \(/)
})
