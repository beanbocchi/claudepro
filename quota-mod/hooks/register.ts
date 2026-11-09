import type { Register } from 'claude-code'

// quota.json, beside .claude-plugin/, is written by the claudepro installer:
// { "url": "http://host:8318/quota", "keyFile": "<absolute path of the API key>" }
type Setup = { url: string; keyFile: string }

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'quota',
      description: "Plan limits of the claudepro server's accounts",
      immediate: true,
    })
    return next(e)
  })

  on('command.run', { command: 'quota' }, async $ => {
    let setup: Setup
    let key: string
    try {
      setup = JSON.parse(await $.fs.read(`${$.plugin.root}/quota.json`))
      key = (await $.fs.read(setup.keyFile)).trim()
    } catch (error) {
      return { text: `quota: cannot read the claudepro setup (${String(error)}); run the claudepro installer again` }
    }
    try {
      const res = await $.http.fetch(setup.url, { headers: { Authorization: `Bearer ${key}` } })
      return { text: res.ok ? res.text : `quota: the server answered HTTP ${res.status}: ${res.text}` }
    } catch (error) {
      return { text: `quota: cannot reach ${setup.url} (${String(error)})` }
    }
  })
}
