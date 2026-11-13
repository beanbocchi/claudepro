import { expect, mock, test } from 'claude-code/testing'

const TOOL = 'mcp__claudepro-image__generate_image'
const SET_TOOL = 'mcp__claudepro-image__set_default_image_model'
const MODELS = ['gpt-image-2.5', 'gpt-image-2']

type T = Parameters<Parameters<typeof test>[1]>
type Engine = T[0]
type On = T[1]
type Registered = { name: string; required?: unknown; description: string }
type Run = { argv: readonly string[]; stdin?: string }

// Each clock.now answers the next value, so a test sets how long a run seems to take.
function clock(on: On, ...times: number[]) {
  on('clock.now', () => ({ value: times.length > 1 ? times.shift()! : times[0]! }))
}

// Starts a session against a server offering `models`. imagegen.py runs are
// answered by `generate` (a generation) and recorded in `runs`.
async function start(
  $: Engine,
  on: On,
  options: {
    models?: string[]
    isInteractive?: boolean
    store?: Record<string, unknown>
    generate?: (run: Run) => unknown
    times?: number[]
  } = {},
) {
  clock(on, ...(options.times ?? [0]))
  mock.store(on, options.store ?? {})
  const tools: Registered[] = []
  const commands: string[] = []
  const runs: Run[] = []
  on('process.run', ($, e) => {
    if (e.argv.includes('--list-models')) {
      return { value: { exitCode: 0, stdout: JSON.stringify(options.models ?? MODELS), stderr: '' } }
    }
    const run = { argv: e.argv, stdin: e.init?.stdin }
    runs.push(run)
    if (options.generate) return options.generate(run) as never
    const model = JSON.parse(run.stdin!).model
    return { value: { exitCode: 0, stdout: JSON.stringify({ path: '/work/cat.png', bytes: 1234, model }), stderr: '' } }
  })
  on('tool.register', ($, e) => {
    const schema = e.inputSchema as { required?: unknown }
    tools.push({ name: e.name, required: schema.required, description: e.description })
    return { value: { tool: `mcp__claudepro-image__${e.name}` } }
  })
  on('command.register', ($, e) => {
    commands.push(e.name)
    return { value: { command: e.name } }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: options.isInteractive ?? true })
  // The latest registration of a tool is the one the model sees.
  const latest = (name: string) => [...tools].reverse().find(t => t.name === name)
  return { tools, commands, runs, latest }
}

const stdinOf = (run: Run | undefined) => JSON.parse(run!.stdin!)

test('with no default yet, Claude must name a model and is told to ask once', async ($, on) => {
  const { latest, commands } = await start($, on)
  const tool = latest('generate_image')!
  expect(tool.required).toEqual(['prompt', 'output_path', 'model'])
  expect(tool.description).toContain('newest first: gpt-image-2.5, gpt-image-2.')
  expect(tool.description).toContain('ask them once which one to use')
  expect(latest('set_default_image_model')).toBeDefined()
  expect(commands).toEqual(['modelimg'])
})

test('the first image sets the default, so later calls need no model', async ($, on) => {
  const { latest, runs } = await start($, on)
  const first = await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png', model: 'gpt-image-2' })
  expect(first.result).toBe(
    'Saved /work/cat.png (1234 bytes, gpt-image-2).\ngpt-image-2 is now the default image model; the person can change it with /modelimg or by asking.',
  )
  expect(latest('generate_image')!.required).toEqual(['prompt', 'output_path'])
  expect(latest('generate_image')!.description).toContain('The default image model is gpt-image-2')

  const second = await $.tool.call({ tool: TOOL, prompt: 'a dog', output_path: 'dog.png' })
  expect(second.result).toBe('Saved /work/cat.png (1234 bytes, gpt-image-2).')
  expect(stdinOf(runs[1]).model).toBe('gpt-image-2')
})

test('a saved default is used without asking', async ($, on) => {
  const { latest, runs } = await start($, on, { store: { defaultModel: 'gpt-image-2' } })
  expect(latest('generate_image')!.required).toEqual(['prompt', 'output_path'])
  await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png', size: '1024x1024' })
  expect(stdinOf(runs[0])).toEqual({ prompt: 'a cat', output_path: 'cat.png', model: 'gpt-image-2', size: '1024x1024' })
})

