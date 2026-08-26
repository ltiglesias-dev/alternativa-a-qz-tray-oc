'use strict';

const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const VERSION = '0.1.0';
const PORT_DEFAULT = 8765;
const COLUMNS_58 = 32;
const ESC = '\x1B';
const GS = '\x1D';
const ROOT = __dirname;
const DEFAULT_CONFIG_PATH = path.join(
  process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'),
  'AgendartePrinterAgent',
  'config.json'
);

function readArg(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : '';
}

const configPath = path.resolve(readArg('--config') || DEFAULT_CONFIG_PATH);
const configDir = path.dirname(configPath);

const defaults = {
  port: PORT_DEFAULT,
  allowedOrigins: ['http://localhost', 'http://127.0.0.1', 'https://agendarte.uy'],
  token: '',
  paperWidth: '58mm',
  printers: [],
};

function loadConfig() {
  try {
    const raw = fs.readFileSync(configPath, 'utf8').replace(/^\uFEFF/, '');
    const parsed = JSON.parse(raw);
    return {
      ...defaults,
      ...parsed,
      port: Number(parsed.port) || PORT_DEFAULT,
      allowedOrigins: Array.isArray(parsed.allowedOrigins) ? parsed.allowedOrigins : defaults.allowedOrigins,
      printers: Array.isArray(parsed.printers) ? parsed.printers : [],
    };
  } catch (_) {
    return { ...defaults };
  }
}

const config = loadConfig();

function normalizeOrigin(value) {
  try {
    return new URL(String(value).trim()).origin;
  } catch (_) {
    return '';
  }
}

const allowedOrigins = new Set(
  config.allowedOrigins.map(normalizeOrigin).filter(Boolean)
);

function configuredPrinterNames() {
  return config.printers
    .map((printer) => typeof printer === 'string' ? printer : printer && printer.name)
    .map((name) => String(name || '').trim())
    .filter(Boolean);
}

function normalizePrinterName(value) {
  return String(value || '').trim();
}

function writeJson(res, statusCode, data, origin = '') {
  const body = JSON.stringify(data);
  res.statusCode = statusCode;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  if (origin) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
  }
  res.end(body);
}

function authorizeRequest(req, res) {
  const originHeader = String(req.headers.origin || '').trim();
  const origin = originHeader ? normalizeOrigin(originHeader) : '';

  if (originHeader && (!origin || !allowedOrigins.has(origin))) {
    writeJson(res, 403, { ok: false, error: 'Origen no autorizado por el agente local.' });
    return null;
  }

  // El navegador envía OPTIONS como preflight CORS antes de mandar
  // Authorization. Esa verificación debe validar el origen, pero no exigir
  // todavía el token.
  if (config.token && req.method !== 'OPTIONS') {
    const authorization = String(req.headers.authorization || '');
    if (authorization !== 'Bearer ' + config.token) {
      writeJson(res, 401, { ok: false, error: 'Token del agente inválido o ausente.' }, origin);
      return null;
    }
  }

  if (origin) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Vary', 'Origin');
  }
  return origin;
}

function readBody(req, maxBytes = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let total = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject(new Error('El cuerpo de la solicitud es demasiado grande.'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function runPowerShell(scriptArgs, timeoutMs = 15000) {
  const powershell = process.env.SystemRoot
    ? path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    : 'powershell.exe';

  return new Promise((resolve, reject) => {
    const child = spawn(powershell, [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      ...scriptArgs,
    ], { windowsHide: true });

    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('La operación de Windows agotó el tiempo de espera.'));
    }, timeoutMs);

    child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    child.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(stdout.trim());
      else reject(new Error(stderr.trim() || stdout.trim() || ('PowerShell terminó con código ' + code)));
    });
  });
}

