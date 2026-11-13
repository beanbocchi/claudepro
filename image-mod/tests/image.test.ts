import { expect, test } from 'claude-code/testing'

const TOOL = 'mcp__claudepro-image__generate_image'
type On = Parameters<Parameters<typeof test>[1]>[1]

// Each clock.now answers the next value, so a test sets how long a run seems to take.
function clock(on: On, ...times: number[]) {
  on('clock.now', () => ({ value: times.length > 1 ? times.shift()! : times[0]! }))
}

const SAVED = JSON.stringify({ path: '/work/cat.png', bytes: 1234, model: 'gpt-image-2.5' })

test('session.start lists generate_image in the prompt, outside ToolSearch', async ($, on) => {
  const registered: { name: string; isDeferred?: unknown; required?: unknown }[] = []
  on('tool.register', ($, e) => {
    registered.push({ name: e.name, isDeferred: e.isDeferred, required: e.inputSchema.required })
    return { value: { tool: TOOL } }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect(registered).toEqual([{ name: 'generate_image', isDeferred: false, required: ['prompt', 'output_path'] }])
})

test('a call runs imagegen.py with the schema fields on stdin and reports the saved file', async ($, on) => {
  clock(on, 0)
  const runs: { argv: readonly string[]; stdin?: string }[] = []
  on('process.run', ($, e) => {
    runs.push({ argv: e.argv, stdin: e.init?.stdin })
    return { value: { exitCode: 0, stdout: SAVED, stderr: '' } }
  })
  const ran = await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png', size: '1024x1024' })
  expect(ran.result).toBe('Saved /work/cat.png (1234 bytes, gpt-image-2.5).')
  expect(runs).toHaveLength(1)
  expect(runs[0]!.argv[0]).toBe('python3')
  expect(runs[0]!.argv[1]).toMatch(/\/bin\/imagegen\.py$/)
  expect(JSON.parse(runs[0]!.stdin!)).toEqual({ prompt: 'a cat', output_path: 'cat.png', size: '1024x1024' })
})

test('without python3 it runs python', async ($, on) => {
  clock(on, 0)
  const tried: string[] = []
  on('process.run', ($, e) => {
    tried.push(e.argv[0]!)
    if (e.argv[0] === 'python3') return { deny: 'spawn python3 ENOENT' }
    return { value: { exitCode: 0, stdout: SAVED, stderr: '' } }
  })
  const ran = await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png' })
  expect(tried).toEqual(['python3', 'python'])
  expect(ran.result).toBe('Saved /work/cat.png (1234 bytes, gpt-image-2.5).')
})

test('a server error reaches the model as an error result', async ($, on) => {
  clock(on, 0)
  on('process.run', () => ({ value: { exitCode: 1, stdout: '', stderr: 'the server answered HTTP 429: quota\n' } }))
  const ran = await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png' })
  expect(ran.isError).toBe(true)
  expect(ran.text ?? ran.result).toBe('generate_image failed: the server answered HTTP 429: quota')
})

test('a timeout ends the call without trying python', async ($, on) => {
  clock(on, 0, 330_500)
  const tried: string[] = []
  on('process.run', ($, e) => {
    tried.push(e.argv[0]!)
    return { deny: 'timed out' }
  })
  const ran = await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png' })
  expect(tried).toEqual(['python3'])
  expect(ran.text ?? ran.result).toBe('generate_image failed: imagegen.py ran past 330 s')
})
