# Alternativa a QZ Tray OC

Agente local para imprimir tickets ESC/POS de 58 mm desde cualquier web en Windows.

El instalador conserva el nombre interno `Agendarte Printer Agent` por compatibilidad con la instalación existente.

Este proyecto también puede conectarse a cualquier web autorizada. La guía completa está en [INSTRUCTIVO.md](INSTRUCTIVO.md) y el ejemplo de integración en [EJEMPLO-INTEGRACION.js](EJEMPLO-INTEGRACION.js).

También podés abrir la [demo visual de configuración](demo-configuracion.html) para ver la pantalla, el flujo y el JSON intercambiado.

Para una integración rápida, incluí [agendarte-printer-client.js](agendarte-printer-client.js) en la web. Ese cliente guarda el token y las impresoras por perfil en el navegador y expone `connect()`, `discover()`, `print()` y `test()`. Hay una página funcional completa en [EJEMPLO-PAGINA-INTEGRADA.html](EJEMPLO-PAGINA-INTEGRADA.html).

```html
<script src="https://raw.githubusercontent.com/viernes69/alternativa-a-qz-tray-oc/main/agendarte-printer-client.js"></script>
<script>
  (async () => {
    const impresora = AgendartePrinter.create({ profile: 'mi-comercio' });
    impresora.setConfig({ token: document.querySelector('#token').value });
    await impresora.print({
      id: pedido.id,
      business: 'Mi comercio',
      client: pedido.cliente,
      rows: pedido.productos,
      total: pedido.total,
    });
  })();
</script>
```

El archivo es público, pero cada instalación conserva su token local. No publiques un token real dentro del código de una web pública.

## Instalación

1. Verificá que Node.js esté instalado.
2. Ejecutá `instalar-agente.bat`.
3. Ingresá la web autorizada.
4. Indicá cuántas impresoras usarás.
5. Escribí el nombre exacto de cada impresora de Windows.

El instalador copia el agente a `%LOCALAPPDATA%\AgendartePrinterAgent`, crea la configuración y registra una tarea oculta para iniciar el servicio al iniciar sesión en Windows.

También crea `%LOCALAPPDATA%\AgendartePrinterAgent\token.txt` con el token vigente y la fecha/hora de generación. Si se vuelve a ejecutar el instalador, ese archivo se actualiza y el token anterior deja de ser válido.

Para abrirlo rápidamente, ejecutá `ver-token.bat`.

## API local

- `GET http://127.0.0.1:8765/health`
- `GET http://127.0.0.1:8765/printers`
- `POST http://127.0.0.1:8765/print`
- `POST http://127.0.0.1:8765/test`

Las solicitudes desde la web deben incluir el token generado por el instalador:

```http
Authorization: Bearer TOKEN_LOCAL
Content-Type: application/json
```

Ejemplo de impresión:

```json
{
  "jobId": "pedido-123",
  "printerName": "Nombre exacto de Windows",
  "ticket": {
    "id": "123",
    "business": "Mi comercio",
    "client": "Lucas",
    "rows": [
      { "name": "Producto", "quantity": 1, "price": 150 }
    ],
    "total": 150
  }
}
```

El agente envía el trabajo como `RAW` al spooler de Windows, con un máximo seguro de 32 columnas para papel de 58 mm.
