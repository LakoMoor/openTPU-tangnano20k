const $ = id => document.getElementById(id);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let link = null, demo = false, generating = false, stopped = false, connecting = false, reads = 0;
for (let i = 0; i < 48; i++) {
  const cell = document.createElement('i');
  cell.style.setProperty('--delay', `${(i * 17 % 31) / 15}s`);
  $('matrix').append(cell);
}
function log(message, type = '') {
  const row = document.createElement('div'); row.className = `log ${type}`;
  const time = document.createElement('time'); time.textContent = new Date().toLocaleTimeString('ru-RU');
  const text = document.createElement('span'); text.textContent = message;
  row.append(time, text); $('logs').append(row);
  while ($('logs').children.length > 200) $('logs').firstChild.remove();
  $('logs').scrollTop = $('logs').scrollHeight;
}
function activity(active, label) {
  $('diagram').classList.toggle('running', active);
  $('activity').textContent = `● ${label}`;
  $('activity').style.color = active ? 'var(--green)' : '';
}
function idle() {
  $('connection').textContent = demo ? '● DEMO / БЕЗ ПЛАТЫ' : '● OFFLINE';
  $('connection').style.color = '';
  activity(demo, demo ? 'ДЕМО' : 'ОЖИДАНИЕ');
  $('flowLabel').textContent = demo ? 'Иллюстрация движения данных; аппаратные метрики не имитируются' : 'Подключите плату или запустите демонстрацию';
}
function setDemo(value) {
  demo = value; $('demo').textContent = demo ? '■ Завершить демо' : '▷ Запустить демо';
  if (!link) idle();
}
$('demo').onclick = () => {
  if (link || connecting || generating) return;
  setDemo(!demo); log(demo ? 'Демо включено. Плата не подключена.' : 'Демо остановлено.');
};
$('clear').onclick = () => $('logs').replaceChildren();