test('a saved default the server no longer offers counts as none', async ($, on) => {
  const { latest } = await start($, on, { store: { defaultModel: 'gpt-image-1' } })
  expect(latest('generate_image')!.required).toEqual(['prompt', 'output_path', 'model'])
})

test('with nobody to ask, the newest model is used and not saved', async ($, on) => {
  const { latest, runs } = await start($, on, { isInteractive: false })
  expect(latest('generate_image')!.required).toEqual(['prompt', 'output_path'])
  expect(latest('generate_image')!.description).toContain('use gpt-image-2.5 unless the prompt names another')
  const ran = await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png' })
  expect(ran.result).toBe('Saved /work/cat.png (1234 bytes, gpt-image-2.5).')
  expect(stdinOf(runs[0]).model).toBe('gpt-image-2.5')
})

test('/modelimg shows the models and sets the default', async ($, on) => {
  const { latest } = await start($, on)
  expect((await $.command.run({ command: 'modelimg' })).text).toBe(
    [
      'No default image model yet: Claude asks before the first image and keeps that choice.',
      '  gpt-image-2.5',
      '  gpt-image-2',
      'Set it with /modelimg <model>.',
    ].join('\n'),
  )
  expect((await $.command.run({ command: 'modelimg', args: ' gpt-image-2 ' })).text).toBe('Default image model: gpt-image-2')
  expect(latest('generate_image')!.description).toContain('The default image model is gpt-image-2')
  expect((await $.command.run({ command: 'modelimg' })).text).toContain('* gpt-image-2\n')
  expect((await $.command.run({ command: 'modelimg', args: 'dall-e' })).text).toBe(
    'modelimg: dall-e is not an image model on the server. It offers: gpt-image-2.5, gpt-image-2',
  )
})

test('asking in chat sets the default through set_default_image_model', async ($, on) => {
  const { runs } = await start($, on)
  expect((await $.tool.call({ tool: SET_TOOL, model: 'gpt-image-2.5' })).result).toBe('The default image model is now gpt-image-2.5.')
  await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png' })
  expect(stdinOf(runs[0]).model).toBe('gpt-image-2.5')
})

test('no image model on the server, no tools and no command', async ($, on) => {
  const { tools, commands } = await start($, on, { models: [] })
  expect(tools).toEqual([])
  expect(commands).toEqual([])
})

test('without python3 it runs python', async ($, on) => {
  clock(on, 0)
  mock.store(on, { defaultModel: 'gpt-image-2' })
  const tried: string[] = []
  on('process.run', ($, e) => {
    tried.push(e.argv[0]!)
    if (e.argv[0] === 'python3') return { deny: 'spawn python3 ENOENT' }
    const stdout = e.argv.includes('--list-models') ? JSON.stringify(MODELS) : JSON.stringify({ path: '/work/cat.png', bytes: 1, model: 'gpt-image-2' })
    return { value: { exitCode: 0, stdout, stderr: '' } }
  })
  on('tool.register', ($, e) => ({ value: { tool: e.name } }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ran = await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png' })
  expect(tried).toEqual(['python3', 'python', 'python3', 'python'])
  expect(ran.result).toBe('Saved /work/cat.png (1 bytes, gpt-image-2).')
})

test('a server error reaches the model as an error result', async ($, on) => {
  await start($, on, {
    store: { defaultModel: 'gpt-image-2' },
    generate: () => ({ value: { exitCode: 1, stdout: '', stderr: 'the server answered HTTP 429: quota\n' } }),
  })
  const ran = await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png' })
  expect(ran.isError).toBe(true)
  expect(ran.text ?? ran.result).toBe('generate_image failed: the server answered HTTP 429: quota')
})

test('a timeout ends the call without trying python', async ($, on) => {
  const tried: string[] = []
  await start($, on, {
    store: { defaultModel: 'gpt-image-2' },
    generate: run => {
      tried.push(run.argv[0]!)
      return { deny: 'timed out' }
    },
    // The model list starts at 0; the generation starts at 0 and fails at 330.5 s.
    times: [0, 0, 330_500],
  })
  const ran = await $.tool.call({ tool: TOOL, prompt: 'a cat', output_path: 'cat.png' })
  expect(tried).toEqual(['python3'])
  expect(ran.text ?? ran.result).toBe('generate_image failed: imagegen.py ran past 330 s')
})
