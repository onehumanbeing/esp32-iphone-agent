const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const context = {};
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(__dirname, '../hidagent/static/keyboard.js'), 'utf8'), context);

function keyboard(platform = 'MacIntel') {
  const element = new EventTarget(), text = [], key = [];
  let allowed = true, blocked = 0, released = 0;
  element.blur = () => {};
  context.connectPhoneKeyboard({element, platform, available: () => allowed,
    text: value => text.push(value), key: value => key.push(value),
    blocked: () => blocked++, release: () => released++});
  function emit(type, fields = {}) {
    const event = new Event(type, {cancelable: true});
    Object.assign(event, fields);
    element.dispatchEvent(event);
    return event;
  }
  return {element, text, key, emit, allow: value => allowed = value,
    get blocked() { return blocked; }, get released() { return released; }};
}

test('physical positions survive Chinese, Japanese, Korean and other host layouts', () => {
  const k = keyboard();
  for (const key of ['Process', '你', 'あ', 'ㅁ', 'ф', 'ش', 'a']) {
    assert.equal(k.emit('keydown', {key, code: 'KeyA', isComposing: true, keyCode: 229}).defaultPrevented, true);
  }
  assert.deepEqual(k.text, ['a', 'a', 'a', 'a', 'a', 'a', 'a']);
  assert.deepEqual(k.key, []);
});

test('Pinyin and Romaji sequences preserve candidate Space, Enter and arrows', () => {
  const k = keyboard();
  for (const code of ['KeyN', 'KeyI', 'KeyH', 'KeyA', 'KeyO', 'Space'])
    k.emit('keydown', {key: 'Process', code, isComposing: true});
  k.emit('keydown', {key: 'Process', code: 'ArrowDown', isComposing: true});
  k.emit('keydown', {key: 'Process', code: 'Enter', isComposing: true});
  assert.deepEqual(k.text, ['n', 'i', 'h', 'a', 'o', ' ']);
  assert.deepEqual(k.key, ['down', 'enter']);
});

test('Shift, Caps Lock, punctuation and shifted Korean key positions keep their HID encoding', () => {
  const k = keyboard();
  k.emit('keydown', {key: 'ㅆ', code: 'KeyT', shiftKey: true});
  k.emit('keydown', {key: 'ф', code: 'KeyA', getModifierState: name => name === 'CapsLock'});
  k.emit('keydown', {key: 'A', code: 'KeyA', shiftKey: true, getModifierState: name => name === 'CapsLock'});
  k.emit('keydown', {key: 'é', code: 'Digit2', shiftKey: true});
  k.emit('keydown', {key: 'Dead', code: 'Quote'});
  assert.deepEqual(k.text, ['T', 'A', 'a', '@', "'"]);
});

test('Control-Space stays language switching on Mac and Windows hosts', () => {
  for (const platform of ['MacIntel', 'Win32', 'Linux x86_64']) {
    const k = keyboard(platform);
    k.emit('keydown', {key: ' ', code: 'Space', ctrlKey: true});
    assert.deepEqual(k.key, ['ctrl+space']);
    assert.deepEqual(k.text, []);
  }
});

test('editing and dead-key chords use only existing legacy key commands', () => {
  const k = keyboard('Win32');
  for (const fields of [
    {key: 'a', code: 'KeyA', ctrlKey: true}, {key: 'y', code: 'KeyY', ctrlKey: true},
    {key: 'Dead', code: 'KeyE', altKey: true}, {key: 'ArrowLeft', code: 'ArrowLeft', shiftKey: true},
    {key: 'Delete', code: 'Delete'}, {key: 'Tab', code: 'Tab'},
  ]) k.emit('keydown', fields);
  assert.deepEqual(k.key, ['cmd+a', 'cmd+shift+z', 'alt+e', 'shift+left', 'ctrl+d', 'tab']);
});

