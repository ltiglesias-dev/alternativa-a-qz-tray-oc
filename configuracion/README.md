# Configuración

La configuración real del agente se guarda en Windows, no dentro del repositorio:

```text
%LOCALAPPDATA%\AgendartePrinterAgent\config.json
%LOCALAPPDATA%\AgendartePrinterAgent\token.txt
```

Para configurarlo o cambiar la web, el token o las impresoras, ejecutá:

```text
..\integracion\instalar-agente.bat
```

La ventana gráfica muestra el puerto local abierto en ese PC, genera un token nuevo y reemplaza la configuración anterior. El puerto y la URL local también quedan en `token.txt`. Nunca publiques `config.json` ni `token.txt`.