// All commands are serialized by the single monitoring task. No register writes or
// control commands: this dashboard never starts, resets or modifies the accelerator.
class SerialLink {
  constructor(port) { this.port = port; this.closed = false; this.pending = []; }
  async open() {
    await this.port.open({baudRate: 2000000, dataBits: 8, stopBits: 1, parity: 'none', flowControl: 'none', bufferSize: 4096});
    this.reader = this.port.readable.getReader(); this.writer = this.port.writable.getWriter();
    // Drain stale input during the same NOP resync used by Python's TangLink.
    this.draining = true;
    this.pump = this.receive();
    await this.writer.write(new Uint8Array(16)); await sleep(50);
    this.pending = []; this.draining = false;
  }
  async receive() {
    try {
      while (!this.closed) {
        const {value, done} = await this.reader.read();
        if (done) break;
        if (!this.draining) this.pending.push(...value);
        this.wake?.();
      }
    } catch (e) { this.error = e; }
    finally { this.ended = true; this.wake?.(); }
  }
  async reg(address) {
    if (this.closed) throw new Error('Порт закрыт');
    await this.writer.write(new Uint8Array([0x72, address & 255, address >> 8]));
    const deadline = performance.now() + 3000;
    while (this.pending.length < 4) {
      if (this.error || this.ended || this.closed) throw this.error || new Error('UART отключён');
      const remaining = deadline - performance.now();
      if (remaining <= 0) throw new Error('Тайм-аут UART: плата не ответила за 3 секунды');
      await new Promise(resolve => {
        const timer = setTimeout(resolve, remaining);
        this.wake = () => { clearTimeout(timer); resolve(); };
      });
      this.wake = null;
    }
    reads++; $('packets').textContent = `${reads} чтений`;
    return new DataView(Uint8Array.from(this.pending.splice(0, 4)).buffer).getUint32(0, true);
  }
  async close() {
    this.closed = true; this.wake?.();
    try { await this.reader?.cancel(); await this.pump; } catch { /* unplugged */ }
    try { this.reader?.releaseLock(); this.writer?.releaseLock(); } catch { /* failed open */ }
    try { await this.port.close(); } catch { /* unplugged or not opened */ }
  }
}
function disconnected() {
  $('connect').textContent = 'Подключить FPGA ↗'; $('demo').disabled = generating;
  $('portLabel').textContent = 'USB UART · 2 000 000 baud · 8N1';
  $('clock').textContent = '— MHz'; $('cycles').textContent = '—';
  $('instructions').textContent = '—'; $('memory').textContent = '—';
  $('sd').textContent = 'Ожидание подключения'; idle();
}
async function monitor(current) {
  let lastError = null;
  try {
    while (link === current && !current.closed) {
      const status = await current.reg(0x00c);
      let hi = await current.reg(0x01c), lo = await current.reg(0x018);
      const hi2 = await current.reg(0x01c);
      if (hi !== hi2) { hi = hi2; lo = await current.reg(0x018); }
      const instructions = await current.reg(0x020), sd = await current.reg(0x218);
      if (link !== current) break;
      $('cycles').textContent = ((BigInt(hi) << 32n) + BigInt(lo)).toLocaleString('ru-RU');
      $('instructions').textContent = instructions.toLocaleString('ru-RU');
      $('memory').textContent = sd & 1 ? 'READY' : 'INIT';
      $('sd').textContent = sd & 4 ? 'Ошибка SD-карты' : sd & 2 ? 'SD-карта готова' : 'SD-карта не готова';
      const running = !!(status & 0x80), error = !!(status & 2);
      activity(running && !error, error ? 'ОШИБКА FPGA' : running ? 'ВЫЧИСЛЕНИЕ' : status & 1 ? 'HALTED' : 'ГОТОВА');
      $('flowLabel').textContent = `STATUS 0x${status.toString(16).padStart(4, '0')} · ${running ? 'ядро выполняет программу' : 'ожидание программы'}`;
      if (error) {
        const code = await current.reg(0x21c);
        if (code !== lastError) log(`FPGA сообщает ошибку, ECODE=${code}`, 'error');
        lastError = code;
      } else lastError = null;
      await sleep(1000);
    }
  } catch (e) {
    if (link === current) {
      log(e.message, 'error'); link = null;
      await current.close(); disconnected();
      $('notice').textContent = `Соединение потеряно: ${e.message}. Переподключите плату.`;
    }
  }
}
$('connect').onclick = async () => {
  if (connecting) return;
  connecting = true; $('connect').disabled = true; $('demo').disabled = true;
  let current;
  try {
    if (link) {
      current = link; link = null; await current.close(); disconnected();
      log('Порт освобождён.');
      $('notice').textContent = 'Порт отключён. Теперь его можно использовать в Python CLI.';
      return;
    }
    if (!navigator.serial) throw new Error('Нужен настольный Chrome или Edge с Web Serial и HTTPS');
    const selected = await navigator.serial.requestPort();
    current = new SerialLink(selected); await current.open();
    log('UART открыт · 2 Mbaud. Проверка openTPU…');
    const id = await current.reg(0x000);
    if (id !== 0x4f545055) throw new Error(`Неизвестная плата: ID 0x${id.toString(16)} (ожидался OTPU)`);
    const clock = await current.reg(0x044);
    setDemo(false); link = current;
    $('clock').textContent = `${(clock / 1000).toFixed(1)} MHz`;
    const info = selected.getInfo();
    $('portLabel').textContent = `USB VID ${info.usbVendorId?.toString(16) || '—'} · PID ${info.usbProductId?.toString(16) || '—'} · 2 Mbaud`;
    $('connection').textContent = '● CONNECTED'; $('connection').style.color = 'var(--green)';
    $('connect').textContent = 'Отключить';
    $('notice').textContent = 'Мониторинг регистров раз в секунду. Браузер не показывает имя COM-порта: выберите устройство в системном диалоге. Для Python CLI сначала отключите порт.';
    log('openTPU обнаружена. Мониторинг активен.', 'success');
    void monitor(current);
  } catch (e) {
    if (e.name === 'NotFoundError') log('Выбор порта отменён.');
    else { log(e.message, 'error'); $('notice').textContent = `Не удалось подключиться: ${e.message}. Закройте другие программы, использующие порт.`; }
    await current?.close(); disconnected();
  } finally {
    connecting = false; $('connect').disabled = false; $('demo').disabled = !!link || generating;
  }
};
$('generate').onclick = async () => {
  if (generating) return;
  if (!$('prompt').value.trim()) { $('prompt').focus(); return; }
  generating = true; stopped = false;
  $('generate').disabled = true; $('stop').disabled = false; $('demo').disabled = true;
  $('answer').replaceChildren(); $('tokenCount').textContent = '0 фрагментов';
  if (!link) setDemo(true);
  log('Показ заранее подготовленного примера. Это не ответ модели на промпт.');
  const text = '…что большой интеллект может жить на маленькой плате. Веса поступают с SD-карты, память хранит активации, а FPGA выполняет вычисления. Шаг за шагом числа превращаются в следующий токен — и история продолжается.';
  let count = 0;
  for (const word of text.split(' ')) {
    if (stopped) break;
    const token = document.createElement('span'); token.className = 'token'; token.textContent = word + ' ';
    $('answer').append(token); $('tokenCount').textContent = `${++count} фрагментов`;
    await sleep(150 + (count % 3) * 65);
  }
  log(stopped ? 'Демонстрация остановлена.' : 'Демонстрация завершена.', 'success');
  generating = false; $('generate').disabled = false; $('stop').disabled = true; $('demo').disabled = !!link || connecting;
  if (!link) setDemo(false);
};
$('stop').onclick = () => { stopped = true; };
log('Control room готов. Подключите Tang Nano 20K или включите демо.', 'success');
if (!navigator.serial) $('notice').textContent = 'Для COM-порта нужен настольный Chrome / Edge с Web Serial. Демонстрация доступна в любом современном браузере.';
