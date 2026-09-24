// Explicit real-worker test. Run with the configured app and dedicated worker already up.
import {chromium, expect} from '../assets/node_modules/@playwright/test/index.mjs';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const phase=process.argv[2] || 'before-restart';
const evidence=process.env.WORKSPACE_EVIDENCE || '.workspace/browser-evidence';
await mkdir(evidence,{recursive:true});
const browser=await chromium.launch({headless:true});
const page=await browser.newPage({baseURL:process.env.WORKSPACE_URL || 'http://localhost:4000',viewport:{width:1440,height:1000}});
const errors=[];
page.on('pageerror',e=>errors.push(e.message));
page.on('console',msg=>{if(msg.type()==='error') errors.push(msg.text())});
const report={phase,checks:[],errors};
const record=(name,value=true)=>{report.checks.push({name,value});console.log(name,JSON.stringify(value));};
async function command(text,mode='foreground') {
  await expect(page.locator('#command')).toBeEnabled({timeout:20000});
  await page.locator('#command').fill(text);
  await page.locator('#command-form [name=mode]').selectOption(mode);
  await page.locator('#command-form [name=timeout]').evaluate(el=>el.value='30');
  const token=await page.locator('#command-form [name=token]').inputValue();
  await page.locator('#command-form button[type=submit]').click();
  const activity=page.locator(`#action-${token}`);
  await expect(activity.locator('.state')).toHaveText(mode==='background'?'Launched':'Completed',{timeout:30000});
  return {token,activity};
}
try {
  await page.goto(process.env.WORKSPACE_URL || 'http://localhost:4000');
  await page.locator('#machine-id,.welcome').first().waitFor({timeout:30000});
  if(await page.getByRole('button',{name:'Create workspace'}).isVisible()) {
    await page.getByRole('button',{name:'Create workspace'}).click();
    await expect(page.locator('#machine-state')).toHaveText('Created',{timeout:30000});
  }
  await expect(page.locator('#machine-id')).toBeVisible({timeout:20000});
  if(await page.getByRole('button',{name:'Start machine'}).isVisible()) await page.getByRole('button',{name:'Start machine'}).click();
  await expect(page.locator('#machine-state')).toHaveText('Running',{timeout:30000});
  const identity=await page.locator('#machine-id').textContent();
  record('machine identity',identity);
  if(phase==='before-restart') {
    const bytes=Buffer.alloc(2*1024*1024,0x61);
    const digest=createHash('sha256').update(bytes).digest('hex');
    await page.locator('#upload-form [name=path]').fill('/app/project/community.bin');
    await page.locator('input[type=file]').setInputFiles({name:'community.bin',mimeType:'application/octet-stream',buffer:bytes});
    await page.getByRole('button',{name:'Upload to machine'}).click();
    const upload=await page.locator('#upload-form [name=token]').inputValue();
    await expect(page.locator(`#action-${upload} .state`)).toHaveText('Completed',{timeout:30000});
    record('2 MiB browser upload',digest);
    const verified=await command("python3 -c \"import hashlib; print(hashlib.sha256(open('community.bin','rb').read()).hexdigest())\"");
    await expect(verified.activity).toContainText(digest);
    await expect(page.getByRole('button',{name:'Collect file'})).toBeEnabled();
    await page.locator('#download-form [name=path]').fill('/app/project/community.bin');
    const collection=await page.locator('#download-form [name=token]').inputValue();
    await page.getByRole('button',{name:'Collect file'}).click();
    const link=page.locator(`#action-${collection}`).getByRole('link',{name:'Download collected file'});
    await expect(link).toBeVisible({timeout:30000});
    const response=await page.request.get(await link.getAttribute('href'));
    expect(createHash('sha256').update(await response.body()).digest('hex')).toBe(digest);
    record('2 MiB browser download hash matches');
    await command(": > background.txt; printf 'retained-through-restart\\n' > retained.txt; printf '<h1>Community workspace survives</h1>' > index.html");
    const background=await command("printf 'launched-once\\n' >> background.txt; sleep 300",'background');
    await expect(background.activity).toContainText(/Launch confirmed · PID [1-9]/);
    record('typed background launch evidence',await background.activity.locator('.result-label').textContent());
    // Same browser identity resubmitted, deliberately without editing or New run.
    await expect(page.locator('#command-form button[type=submit]')).toBeEnabled();
    await page.locator('#command-form button[type=submit]').click();
    await expect(page.locator(`#action-${background.token}`)).toHaveCount(1);
    const count=await command('wc -l < background.txt');
    await expect(count.activity.locator('.output')).toContainText('1');
    record('duplicate launch was not replayed');
    await expect(page.getByRole('button',{name:'Open terminal'})).toBeEnabled();
    await page.getByRole('button',{name:'Open terminal'}).click();
    await expect(page.getByRole('button',{name:'Disconnect terminal'})).toBeVisible({timeout:15000});
    await expect(page.locator('.xterm-accessibility-tree')).toContainText('/ #',{timeout:15000});
    await page.locator('.xterm-helper-textarea').focus();
    await page.keyboard.type("printf 'terminal-ready\\n'; stty size");
    await page.keyboard.press('Enter');
    await expect(page.locator('.xterm-accessibility-tree')).toContainText('terminal-ready',{timeout:15000});
    const firstSize=(await page.locator('.xterm-accessibility-tree').innerText()).match(/\b(\d+ \d+)\b/)[1];
    await page.setViewportSize({width:1100,height:850});
    await page.waitForTimeout(250);
    await page.keyboard.type('stty size'); await page.keyboard.press('Enter');
    await expect.poll(async()=> (await page.locator('.xterm-accessibility-tree').innerText()).match(/\b(\d+ \d+)\b/g)?.filter(size=>size!==firstSize).length || 0).toBeGreaterThan(0);
    record('PTY input/output and resize',await page.locator('.xterm-accessibility-tree').innerText());
    await page.keyboard.press('Escape');
    await expect(page.getByRole('button',{name:'Disconnect terminal'})).toBeFocused();
    await page.locator('.xterm-helper-textarea').focus();
    await page.keyboard.type('exit'); await page.keyboard.press('Enter');
    await expect(page.locator('#notice')).toContainText('Terminal exited with code 0',{timeout:15000});
    record('PTY observed exit and keyboard escape');
    const url=await page.getByRole('link',{name:'Open service'}).getAttribute('href');
    expect(await (await page.request.get(url)).text()).toContain('Community workspace survives');
    record('mapped startup service reachable',url);
    const startEvidence=await command('wc -l < starts.txt');
    const starts=Number((await startEvidence.activity.locator('.output').innerText()).trim());
    await writeFile(`${evidence}/identity.json`,JSON.stringify({identity,digest,background:background.token,url,starts},null,2));
  } else {
    const previous=JSON.parse(await readFile(`${evidence}/identity.json`));
    expect(identity).toBe(previous.identity);
    record('same identity after controller restart');
    const check=await command('cat retained.txt; wc -l < background.txt');
    await expect(check.activity.locator('.output')).toContainText('retained-through-restart\n1');
    record('files retained and background launch not replayed after restart');
    await expect(page.getByRole('button',{name:'Stop machine'})).toBeEnabled();
    await page.getByRole('button',{name:'Stop machine'}).click();
    await expect(page.locator('#machine-state')).toHaveText('Stopped',{timeout:30000});
    record('machine stopped');
    await page.getByRole('button',{name:'Start machine'}).click();
    await expect(page.locator('#machine-state')).toHaveText('Running',{timeout:30000});
    const check2=await command("cat retained.txt; wc -l < background.txt; wc -l < starts.txt; python3 -c \"import hashlib; print(hashlib.sha256(open('community.bin','rb').read()).hexdigest())\"");
    await expect(check2.activity.locator('.output')).toContainText(`retained-through-restart\n1\n${previous.starts+1}`);
    await expect(check2.activity.locator('.output')).toContainText(previous.digest);
    expect(await (await page.request.get(previous.url)).text()).toContain('Community workspace survives');
    record('stop/start retained files, restarted workload, did not replay background');
    if(process.env.WORKSPACE_DELETE==='1') {
      await expect(page.getByRole('button',{name:'Delete',exact:true})).toBeEnabled();
      await page.getByRole('button',{name:'Delete',exact:true}).click();
      await page.getByRole('button',{name:'Confirm deletion'}).click();
      await expect(page.locator('#machine-state')).toHaveText('Deleted',{timeout:30000});
      await expect(page.locator('.deleted-note')).toContainText('released');
      record('explicit deletion with verified absence and reservation release');
    }
  }
  expect(errors).toEqual([]);
} finally {
  await writeFile(`${evidence}/${phase}.json`,JSON.stringify(report,null,2));
  await browser.close();
}
