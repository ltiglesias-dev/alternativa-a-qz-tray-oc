/*
 * Cliente universal para Agendarte Printer Agent.
 *
 * Uso desde cualquier web:
 * <script src="https://raw.githubusercontent.com/viernes69/alternativa-a-qz-tray-oc/main/agendarte-printer-client.js"></script>
 *
 * El token se guarda solamente en localStorage del equipo que imprime.
 */
(function (global) {
  'use strict';

  const VERSION = '1.0.0';
  const DEFAULT_URL = 'http://127.0.0.1:8765';
  const DEFAULT_STORAGE_KEY = 'agendarte-printer-agent';

  const cleanUrl = (value) => String(value || DEFAULT_URL).trim().replace(/\/+$/, '') || DEFAULT_URL;
  const cleanNames = (value) => {
    if (!Array.isArray(value)) return [];
    return value.map((name) => String(name || '').trim()).filter(Boolean);
  };

  const storage = () => {
    try {
      return global.localStorage;
    } catch (_) {
      return null;
    }
  };

  const readStorage = (key) => {
    const store = storage();
    if (!store) return {};
    try {
      const value = store.getItem(key);
      const parsed = value ? JSON.parse(value) : {};
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch (_) {
      return {};
    }
  };

  const writeStorage = (key, value) => {
    const store = storage();
    if (!store) return false;
    try {
      store.setItem(key, JSON.stringify(value));
      return true;
    } catch (_) {
      return false;
    }
  };

  const removeStorage = (key) => {
    const store = storage();
    if (!store) return;
    try { store.removeItem(key); } catch (_) {}
  };

  const create = (options) => {
    const initial = options && typeof options === 'object' ? options : {};
    const storageKey = String(initial.storageKey || (
      DEFAULT_STORAGE_KEY + ':' + String(initial.profile || 'default')
    ));
    const saved = readStorage(storageKey);
    let config = {
      agentUrl: DEFAULT_URL,
      token: '',
      printerNames: [],
      profile: String(initial.profile || saved.profile || 'default'),
      timeoutMs: 12000,
      ...saved,
      ...initial,
    };

    const normalizedConfig = () => ({
      agentUrl: cleanUrl(config.agentUrl),
      token: String(config.token || '').trim(),
      printerNames: cleanNames(config.printerNames),
      profile: String(config.profile || 'default').trim() || 'default',
      timeoutMs: Math.max(1000, Number(config.timeoutMs) || 12000),
    });

    const getConfig = () => ({ ...normalizedConfig() });
    const saveConfig = () => {
      config = normalizedConfig();
      writeStorage(storageKey, config);
      return getConfig();
    };
    const setConfig = (patch) => {
      if (!patch || typeof patch !== 'object') return saveConfig();
      config = { ...config, ...patch };
      return saveConfig();
    };
    const clearConfig = () => {
      removeStorage(storageKey);
      config = { agentUrl: DEFAULT_URL, token: '', printerNames: [], profile: normalizedConfig().profile, timeoutMs: 12000 };
      return getConfig();
    };

    const request = async (path, optionsRequest) => {
      const current = normalizedConfig();
      const requestOptions = optionsRequest && typeof optionsRequest === 'object' ? optionsRequest : {};
      const headers = {
        Accept: 'application/json',
        ...(requestOptions.headers || {}),
      };
      if (current.token) headers.Authorization = 'Bearer ' + current.token;

      const controller = typeof AbortController === 'function' ? new AbortController() : null;
      const timer = controller ? setTimeout(() => controller.abort(), current.timeoutMs) : null;
      let response;
      try {
        response = await fetch(current.agentUrl + path, {
          ...requestOptions,
          headers,
          credentials: 'omit',
          signal: controller ? controller.signal : requestOptions.signal,
        });
      } catch (error) {
        const detail = error && error.name === 'AbortError' ? 'Tiempo agotado.' : (error && error.message ? error.message : error);
        throw new Error('No se pudo conectar con el agente local. Verificá que esté iniciado y que esta web esté autorizada. (' + detail + ')');
      } finally {
        if (timer) clearTimeout(timer);
      }

      let data = {};
      try { data = await response.json(); } catch (_) {}
      if (!response.ok || data.ok === false) {
        throw new Error(data.error || ('El agente local respondió con HTTP ' + response.status + '.'));
      }
      return data;
    };

    const connect = () => request('/health');
    const getPrinters = () => request('/printers');
    const test = (printerNames) => {
      const names = cleanNames(printerNames === undefined ? normalizedConfig().printerNames : printerNames);
      return request('/test', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(names.length ? { printerNames: names } : {}),
      });
    };

    const print = (ticket, printOptions) => {
      const current = normalizedConfig();
      const opts = printOptions && typeof printOptions === 'object' ? printOptions : {};
      const names = cleanNames(opts.printerNames === undefined ? current.printerNames : opts.printerNames);
      const body = {
        jobId: String(opts.jobId || ('ticket-' + Date.now())),
        ticket: ticket && typeof ticket === 'object' ? ticket : {},
      };
      if (names.length) body.printerNames = names;
      return request('/print', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
    };

    const printRaw = (rawBase64, printOptions) => {
      const current = normalizedConfig();
      const opts = printOptions && typeof printOptions === 'object' ? printOptions : {};
      const names = cleanNames(opts.printerNames === undefined ? current.printerNames : opts.printerNames);
      const body = {
        jobId: String(opts.jobId || ('raw-' + Date.now())),
        rawBase64: String(rawBase64 || ''),
      };
      if (names.length) body.printerNames = names;
      return request('/print', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
    };

    // Si la web inicializa el cliente con token o impresoras, también queda
    // persistido para que la siguiente visita no vuelva a pedirlos.
    if (Object.keys(initial).some((key) => ['agentUrl', 'token', 'printerNames', 'profile', 'timeoutMs'].includes(key))) {
      saveConfig();
    }

    return {
      version: VERSION,
      storageKey,
      getConfig,
      setConfig,
      saveConfig,
      clearConfig,
      request,
      connect,
      getPrinters,
      discover: getPrinters,
      print,
      printOrder: print,
      printAppointment: (ticket, opts) => print({ ...ticket, type: 'appointment' }, opts),
      printRaw,
      test,
    };
  };

  global.AgendartePrinter = {
    version: VERSION,
    create,
    getStoredConfig: (profile) => readStorage(DEFAULT_STORAGE_KEY + ':' + String(profile || 'default')),
    clearStoredConfig: (profile) => removeStorage(DEFAULT_STORAGE_KEY + ':' + String(profile || 'default')),
  };
})(typeof window !== 'undefined' ? window : globalThis);
