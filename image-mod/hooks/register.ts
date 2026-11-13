import type { EngineInterface, Register } from 'claude-code'

const NAME = 'generate_image'
const TOOL = 'mcp__claudepro-image__generate_image'
const SET_NAME = 'set_default_image_model'
const SET_TOOL = 'mcp__claudepro-image__set_default_image_model'
const COMMAND = 'modelimg'
// The default image model, kept in this mod's store across sessions.
const STORE_KEY = 'defaultModel'
// Generation on the server takes up to a few minutes; bin/imagegen.py gives up after 300 s.
const TIMEOUT_MS = 330_000
const LIST_TIMEOUT_MS = 20_000

const FIELDS = ['prompt', 'output_path', 'model', 'size', 'quality', 'background', 'reference_images']

// Read at each session start: the server's image models, newest first, and
// whether anyone can be asked. Module variables start over on a reload, and
// session.start runs again then.
let models: string[] = []
let isInteractive = true

function description(saved: string | undefined): string {
  const choice = saved
    ? `The default image model is ${saved}, which the person chose: use it without asking, and another listed model only when the person names one.`
    : isInteractive
      ? `No default image model is set. Unless the person named a model, ask them once which one to use before the first image; the model of the first image becomes the default for later conversations.`
      : `No default image model is set and nobody can be asked in this session: use ${models[0]} unless the prompt names another.`
  return [
    'Generates an image with an image model on the claudepro server (the same server this session talks to) and saves it to output_path.',
    'Use it whenever the task needs a picture: an illustration, icon, logo, mascot, photo, texture, sprite or UI asset.',
    'Use it instead of drawing the image in code (SVG, Pillow, canvas) or running another program such as Codex.',
    `The server's image models, newest first: ${models.join(', ')}.`,
    choice,
    `When the person asks to change the default image model, call ${SET_NAME}; they can also run /${COMMAND}.`,
    'With reference_images it calls the edits endpoint: the new image edits those files or keeps their style and subject.',
    'One image per call; for variants, make several calls in parallel with different output paths.',
    'It overwrites output_path. The answer gives the saved path; Read that path to look at the image.',
  ].join(' ')
}

function inputSchema(saved: string | undefined) {
  // The model may be left out once a default exists, or when nobody can be asked.
  const mustName = !saved && isInteractive
  return {
    type: 'object',
    properties: {
      prompt: { type: 'string', description: 'What to draw, in detail: subject, style, composition, colours, text in the image.' },
      output_path: {
        type: 'string',
        description: 'Where to save it, absolute or relative to the working directory, ending in .png, .jpg, .jpeg or .webp. Missing folders are created.',
      },
      model: {
        type: 'string',
        enum: models,
        description: saved ? `Leave out for the default, ${saved}.` : 'The image model the person chose.',
      },
      size: { type: 'string', description: '1024x1024 (default), 1536x1024 (landscape), 1024x1536 (portrait) or auto.' },
      quality: { type: 'string', enum: ['low', 'medium', 'high', 'auto'] },
      background: { type: 'string', enum: ['transparent', 'opaque', 'auto'], description: 'transparent needs .png or .webp.' },
      reference_images: {
        type: 'array',
        items: { type: 'string' },
        description: 'Paths of images to edit or to take the style from.',
      },
    },
    required: mustName ? ['prompt', 'output_path', 'model'] : ['prompt', 'output_path'],
    additionalProperties: false,
  }
}

// The saved default, while the server still offers it.
async function savedDefault($: EngineInterface): Promise<string | undefined> {
  const value = await $.store.get(STORE_KEY)
  return typeof value === 'string' && models.includes(value) ? value : undefined
}

// Registers both tools again, so their descriptions name the current default
// from the next prompt on.
async function registerTools($: EngineInterface) {
  const saved = await savedDefault($)
  await $.tool.register({ name: NAME, description: description(saved), inputSchema: inputSchema(saved), isDeferred: false })
  await $.tool.register({
    name: SET_NAME,
    description: `Saves the default image model that ${NAME} uses in this and later conversations. Call it when the person asks to change the default image model.`,
    inputSchema: {
      type: 'object',
      properties: { model: { type: 'string', enum: models } },
      required: ['model'],
      additionalProperties: false,
    },
  })
}

async function setDefault($: EngineInterface, model: string) {
  await $.store.set(STORE_KEY, model)
  await registerTools($)
}

type Ran = { exitCode: number; stdout: string; stderr: string }
type Generated = { path: string; bytes: number; model: string; revised_prompt?: string }

