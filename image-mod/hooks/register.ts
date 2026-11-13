import type { Register } from 'claude-code'

const NAME = 'generate_image'
const TOOL = 'mcp__claudepro-image__generate_image'
// Generation on the server takes up to a few minutes; bin/imagegen.py gives up after 300 s.
const TIMEOUT_MS = 330_000

const DESCRIPTION = [
  'Generates an image with a gpt-image model on the claudepro server (the same server this session talks to) and saves it to output_path.',
  'Use it whenever the task needs a picture: an illustration, icon, logo, mascot, photo, texture, sprite or UI asset.',
  'Use it instead of drawing the image in code (SVG, Pillow, canvas) or running another program such as Codex.',
  'With reference_images it calls the edits endpoint: the new image edits those files or keeps their style and subject.',
  'One image per call; for variants, make several calls in parallel with different output paths.',
  'It overwrites output_path. The answer gives the saved path; Read that path to look at the image.',
].join(' ')

const INPUT_SCHEMA = {
  type: 'object',
  properties: {
    prompt: { type: 'string', description: 'What to draw, in detail: subject, style, composition, colours, text in the image.' },
    output_path: {
      type: 'string',
      description: 'Where to save it, absolute or relative to the working directory, ending in .png, .jpg, .jpeg or .webp. Missing folders are created.',
    },
    size: { type: 'string', description: '1024x1024 (default), 1536x1024 (landscape), 1024x1536 (portrait) or auto.' },
    quality: { type: 'string', enum: ['low', 'medium', 'high', 'auto'] },
    background: { type: 'string', enum: ['transparent', 'opaque', 'auto'], description: 'transparent needs .png or .webp.' },
    reference_images: {
      type: 'array',
      items: { type: 'string' },
      description: 'Paths of images to edit or to take the style from.',
    },
    model: { type: 'string', description: 'gpt-image-2.5 (default), gpt-image-2 or another gpt-image model the server lists.' },
  },
  required: ['prompt', 'output_path'],
  additionalProperties: false,
}

const FIELDS = Object.keys(INPUT_SCHEMA.properties)

type Generated = { path: string; bytes: number; model: string; revised_prompt?: string }

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.tool.register({ name: NAME, description: DESCRIPTION, inputSchema: INPUT_SCHEMA, isDeferred: false })
    return next(e)
  })

  on('tool.call', { tool: TOOL }, async ($, e) => {
    const args = e as unknown as Record<string, unknown>
    const input = Object.fromEntries(FIELDS.filter(k => args[k] !== undefined).map(k => [k, args[k]]))
    const script = `${$.plugin.root}/bin/imagegen.py`
    const stdin = JSON.stringify(input)

    let ran: Awaited<ReturnType<typeof $.process.run>> | undefined
    let startError = ''
    // python3 on Linux and macOS; Windows installs usually name it python.
    for (const python of ['python3', 'python']) {
      const startedAt = await $.clock.now()
      try {
        ran = await $.process.run([python, script], { stdin, timeoutMs: TIMEOUT_MS })
        break
      } catch (error) {
        // A rejection after a few seconds is the timeout, so trying the next name would only wait again.
        if ((await $.clock.now()) - startedAt > 5_000) return failure(`imagegen.py ran past ${TIMEOUT_MS / 1000} s`)
        startError = String(error)
      }
    }
    if (!ran) return failure(`cannot run ${script} with python3 or python (${startError})`)
    if (ran.exitCode !== 0) return failure(ran.stderr.trim() || `imagegen.py exited with code ${ran.exitCode}`)

    const out = JSON.parse(ran.stdout) as Generated
    const lines = [`Saved ${out.path} (${out.bytes} bytes, ${out.model}).`]
    if (out.revised_prompt) lines.push(`The model revised the prompt to: ${out.revised_prompt}`)
    return { result: lines.join('\n') }
  }).catch(($, e, next) => (next.called ? next(e) : failure(String(next.error.message ?? 'the hook failed'))))
}

function failure(reason: string) {
  return { isError: true as const, result: `generate_image failed: ${reason}` }
}
