// Renders every mockup in design/mockups/*.html to a 2x PNG in design/shots/.
//
// Usage:  cd design && node render.mjs [name ...]
// With no arguments it renders every mockup. Names may omit the .html suffix.
//
// Requires the pre-installed Chromium (PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers).
// Do not run "playwright install" — the browser is already on disk.

import { chromium } from 'playwright'
import { readdir, mkdir, stat } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const MOCKUPS = path.join(HERE, 'mockups')
const SHOTS = path.join(HERE, 'shots')
const CHROME = '/opt/pw-browsers/chromium-1194/chrome-linux/chrome'

// Each mockup may declare its own viewport via <meta name="shot-viewport" content="1440x960">.
const DEFAULT_VIEWPORT = { width: 1440, height: 900 }

async function main() {
  const wanted = process.argv.slice(2).map((n) => n.replace(/\.html$/, ''))
  const all = (await readdir(MOCKUPS)).filter((f) => f.endsWith('.html')).sort()
  const files = wanted.length ? all.filter((f) => wanted.includes(f.replace(/\.html$/, ''))) : all

  if (files.length === 0) {
    console.error(`no mockups matched. available: ${all.join(', ') || '(none)'}`)
    process.exit(1)
  }

  await mkdir(SHOTS, { recursive: true })
  const browser = await chromium.launch({ executablePath: CHROME })

  const results = []
  for (const file of files) {
    const name = file.replace(/\.html$/, '')
    const page = await browser.newPage({ viewport: DEFAULT_VIEWPORT, deviceScaleFactor: 2 })
    try {
      await page.goto(`file://${path.join(MOCKUPS, file)}`, { waitUntil: 'load' })

      // Honour a per-mockup viewport override.
      const declared = await page
        .locator('meta[name="shot-viewport"]')
        .getAttribute('content')
        .catch(() => null)
      if (declared) {
        const [w, h] = declared.split('x').map((n) => parseInt(n, 10))
        if (Number.isFinite(w) && Number.isFinite(h)) await page.setViewportSize({ width: w, height: h })
      }

      // Let fonts settle and any entrance animation finish before capturing.
      await page.evaluate(() => document.fonts.ready)
      await page.waitForTimeout(450)

      const out = path.join(SHOTS, `${name}.png`)
      await page.screenshot({ path: out })
      const { size } = await stat(out)
      results.push({ name, out, kb: Math.round(size / 1024) })
      console.log(`ok   ${name}  ->  ${path.relative(HERE, out)}  (${Math.round(size / 1024)} KB)`)
    } catch (error) {
      console.error(`FAIL ${name}: ${error.message}`)
      process.exitCode = 1
    } finally {
      await page.close()
    }
  }

  await browser.close()
  console.log(`\nrendered ${results.length}/${files.length} mockups into design/shots/`)
}

await main()
