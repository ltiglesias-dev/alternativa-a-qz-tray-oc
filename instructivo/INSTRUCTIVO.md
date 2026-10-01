# Instructivo: agente local de impresión ESC/POS

Este proyecto reemplaza QZ Tray para imprimir tickets ESC/POS directamente desde una web en Windows, sin abrir el diálogo de impresión del navegador.

Para ver cómo se vería la pantalla de configuración y cómo se arma la solicitud, abrí [demo-configuracion.html](../demo/demo-configuracion.html). Es una demostración visual: no conecta ni imprime.

La arquitectura es:

```text
Web en el navegador
        |
        | HTTP local + token
        v
Agente Node en 127.0.0.1:8765
        |
        | RAW ESC/POS
        v
Spooler de Windows -> impresora térmica USB, COM o Bluetooth
```

## 1. Requisitos

- Windows 10 u 11.
- Node.js instalado y disponible como `node` en PowerShell.
- La impresora instalada en Windows y visible en **Configuración > Bluetooth y dispositivos > Impresoras y escáneres**.
- Impresora compatible con ESC/POS RAW.
- Nombre exacto de la web, por ejemplo `https://miweb.com` o `http://localhost:3000`.

El agente está preparado para tickets de 58 mm con 32 columnas seguras. Para otro ancho hay que ajustar `COLUMNS_58` y el formato ESC/POS según la impresora.

## 2. Instalar el agente

1. Descargá o cloná este repositorio.
2. Ejecutá `integracion\instalar-agente.bat`.
3. Se abrirá el configurador gráfico. Ingresá el origen de la web. No ingreses una ruta completa: se usa solamente el origen, por ejemplo `https://miweb.com`.
4. Confirmá el puerto local abierto en ese PC (por defecto `8765`, visible en la misma ventana).
5. Marcá las impresoras que querés usar en la lista detectada por Windows.
6. Presioná **Guardar y activar agente**.

Si hay más de un origen, separalos por coma:

   ```text
   https://miweb.com,http://localhost:3000,http://127.0.0.1:5173
   ```

El instalador:

- Copia el agente a `%LOCALAPPDATA%\AgendartePrinterAgent`.
- Genera un token aleatorio.
- Guarda la configuración en `config.json`, incluyendo el puerto local.
- Registra el agente para iniciarlo al iniciar sesión en Windows.
- Inicia el proceso local.
- Crea `token.txt` con el token vigente, el puerto, la URL local y la fecha/hora.
- Registra en Microsoft Edge el origen autorizado para permitir el acceso al agente local sin repetir el aviso de permisos.

El agente queda registrado como una tarea oculta de Windows. No es necesario dejar abierto un CMD; `iniciar-agente.bat` o `iniciar-agente.vbs` solamente vuelven a iniciar esa tarea si hace falta. El `.vbs` es la opción totalmente silenciosa si se lo ejecuta desde el Explorador.

Si Edge estaba abierto durante la instalación, cerralo y abrilo nuevamente. El instalador puede solicitar una autorización de administrador de Windows para registrar la política. La política se aplica solamente a los orígenes ingresados en el configurador y al acceso de loopback (`127.0.0.1`, `localhost` o `::1`).

Para consultar el token, ejecutá `iniciar-agente\ver-token.bat`. No publiques ni compartas ese archivo.

## 3. Reconfigurar o cambiar el token

Volvé a ejecutar `integracion\instalar-agente.bat` y completá el asistente nuevamente.

El configurador detiene la instancia anterior, genera un token nuevo, reemplaza `config.json`, actualiza `token.txt` y vuelve a iniciar el agente. El token anterior deja de funcionar.

## 4. Conectar cualquier web

La web debe guardar localmente el token del equipo y enviarlo en cada solicitud:

```js
const AGENT_URL = 'http://127.0.0.1:8765';
const AGENT_TOKEN = 'TOKEN_GENERADO_EN_ESE_EQUIPO';

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
```

El origen exacto de la web debe haber sido cargado durante la instalación. El navegador realiza una solicitud CORS `OPTIONS` antes de enviar solicitudes con `Authorization`; el agente ya contempla ese preflight.

### Integración simplificada con un único JavaScript

Para no repetir el código de `fetch()` en cada proyecto, incluí este archivo público:

```html
<script src="https://cdn.jsdelivr.net/gh/viernes69/alternativa-a-qz-tray-oc@main/agendarte-printer-client.js"></script>
```

Después creá un cliente por perfil de uso. El perfil permite guardar configuraciones distintas en el mismo equipo, por ejemplo `caja`, `cocina` o `mostrador`:

```js
const impresora = AgendartePrinter.create({ profile: 'caja' });

// Se ejecuta una sola vez desde el panel de configuración de la web.
impresora.setConfig({
  token: document.querySelector('#token-local').value,
  printerNames: ['POS-58', 'Impresora portatil'],
});

const estado = await impresora.connect();
const instaladas = await impresora.discover();

await impresora.print({
  id: pedido.id,
  business: 'Mi comercio',
  client: pedido.cliente,
  phone: pedido.telefono,
  payment: pedido.formaPago,
  date: pedido.fecha,
  address: pedido.direccion,
  rows: pedido.productos.map((producto) => ({
    name: producto.nombre,
    quantity: producto.cantidad,
    price: producto.precio,
  })),
  total: pedido.total,
});
```

Métodos disponibles:

- `connect()` verifica que el agente esté activo.
- `discover()` devuelve las impresoras instaladas y las configuradas.
- `print(ticket, opciones)` imprime en las impresoras guardadas o en las indicadas en `opciones.printerNames`.
- `test()` envía un ticket de prueba.
- `setConfig()` guarda token, URL, perfil e impresoras en `localStorage` de ese equipo.
- `clearConfig()` elimina la configuración del perfil actual.

