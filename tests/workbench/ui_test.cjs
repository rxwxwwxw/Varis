// Optional browser smoke test: NODE_PATH=<playwright modules> node tests/workbench/ui_test.cjs <varis>
// VARIS_BROWSER may name a Chromium executable. The protocol suite needs no browser or Node.
const { chromium } = require('playwright');
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'varis-workbench-ui-'));
  const root = path.resolve(__dirname, '../..');
  const project = path.join(temporary, 'game');
  await fs.cp(path.join(root, 'sample-game'), project, { recursive: true });
  const server = spawn(path.resolve(process.argv[2] || 'bin/varis'), ['serve', '--port', '0', project]);
  let browser, page;
  try {
    const address = await new Promise((resolve, reject) => {
      let text = '';
      server.stdout.on('data', data => { text += data; const m = text.match(/http:\/\/127\.0\.0\.1:\d+\/\?token=[a-f0-9]+/); if (m) resolve(m[0]); });
      server.on('exit', code => reject(new Error('server exited: ' + code)));
      server.stderr.on('data', data => process.stderr.write(data));
    });
    browser = await chromium.launch({ headless: true, ...(process.env.VARIS_BROWSER ? { executablePath: process.env.VARIS_BROWSER } : {}) });
    page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
    page.setDefaultTimeout(10000);
    const errors = [];
    page.on('pageerror', error => { errors.push(error.message); console.error(error.message); });
    await page.goto(address);
    await page.waitForFunction(() => source.value.length > 0);
    await page.selectOption('#files', 'content/lamp.lua');
    await page.waitForFunction(() => source.value.includes('storylet lamp'));
    const original = await page.evaluate(() => source.value);
    const draft = original + '\n-- unsaved 日本語 🐈\n';
    await page.locator('.cm-content[contenteditable=true]').fill(draft);
    await page.waitForFunction(text => source.value === text, draft);
    await page.selectOption('#files', 'world.lua');
    await page.waitForFunction(() => source.value.includes('M.build_world'));
    await page.selectOption('#files', 'content/lamp.lua');
    await page.waitForFunction(() => source.value.includes('-- unsaved'));
    assert.equal(await page.evaluate(() => source.value), draft);
    await page.evaluate(() => { const at = source.value.indexOf('carries(:player'); source.setSelectionRange(at, at); });
    await page.click('#hover');
    await page.waitForFunction(() => document.getElementById('editorInfo').textContent.includes('relation carries'));
    await page.click('#definition');
    await page.waitForFunction(() => document.getElementById('files').value === 'world.lua');
    await page.selectOption('#files', 'content/lamp.lua');
    await page.waitForFunction(() => source.value.includes('-- unsaved'));
    await page.evaluate(() => { const at = source.value.indexOf('carries(:player'); source.setSelectionRange(at, at); });
    page.once('dialog', dialog => dialog.accept('holds'));
    await page.click('#rename');
    await page.getByText('Apply to drafts', { exact: true }).click();
    await page.waitForFunction(() => source.value.includes('holds(:player'));
    assert.equal(await fs.readFile(path.join(project, 'content/lamp.lua'), 'utf8'), original);
    await page.click('#save');
    await page.waitForFunction(() => document.getElementById('dirty').textContent === '');
    assert.match(await fs.readFile(path.join(project, 'world.lua'), 'utf8'), /relation holds\(/);
    assert.match(await fs.readFile(path.join(project, 'content/lamp.lua'), 'utf8'), /-- unsaved 日本語 🐈/);
    // Completion uses the shared frontend and inserts its selected result.
    const beforeCompletion = await page.evaluate(() => source.value);
    await page.evaluate(() => { source.value += '\nhol'; source.setSelectionRange(source.value.length, source.value.length); source.focus(); });
    await page.keyboard.press('Tab');
    await page.waitForSelector('.cm-tooltip-autocomplete');
    await page.locator('.cm-completionLabel').filter({ hasText: /^holds$/ }).click();
    await page.waitForFunction(() => source.value.endsWith('\nholds'));
    await page.evaluate(text => { source.value = text; }, beforeCompletion);
    // Inline compiler diagnostics appear on the text and in the gutter, then clear.
    const clean = await page.evaluate(() => source.value);
    await page.evaluate(() => { source.value += "\nlocal = broken\n"; });
    await page.waitForSelector('.cm-lintRange-error');
    assert.ok(await page.locator('.cm-lint-marker-error').count());
    await page.evaluate(text => { source.value = text; }, clean);
    await page.waitForFunction(() => !document.querySelector('.cm-lintRange-error'));
    // The margin toggles actual server breakpoints, not just an editor decoration.
    await page.evaluate(async () => { source.selectLine(1); await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); });
    const number = await page.locator('.cm-lineNumbers .cm-gutterElement').filter({ hasText: /^1$/ }).boundingBox();
    const margin = await page.locator('.cm-breakpoints').boundingBox();
    await page.mouse.click(margin.x + margin.width / 2, number.y + number.height / 2);
    await page.waitForFunction(() => document.getElementById('breaks').textContent.includes('content/lamp.lua:1'));
    assert.ok(await page.locator('.cm-breakpoints .cm-gutterElement').filter({ hasText: '●' }).count());
    await page.evaluate(() => { source.value = '\n' + source.value; });
    await page.waitForFunction(() => document.getElementById('breaks').textContent.includes('content/lamp.lua:2'));
    await page.locator('.cm-breakpoints span[title="Breakpoint (click to remove)"]:visible').click();
    await page.waitForFunction(() => document.getElementById('breaks').textContent === '');
    // Ordinary typing has undo history, preserved when another file is opened.
    const area = page.locator('.cm-content[contenteditable=true]');
    await area.press('ControlOrMeta+End');
    await area.press('Enter');
    await area.pressSequentially('-- undo retained');
    await page.selectOption('#files', 'world.lua');
    await page.waitForFunction(() => source.value.includes('M.build_world'));
    await page.selectOption('#files', 'content/lamp.lua');
    await page.waitForFunction(() => source.value.includes('-- undo retained'));
    await area.press('ControlOrMeta+z');
    await page.waitForFunction(() => !source.value.includes('-- undo retained'));
    await page.click('#startStory');
    await page.waitForFunction(() => document.getElementById('turn').textContent === 'turn 0');
    await page.locator('#storyBody .storylet button').first().click();
    await page.waitForFunction(() => document.getElementById('turn').textContent === 'turn 1');
    await page.click('#reloadStory');
    await page.waitForFunction(() => document.getElementById('turn').textContent === 'turn 1');
    page.once('dialog', dialog => dialog.accept('0'));
    await page.click('#rewindStory');
    await page.waitForFunction(() => document.getElementById('turn').textContent === 'turn 0');
    // Splitters support pointer and keyboard input and survive a page reload.
    const before = await page.locator('#columnSplit').getAttribute('aria-valuenow');
    await page.locator('#columnSplit').focus();
    await page.keyboard.press('ArrowRight');
    await page.waitForFunction(value => document.getElementById('columnSplit').getAttribute('aria-valuenow') !== value, before);
    const box = await page.locator('#storySplit').boundingBox();
    const topBefore = await page.locator('#storySplit').getAttribute('aria-valuenow');
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2, box.y + 45);
    await page.mouse.up();
    await page.waitForFunction(value => document.getElementById('storySplit').getAttribute('aria-valuenow') !== value, topBefore);
    const layout = await page.evaluate(() => localStorage.getItem('varis.workbench.layout'));
    await page.locator('#input').fill('6 * 7');
    await page.locator('#input').press('Enter');
    await page.waitForFunction(() => document.getElementById('log').textContent.includes('42'));
    await page.click('#toggleHistory');
    await page.locator('#commandHistory button').filter({ hasText: '6 * 7' }).click();
    assert.equal(await page.locator('#input').inputValue(), '6 * 7');
    await page.reload();
    await page.waitForFunction(() => source.value.length > 0);
    assert.equal(await page.evaluate(() => localStorage.getItem('varis.workbench.layout')), layout);
    await page.click('#toggleHistory');
    await page.locator('#commandHistory button').filter({ hasText: '6 * 7' }).click();
    assert.equal(await page.locator('#input').inputValue(), '6 * 7');
    assert.deepEqual(errors, []);
    if (process.env.VARIS_UI_SCREENSHOT) await page.screenshot({ path: process.env.VARIS_UI_SCREENSHOT });
    console.log('workbench browser tests passed');
  } catch (error) {
    if (page && process.env.VARIS_UI_SCREENSHOT) await page.screenshot({ path: process.env.VARIS_UI_SCREENSHOT }).catch(() => {});
    throw error;
  } finally {
    if (browser) await browser.close();
    server.kill();
    await fs.rm(temporary, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