async function listPrinters() {
  const command = "$ErrorActionPreference='Stop'; if (Get-Command Get-Printer -ErrorAction SilentlyContinue) { Get-Printer | Select-Object Name,PrinterStatus,WorkOffline,PortName | ConvertTo-Json -Compress } else { Get-CimInstance Win32_Printer | Select-Object Name,PrinterStatus,WorkOffline,PortName | ConvertTo-Json -Compress }";
  const output = await runPowerShell(['-Command', command]);
  if (!output) return [];
  const parsed = JSON.parse(output);
  return (Array.isArray(parsed) ? parsed : [parsed]).map((printer) => ({
    name: String(printer.Name || ''),
    status: printer.PrinterStatus,
    workOffline: Boolean(printer.WorkOffline),
    port: String(printer.PortName || ''),
  })).filter((printer) => printer.name);
}

function normalizeText(value) {
  return String(value == null ? '' : value)
    .replace(/¡/g, '!')
    .replace(/¿/g, '?')
    .replace(/[“”]/g, '"')
    .replace(/[‘’]/g, "'")
    .replace(/—/g, '-')
    .replace(/…/g, '...')
    .replace(/€/g, 'EUR')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/\r?\n/g, ' ')
    // Las impresoras ESC/POS sencillas no interpretan UTF-8/emoji de forma
    // uniforme y pueden imprimir letras sueltas en lugar del símbolo.
    .replace(/[^\x20-\x7E]/g, ' ');
}