// Runs bin/imagegen.py with python3, or python where that is the only name (Windows).
// Resolves the run, or a reason it could not run.
async function runImagegen($: EngineInterface, args: string[], stdin: string, timeoutMs: number): Promise<Ran | string> {
  const script = `${$.plugin.root}/bin/imagegen.py`
  let startError = ''
  for (const python of ['python3', 'python']) {
    const startedAt = await $.clock.now()
    try {
      return await $.process.run([python, script, ...args], { stdin, timeoutMs })
    } catch (error) {
      // A rejection after a few seconds is the timeout, so trying the next name would only wait again.
      if ((await $.clock.now()) - startedAt > 5_000) return `imagegen.py ran past ${timeoutMs / 1000} s`
      startError = String(error)
    }
  }
  return `cannot run ${script} with python3 or python (${startError})`
}

export const register: Register = on => {
  // The tools and /modelimg are there only when the server offers an image model.
  on('session.start', async ($, e, next) => {
    isInteractive = e.isInteractive
    models = []
    const ran = await runImagegen($, ['--list-models'], '', LIST_TIMEOUT_MS)
    if (typeof ran !== 'string' && ran.exitCode === 0) models = JSON.parse(ran.stdout) as string[]
    if (models.length > 0) {
      await registerTools($)
      await $.command.register({
        name: COMMAND,
        description: 'Show or set the default model of the generate_image tool',
        argumentHint: '[model]',
        immediate: true,
      })
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('command.run', { command: COMMAND }, async ($, e) => {
    const wanted = (e.args ?? '').trim()
    if (wanted && !models.includes(wanted)) {
      return { text: `modelimg: ${wanted} is not an image model on the server. It offers: ${models.join(', ')}` }
    }
    if (wanted) {
      await setDefault($, wanted)
      return { text: `Default image model: ${wanted}` }
    }
    const saved = await savedDefault($)
    const rows = models.map(model => `${model === saved ? '* ' : '  '}${model}`)
    const head = saved ? `Default image model: ${saved}` : 'No default image model yet: Claude asks before the first image and keeps that choice.'
    return { text: [head, ...rows, `Set it with /${COMMAND} <model>.`].join('\n') }
  }).catch(($, e, next) => (next.called ? next(e) : { text: `modelimg: ${String(next.error.message ?? 'failed')}` }))

  on('tool.call', { tool: SET_TOOL }, async ($, e) => {
    const model = (e as unknown as Record<string, unknown>).model
    if (typeof model !== 'string' || !models.includes(model)) {
      return failure(`${String(model)} is not an image model on the server; it offers ${models.join(', ')}`, SET_NAME)
    }
    await setDefault($, model)
    return { result: `The default image model is now ${model}.` }
  }).catch(($, e, next) => (next.called ? next(e) : failure(String(next.error.message ?? 'the hook failed'), SET_NAME)))

  on('tool.call', { tool: TOOL }, async ($, e) => {
    const args = e as unknown as Record<string, unknown>
    const input: Record<string, unknown> = Object.fromEntries(FIELDS.filter(k => args[k] !== undefined).map(k => [k, args[k]]))
    const saved = await savedDefault($)
    if (input.model === undefined) {
      input.model = saved ?? (isInteractive ? undefined : models[0])
      if (input.model === undefined) return failure(`no default image model is set; ask the person which to use: ${models.join(', ')}`)
    }

    const ran = await runImagegen($, [], JSON.stringify(input), TIMEOUT_MS)
    if (typeof ran === 'string') return failure(ran)
    if (ran.exitCode !== 0) return failure(ran.stderr.trim() || `imagegen.py exited with code ${ran.exitCode}`)

    const out = JSON.parse(ran.stdout) as Generated
    const lines = [`Saved ${out.path} (${out.bytes} bytes, ${out.model}).`]
    if (out.revised_prompt) lines.push(`The model revised the prompt to: ${out.revised_prompt}`)
    // The first image's model becomes the default, so the person is asked once.
    if (!saved && isInteractive && models.includes(out.model)) {
      await setDefault($, out.model)
      lines.push(`${out.model} is now the default image model; the person can change it with /${COMMAND} or by asking.`)
    }
    return { result: lines.join('\n') }
  }).catch(($, e, next) => (next.called ? next(e) : failure(String(next.error.message ?? 'the hook failed'))))
}

function failure(reason: string, tool = NAME) {
  return { isError: true as const, result: `${tool} failed: ${reason}` }
}