test('host composition cannot duplicate phone IME input or inject Unicode', () => {
  const k = keyboard();
  k.emit('keydown', {key: 'Process', code: 'KeyN', isComposing: true});
  k.emit('compositionstart');
  k.emit('compositionend', {data: '你好 日本語 안녕하세요'});
  k.emit('input', {data: '你好 日本語 안녕하세요'});
  assert.deepEqual(k.text, ['n']);
  assert.equal(k.emit('paste').defaultPrevented, true);
  assert.equal(k.blocked, 1);
});

test('inactive preview, unsupported international keys and Escape send no typing', () => {
  const k = keyboard();
  k.allow(false);
  k.emit('keydown', {key: 'a', code: 'KeyA'});
  k.allow(true);
  k.emit('keydown', {key: 'ろ', code: 'IntlRo'});
  k.emit('keydown', {key: 'Escape', code: 'Escape'});
  assert.deepEqual(k.text, []);
  assert.deepEqual(k.key, []);
  assert.equal(k.blocked, 1);
  assert.equal(k.released, 1);
});

test('queued typing, language switching and candidate commit preserve order', async () => {
  const sent = [];
  let release;
  const queue = context.createKeyboardQueue(async (path, body) => {
    sent.push([path, {...body}]);
    if (sent.length === 1) await new Promise(resolve => release = resolve);
    return {ok: true};
  }, () => assert.fail('unexpected failure'));
  const jobs = [queue.push('/api/key', {text: 'ctrl+space'}), queue.push('/api/type', {text: 'n'}),
    queue.push('/api/type', {text: 'ihao'}), queue.push('/api/key', {text: 'space'})];
  release();
  await Promise.all(jobs);
  assert.deepEqual(sent.map(([, body]) => body.text), ['ctrl+space', 'nihao', 'space']);
});

test('failure drops pending input and never retries a language switch', async () => {
  let release;
  const sent = [];
  const queue = context.createKeyboardQueue(async (path, body) => {
    sent.push(body.text);
    await new Promise(resolve => release = resolve);
    return null;
  }, () => {});
  const jobs = [queue.push('/api/key', {text: 'ctrl+space'}), queue.push('/api/type', {text: 'nihao'})];
  release();
  assert.deepEqual(await Promise.all(jobs), [null, null]);
  assert.deepEqual(sent, ['ctrl+space']);
});

test('a visible phone globe tap stays ordered before subsequent typing', async () => {
  const sent = [];
  let release;
  const queue = context.createKeyboardQueue(async (path, body) => {
    sent.push([path, {...body}]);
    if (sent.length === 1) await new Promise(resolve => release = resolve);
    return {ok: true};
  }, () => assert.fail('unexpected failure'));
  const tap = queue.push('/api/tap', {x: .1, y: .9});
  const typing = queue.push('/api/type', {text: 'nihao'});
  release();
  await Promise.all([tap, typing]);
  assert.deepEqual(sent, [['/api/tap', {x: .1, y: .9}], ['/api/type', {text: 'nihao'}]]);
});

test('focus loss or Stop clears unsent input without replay', async () => {
  let release;
  const sent = [];
  const queue = context.createKeyboardQueue(async (path, body) => {
    sent.push(body.text);
    await new Promise(resolve => release = resolve);
    return {ok: true};
  }, () => {});
  const first = queue.push('/api/type', {text: 'n'});
  const pending = queue.push('/api/key', {text: 'space'});
  queue.clear();
  assert.equal(await pending, null);
  release();
  await first;
  assert.deepEqual(sent, ['n']);
});

test('bounded queue rejects overflow and drops pending input', async () => {
  let release, errors = 0;
  const queue = context.createKeyboardQueue(async () => {
    await new Promise(resolve => release = resolve);
    return {ok: true};
  }, () => errors++, 1);
  const first = queue.push('/api/key', {text: 'left'});
  const pending = queue.push('/api/key', {text: 'right'});
  assert.equal(await queue.push('/api/key', {text: 'space'}), null);
  assert.equal(await pending, null);
  assert.equal(errors, 1);
  release();
  await first;
});
