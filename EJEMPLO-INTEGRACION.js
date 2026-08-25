/* Ejemplo genérico para cualquier web. No guardes un token real en este archivo. */
const AGENT_URL = 'http://127.0.0.1:8765';
const AGENT_TOKEN = 'PEGAR_TOKEN_LOCAL_AQUI';

async function agentRequest(path, options = {}) {
  const response = await fetch(AGENT_URL + path, {
    ...options,
    headers: {
      Accept: 'application/json',
      Authorization: `Bearer ${AGENT_TOKEN}`,
      ...(options.headers || {}),
    },
  });
  const data = await response.json();
  if (!response.ok || data.ok === false) {
    throw new Error(data.error || `Error HTTP ${response.status}`);
  }
  return data;
}

export const buscarImpresoras = () => agentRequest('/printers');

export const imprimirPedido = (pedido, printerNames = []) => agentRequest('/print', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    jobId: `pedido-${pedido.id}-${Date.now()}`,
    ...(printerNames.length ? { printerNames } : {}),
    ticket: pedido,
  }),
});

export const imprimirPrueba = (printerNames = []) => agentRequest('/test', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(printerNames.length ? { printerNames } : {}),
});
