// Run with: node --test tests/webui_serial.test.cjs
const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
function setup() {
  const elements = new Map();
  const element = () => ({style: {setProperty() {}}, classList: {toggle() {}}, children: [],
    append(...nodes) { this.children.push(...nodes); }, replaceChildren() { this.children = []; }});
  const context = vm.createContext({Uint8Array, DataView, BigInt, performance, setTimeout, clearTimeout,
    navigator: {}, document: {createElement: element, getElementById(id) {
      if (!elements.has(id)) elements.set(id, element()); return elements.get(id);
    }}});
  vm.runInContext(fs.readFileSync('site/control/app.js', 'utf8') + '\nglobalThis.Link = SerialLink;', context);
  return context;
}
function device(reply, failOpen = false) {
  let wake, queue = [], done = false;
  const commands = [];
  const port = {commands, released: 0, closes: 0,
    async open() { if (failOpen) throw new Error('Port busy'); },
    async close() { this.closes++; },
    readable: {getReader() { return {
      async read() { while (!queue.length && !done) await new Promise(r => wake = r);
        return queue.length ? {value: queue.shift(), done: false} : {done: true}; },
      async cancel() { done = true; wake?.(); }, releaseLock() { port.released++; }
    }; }},
    writable: {getWriter() { return {
      async write(bytes) {
        commands.push([...bytes]);
        if (bytes[0] === 0x72) { queue.push(...reply.map(x => Uint8Array.from(x))); wake?.(); }
      }, releaseLock() { port.released++; }
    }; }} };
  return port;
}
test('binary register request and fragmented little-endian response; release locks', async () => {
  const {Link} = setup(); const port = device([[0x55], [0x50, 0x54], [0x4f]]);
  const link = new Link(port); await link.open();
  assert.equal(await link.reg(0x218), 0x4f545055);
  assert.deepEqual(port.commands[0], Array(16).fill(0));
  assert.deepEqual(port.commands[1], [0x72, 0x18, 2]);
  await link.close(); assert.equal(port.released, 2); assert.equal(port.closes, 1);
});
test('failed opening can be cleaned up', async () => {
  const {Link} = setup(); const port = device([], true); const link = new Link(port);
  await assert.rejects(link.open(), /Port busy/); await link.close();
  assert.equal(port.closes, 1);
});
test('disconnect wakes a register read without waiting for timeout', async () => {
  const {Link} = setup(); const link = new Link(device([])); await link.open();
  const pending = assert.rejects(link.reg(0), /UART отключён|Порт закрыт/);
  await new Promise(r => setTimeout(r, 10)); await link.close(); await pending;
});
