// Tests for the web page's post helpers (run: node scripts/test_web_posts.mjs). The helpers are the block between the
// "BEGIN pure post helpers" and "END pure post helpers" markers in web/app.js, evaluated here without a browser.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const src = readFileSync(new URL('../web/app.js', import.meta.url), 'utf8');
const block = src.slice(src.indexOf('// BEGIN pure post helpers'), src.indexOf('// END pure post helpers'));
assert.ok(block.length > 100, 'helper block found');
const ctx = { URL, Intl };
vm.createContext(ctx);
vm.runInContext(block + '\n;globalThis.H = { postEsc, safeHref, postTextHTML, postWho, postsSearchParams, postsScopeOffered, viewerZone };', ctx);
const H = ctx.H;
let n = 0;
const t = (name, f) => { f(); n++; console.log('ok', name); };

t('every character of a body, name, group or link is escaped', () => {
  const evil = `<img src=x onerror="alert(1)"> & 'q'`;
  assert.equal(H.postEsc(evil), '&lt;img src=x onerror=&quot;alert(1)&quot;&gt; &amp; &#39;q&#39;');
  assert.equal(H.postTextHTML({ body: evil, kind: 'status' }), H.postEsc(evil));
  assert.equal(H.postTextHTML({ body: null, context: '<b>Casey shared</b>', kind: 'link' }), '&lt;b&gt;Casey shared&lt;/b&gt;');
  assert.equal(H.postTextHTML({ body: null, context: null, link: 'javascript:alert(1)', kind: 'link' }), 'javascript:alert(1)');
  assert.equal(H.postTextHTML({ kind: '<script>' }), '(&lt;script&gt;)');
});

t('a search snippet is escaped before its match marks become <mark>', () => {
  assert.equal(H.postTextHTML({ snippet: '<b>\u0001birth</b>day\u0002', kind: 'status' }), '&lt;b&gt;<mark>birth&lt;/b&gt;day</mark>');
});

t('only http and https links are clickable', () => {
  assert.equal(H.safeHref('https://example.com/a?b=1'), 'https://example.com/a?b=1');
  assert.equal(H.safeHref('http://example.com'), 'http://example.com/');
  for (const bad of ['javascript:alert(1)', 'JAVASCRIPT:alert(1)', ' javascript:alert(1)', 'data:text/html,<script>1</script>', 'file:///etc/passwd', 'vbscript:x', '//evil.example', 'not a url', '', null, undefined]) {
    assert.equal(H.safeHref(bad), null, String(bad));
  }
});

t('mine is byMe, never a missing author', () => {
  assert.equal(H.postWho({ byMe: true, account: 'facebook:me' }), 'You');
  assert.equal(H.postWho({ byMe: false, author: null }), 'Someone (not named)');
  assert.equal(H.postWho({ byMe: false, author: 'other_account', account: 'instagram:other_account' }), 'other_account');
});

t('posts search passes the person scope and the order, and offers no thread scope', () => {
  const st = { q: 'birthday', offset: 0, order: 'newest', everywhere: false };
  assert.deepEqual({ ...H.postsSearchParams(st, { person: '7' }) }, { q: 'birthday', limit: 50, offset: 0, order: 'newest', person: '7' });
  assert.equal(H.postsSearchParams({ ...st, everywhere: true }, { person: '7' }).person, undefined);
  assert.equal(H.postsSearchParams(st, { thread: '9' }).person, undefined);
  assert.equal(H.postsSearchParams({ ...st, order: 'best' }, {}).order, 'best');
  assert.equal(H.postsScopeOffered({ thread: '9' }), false);
  assert.equal(H.postsScopeOffered({ person: '7' }), true);
});

t('the viewer zone is an IANA name', () => { assert.match(H.viewerZone(), /^[A-Za-z_]+(\/[A-Za-z_+-]+)*$|^UTC$|^$/); });

console.log(`${n} tests OK`);