function escapeRegExp(value) {
  return String(value || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function cleanDeliveryText(value, data = {}) {
  let text = normalizeText(value).trim();
  if (!text) return '';

  text = text
    .replace(/pedido\s+(?:whatsapp|mercado\s+pago)\s*(?:\([^)]*\))?/gi, ' ')
    .replace(/\btienda\s+s\b/gi, ' ');

  [data.client, data.phone || data.telefono].forEach((duplicate) => {
    const normalizedDuplicate = normalizeText(duplicate).trim();
    if (normalizedDuplicate) {
      text = text.replace(new RegExp(escapeRegExp(normalizedDuplicate), 'gi'), ' ');
    }
  });

  text = text
    .replace(/\s*[|;,]+\s*/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .replace(/^[\s:.-]+|[\s:.-]+$/g, '')
    .trim();

  if (/\bretiro\s+en\s+(?:el\s+)?(?:comercio|local)\b/i.test(text)
    || /\bpasa\s+a\s+retirar\b/i.test(text)) {
    return 'Retiro en el comercio';
  }

  const envioMatch = text.match(/envio\s+a\s+domicilio\s*:?\s*(.*)$/i);
  if (envioMatch) {
    const address = String(envioMatch[1] || '').trim();
    return address ? 'Envio a domicilio: ' + address : 'Envio a domicilio';
  }

  return text;
}

function wrapText(value, width = COLUMNS_58) {
  const text = normalizeText(value).trim();
  if (!text) return [''];
  const lines = [];
  let current = '';
  for (let word of text.split(/\s+/)) {
    if (word.length > width) {
      if (current) lines.push(current);
      current = '';
      while (word.length > width) {
        lines.push(word.slice(0, width));
        word = word.slice(width);
      }
      current = word;
      continue;
    }
    const candidate = current ? current + ' ' + word : word;
    if (candidate.length > width) {
      lines.push(current);
      current = word;
    } else {
      current = candidate;
    }
  }
  if (current) lines.push(current);
  return lines.length ? lines : [''];
}

function addLine(parts, value = '') {
  wrapText(value).forEach((line) => parts.push(line + '\n'));
}

function addCentered(parts, value) {
  parts.push(ESC + 'a' + '\x01');
  addLine(parts, value);
  parts.push(ESC + 'a' + '\x00');
}

function addColumns(parts, left, right) {
  const leftText = normalizeText(left);
  const rightText = normalizeText(right);
  const width = COLUMNS_58 - rightText.length - 1;
  if (width < 8 || leftText.length > width) {
    addLine(parts, leftText);
    addLine(parts, rightText);
    return;
  }
  parts.push(leftText.padEnd(COLUMNS_58 - rightText.length, ' ') + rightText + '\n');
}

function money(value) {
  const amount = Number(value || 0);
  return '$ ' + amount.toLocaleString('es-UY', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function businessInfo(data) {
  const info = data.businessInfo || {};
  const name = info.name || data.business || 'Comercio';
  const phone = info.phone || '';
  const address = info.address || '';
  return { name, phone, address };
}

function addHeader(parts, data, label) {
  const info = businessInfo(data);
  const business = normalizeText(info.name);
  const doubleSize = business.length <= 16;
  parts.push(ESC + 'a' + '\x01', ESC + 'E' + '\x01');
  if (doubleSize) parts.push(GS + '!' + '\x11');
  addCentered(parts, info.name);
  if (doubleSize) parts.push(GS + '!' + '\x00');
  parts.push(ESC + 'E' + '\x00');
  if (info.phone) addCentered(parts, 'Tel: ' + info.phone);
  if (info.address) addCentered(parts, info.address);
  parts.push(ESC + 'E' + '\x01');
  addCentered(parts, label);
  parts.push(ESC + 'E' + '\x00', ESC + 'a' + '\x00');
}

function finishTicket(parts) {
  parts.push(ESC + 'a' + '\x01');
  addCentered(parts, 'Agendarte.uy');
  parts.push(ESC + 'a' + '\x00', ESC + 'd' + '\x03', '\n');
  return parts.join('');
}

function buildOrderTicket(data = {}) {
  const parts = [ESC + '@'];
  addHeader(parts, data, 'PEDIDO #' + (data.id || 'N/A'));
  addLine(parts, '-'.repeat(COLUMNS_58));
  [
    ['Cliente', data.client],
    ['Telefono', data.phone || data.telefono],
    ['Cedula', data.cedula],
    ['Forma de pago', data.payment || data.metodo_pago],
    ['Fecha', data.date || data.fecha],
    ['Entrega', cleanDeliveryText(data.address || data.direccion, data)],
  ].filter(([, value]) => value && String(value).trim())
    .forEach(([label, value]) => addLine(parts, label + ': ' + value));
  addLine(parts, '-'.repeat(COLUMNS_58));
  parts.push(ESC + 'E' + '\x01');
  addLine(parts, 'DETALLE DE PRODUCTOS');
  parts.push(ESC + 'E' + '\x00');
  (data.rows || data.items || []).forEach((row) => {
    const name = row.name || row.product || 'Producto';
    const variant = row.variant_label ? ' (' + row.variant_label + ')' : '';
    const quantity = Number(row.quantity || 1);
    const price = Number(row.price || row.unitPrice || 0);
    addLine(parts, name + variant);
    addColumns(parts, quantity + ' x ' + money(price), money(quantity * price));
  });
  addLine(parts, '-'.repeat(COLUMNS_58));
  parts.push(ESC + 'E' + '\x01');
  addColumns(parts, 'TOTAL:', money(data.total));
  parts.push(ESC + 'E' + '\x00');
  addCentered(parts, 'Muchas gracias por su compra!');
  return finishTicket(parts);
}

function buildAppointmentTicket(data = {}) {
  const parts = [ESC + '@'];
  addHeader(parts, data, 'RESERVA #' + (data.id || data.id_reserva || 'N/A'));
  addLine(parts, '-'.repeat(COLUMNS_58));
  [
    ['Cliente', data.cliente || data.client],
    ['Telefono', data.telefono],
    ['Servicio', data.servicio || data.service],
    ['Profesional', data.barbero || data.profesional],
    ['Fecha', data.fecha || data.date],
    ['Hora', data.hora || data.time],
    ['Precio', money(data.precio || data.price)],
    ['Estado', data.estado],
  ].filter(([, value]) => value && String(value).trim())
    .forEach(([label, value]) => addLine(parts, label + ': ' + value));
  addLine(parts, '-'.repeat(COLUMNS_58));
  addCentered(parts, 'Gracias por agendar con nosotros!');
  return finishTicket(parts);
}

function buildTicket(body) {
  if (body.type === 'appointment' || body.ticketType === 'appointment') {
    return buildAppointmentTicket(body.ticket || body);
  }
  return buildOrderTicket(body.ticket || body);
}

function rawBase64(data) {
  return Buffer.from(data, 'utf8').toString('base64');
}

async function printRaw(printerName, base64Data) {
  const scriptPath = path.join(ROOT, 'print-raw.ps1');
  return runPowerShell([
    '-File',
    scriptPath,
    '-PrinterName',
    printerName,
    '-Base64Data',
    base64Data,
  ], 30000);
}

const recentJobs = new Map();
function rememberJob(jobId, result) {
  if (!jobId) return;
  recentJobs.set(jobId, result);
  while (recentJobs.size > 100) recentJobs.delete(recentJobs.keys().next().value);
}

async function processPrint(body) {
  const jobId = String(body.jobId || '').trim();
  if (jobId && recentJobs.has(jobId)) return recentJobs.get(jobId);

  const configured = configuredPrinterNames();
  const requested = body.printerNames || body.printers || body.printerName;
  const printerNames = (Array.isArray(requested) ? requested : [requested])
    .map(normalizePrinterName)
    .filter(Boolean);
  const targets = printerNames.length ? printerNames : configured;
  if (!targets.length) throw new Error('No hay impresoras configuradas en el agente.');

  for (const name of targets) {
    if (configured.length && !configured.includes(name)) {
      throw new Error('La impresora no está configurada: ' + name);
    }
  }

  const data = body.rawBase64
    ? String(body.rawBase64)
    : rawBase64(buildTicket(body));
  const results = [];
  for (const printer of targets) {
    try {
      await printRaw(printer, data);
      results.push({ printer, ok: true });
    } catch (error) {
      results.push({ printer, ok: false, error: error.message });
    }
  }
  const result = { ok: results.every((item) => item.ok), jobId: jobId || null, results };
  rememberJob(jobId, result);
  return result;
}

const server = http.createServer(async (req, res) => {
  const origin = authorizeRequest(req, res);
  if (origin === null) return;

  if (req.method === 'OPTIONS') {
    res.statusCode = 204;
    res.end();
    return;
  }

  const url = new URL(req.url, 'http://127.0.0.1');
  try {
    if (req.method === 'GET' && url.pathname === '/health') {
      writeJson(res, 200, { ok: true, service: 'agendarte-printer-agent', version: VERSION, port: config.port }, origin);
      return;
    }

    if (req.method === 'GET' && url.pathname === '/printers') {
      const printers = await listPrinters();
      writeJson(res, 200, { ok: true, printers, configured: configuredPrinterNames() }, origin);
      return;
    }

    if (req.method === 'POST' && (url.pathname === '/print' || url.pathname === '/test')) {
      const bodyText = await readBody(req);
      const body = bodyText ? JSON.parse(bodyText) : {};
      if (url.pathname === '/test') {
        body.type = 'order';
        body.ticket = {
          id: 'PRUEBA',
          business: 'Agendarte UY',
          rows: [{ name: 'Ticket de prueba', quantity: 1, price: 0 }],
          total: 0,
          client: 'Conexión local',
          date: new Date().toLocaleString('es-UY'),
        };
      }
      const result = await processPrint(body);
      writeJson(res, result.ok ? 200 : 207, result, origin);
      return;
    }

    writeJson(res, 404, { ok: false, error: 'Ruta no encontrada.' }, origin);
  } catch (error) {
    writeJson(res, 400, { ok: false, error: error.message || 'Error del agente.' }, origin);
  }
});

server.on('error', (error) => {
  console.error('[Agendarte Printer Agent]', error.message);
  process.exitCode = 1;
});

server.listen(config.port, '127.0.0.1', () => {
  console.log('Agendarte Printer Agent activo en http://127.0.0.1:' + config.port);
  console.log('Configuración: ' + configPath);
  console.log('Impresoras configuradas: ' + (configuredPrinterNames().join(', ') || '(ninguna)'));
});