La página funcional [EJEMPLO-PAGINA-INTEGRADA.html](../demo/EJEMPLO-PAGINA-INTEGRADA.html) muestra token, búsqueda de impresoras, selección múltiple, prueba e impresión de un pedido. Para una web real solo hay que reemplazar el objeto `pedido` por los datos propios del sistema.

## 5. Consultar impresoras

```js
const data = await agentRequest('/printers');

console.log(data.printers);   // Todas las impresoras instaladas en Windows
console.log(data.configured); // Las configuradas para este agente
```

## 6. Imprimir en una o varias impresoras

Para enviar el mismo ticket a dos impresoras:

```js
const result = await agentRequest('/print', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    jobId: `pedido-${pedido.id}-${Date.now()}`,
    printerNames: ['ImpCaja', 'POS-58'],
    ticket: {
      id: pedido.id,
      business: 'Mi comercio',
      client: pedido.cliente,
      phone: pedido.telefono,
      payment: pedido.formaPago,
      date: pedido.fecha,
      address: pedido.direccion,
      rows: pedido.productos.map((producto) => ({
        name: producto.nombre,
        quantity: producto.cantidad,
        price: producto.precio,
      })),
      total: pedido.total,
    },
  }),
});

if (result.ok) {
  console.log('Ticket enviado a todas las impresoras.');
}
```

Si se omite `printerNames`, el agente imprime en todas las impresoras configuradas durante la instalación:

```js
await agentRequest('/print', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    jobId: `pedido-${pedido.id}-${Date.now()}`,
    ticket: ticketData,
  }),
});
```

El `jobId` evita duplicados accidentales si la web reintenta la misma solicitud.

## 7. Imprimir un ticket de prueba

```js
await agentRequest('/test', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    printerNames: ['ImpCaja', 'POS-58'],
  }),
});
```

Esto imprime físicamente. Usalo solamente cuando quieras probar las impresoras.

## 8. Rutas disponibles

| Método | Ruta | Uso |
|---|---|---|
| GET | `/health` | Verificar que el agente esté activo |
| GET | `/printers` | Consultar impresoras instaladas y configuradas |
| POST | `/print` | Enviar un ticket estructurado o RAW |
| POST | `/test` | Imprimir ticket de prueba |

Todas las rutas requieren `Authorization: Bearer TOKEN`, salvo la solicitud CORS `OPTIONS`.

## 9. Enviar ESC/POS RAW propio

Si la web ya genera los comandos ESC/POS, puede enviarlos codificados en Base64:

```js
function toBase64Utf8(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

await agentRequest('/print', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    jobId: `raw-${Date.now()}`,
    printerNames: ['ImpCaja'],
    rawBase64: toBase64Utf8(escPosCommands),
  }),
});
```

## 10. Solución de problemas

### La web muestra `Failed to fetch`

1. Confirmá que el agente esté iniciado.
2. Ejecutá `iniciar-agente\iniciar-agente.bat` para probarlo manualmente.
3. Abrí `http://127.0.0.1:8765/health`.
4. Verificá que la URL de la web haya sido incluida durante la instalación.
5. Confirmá que el token corresponda a la instalación actual.
6. Ejecutá `Ctrl + F5` para evitar JavaScript antiguo en caché.

### Devuelve `401 Token inválido`

El token no coincide con el `config.json` cargado por el agente. Consultá `token.txt` o ejecutá nuevamente el instalador.

### No aparecen impresoras

Verificá que Windows las muestre con `Get-Printer` en PowerShell y que el nombre escrito en el instalador sea exacto.

### Imprime caracteres incorrectos

El formato ESC/POS y la tabla de caracteres dependen del modelo. El agente normaliza acentos para trabajar con impresoras térmicas sencillas; para una impresora específica puede ser necesario seleccionar otra tabla de caracteres o enviar comandos propios.

### Se abre el diálogo de Windows

Eso significa que la web está usando un respaldo de impresión del navegador o que no está utilizando el agente. La integración silenciosa debe llamar a `/print` directamente y no a `window.print()`.

## 11. Seguridad y publicación

- No subas `config.json`, `token.txt` ni tokens a GitHub.
- Cada computadora debe tener su propio token.
- Limitá `allowedOrigins` al origen real de la web.
- El agente escucha solamente en `127.0.0.1`; no debe exponerse a Internet.
- Si una web pública contiene un token fijo en su JavaScript, cualquier visitante podría verlo. Para varios usuarios/equipos, configurá el token localmente por equipo o usá un mecanismo de activación por dispositivo.

## 12. Crear una nueva versión

1. Modificá los archivos correspondientes dentro de `integracion`.
2. Ejecutá las validaciones:

   ```powershell
   node --check .\integracion\server.js
   ```

3. Probá `/health` y `/printers`.
4. Si cambiás la configuración de Windows o el código del agente instalado, volvé a ejecutar `integracion\instalar-agente.bat`.
5. Publicá los cambios en el repositorio:

   ```powershell
   git add .
   git commit -m "Describe el cambio"
   git push
   ```

## 13. Ejemplo visual completo

La demo incluida en `demo/demo-configuracion.html` representa la pantalla que puede agregar cualquier web:

1. Campo para pegar el token local.
2. Estado de conexión con el agente.
3. Lista múltiple de impresoras.
4. Botón para buscar impresoras.
5. Botón de prueba.
6. Vista del JSON que se enviaría a `/print`.

La demo no contiene un token real y no debe usarse como sustituto de la integración de producción. Para producción, reemplazá la simulación por `fetch()` usando el ejemplo de `integracion/EJEMPLO-INTEGRACION.js`.
