# Audio Link (Windows -> Android)

Streaming de audio de baja latencia para uso diario personal.

## Estado v1 personal

- `windows-sender` (Rust): captura `desktop` (WASAPI loopback) o `mic`.
- `android-receiver` (Kotlin): recibe y reproduce audio con jitter buffer adaptativo.
- Transportes soportados:
  - `udp` para LAN.
  - `tcp` para LAN o USB (`adb forward`).

## Estructura

- `windows-sender/`: emisor CLI en Rust.
- `android-receiver/`: app receptor Android.
- `tools/launcher/`: scripts de inicio/parada 1 clic.
- `tools/release/`: script de empaquetado.
- `tools/audio-report/`: pruebas y reportes.

## Uso normal (red LAN)

1. En Android abre la app y pulsa `Start` (port/jitter/transport).
2. En Windows:

```powershell
cd windows-sender
cargo run --release -- --target-ip 192.168.100.49 --port 50000 --frame-ms 5 --transport udp --source desktop
```

Para microfono:

```powershell
cargo run --release -- --target-ip 192.168.100.49 --port 50000 --frame-ms 5 --transport udp --source mic
```

## Uso por USB (sin depender de Wi-Fi)

1. Conecta Android por USB con ADB activo.
2. Crea forward:

```powershell
adb -s <serial> forward tcp:50000 tcp:50000
```

3. Inicia receiver en Android con `transport=tcp` (desde app o ADB).
4. Ejecuta sender hacia loopback local:

```powershell
cd windows-sender
cargo run --release -- --target-ip 127.0.0.1 --port 50000 --frame-ms 5 --transport tcp --source desktop
```

## Arranque/parada 1 clic

Modo red:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\launcher\start-audio-link.ps1 -Mode network -TargetIp 192.168.100.49 -Source desktop -JitterMs 20
```

Modo USB:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\launcher\start-audio-link.ps1 -Mode usb -DeviceSerial 344b5d65 -Source desktop -JitterMs 20
```

Nota: en `-Mode usb` el launcher activa auto-reconexion por defecto (watchdog en segundo plano).
Log del watchdog: `tools/launcher/.runtime/watchdog.log`.

Parar:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\launcher\stop-audio-link.ps1
```

## Launcher unificado (recomendado)

Desde la raiz del repo usa un solo comando para encender/apagar todo:

```powershell
powershell -ExecutionPolicy Bypass -File .\audio-link.ps1 -Action <start|stop|restart|status|logs> -Profile <both|downlink|uplink>
```

Ejemplos:

```powershell
# Inicia ambos flujos
powershell -ExecutionPolicy Bypass -File .\audio-link.ps1 -Action start -Profile both -DownMode network -DownTargetIp 192.168.100.49 -UpTargetIp 192.168.100.17 -DownSource desktop -UpMicSource auto

# Detiene todo
powershell -ExecutionPolicy Bypass -File .\audio-link.ps1 -Action stop -Profile both

# Estado rapido
powershell -ExecutionPolicy Bypass -File .\audio-link.ps1 -Action status -Profile both

# Ver logs (cola)
powershell -ExecutionPolicy Bypass -File .\audio-link.ps1 -Action logs -Profile both -Tail 60
```

Tambien puedes usar `.\audio-link.cmd` (misma sintaxis) desde `cmd` o PowerShell.

### UI Windows (GUI)

Tambien tienes interfaz grafica para gestionar todo sin comandos:

```powershell
powershell -ExecutionPolicy Bypass -File .\audio-link-ui.ps1
```

o doble clic en:

```text
audio-link-ui.cmd
```

La GUI permite:
- `start/stop/restart/status/logs`
- Perfil `both/downlink/uplink`
- Configurar IP/puertos/source/transport/mic source
- Ver salida y logs en una sola ventana

## Web UI local (navegador o base para Electron)

Servidor local en `localhost` con panel moderno para controlar downlink/uplink:

```powershell
powershell -ExecutionPolicy Bypass -File .\audio-link-web.ps1
```

Opciones utiles:

```powershell
# Puerto custom
powershell -ExecutionPolicy Bypass -File .\audio-link-web.ps1 -Port 47840

# Sin abrir navegador automatico
powershell -ExecutionPolicy Bypass -File .\audio-link-web.ps1 -NoOpenBrowser

# Con token API opcional
powershell -ExecutionPolicy Bypass -File .\audio-link-web.ps1 -Token mi_token_seguro
```

Si el puerto solicitado esta ocupado, el servidor intenta automaticamente el siguiente puerto libre.

Tambien puedes usar doble clic en:

```text
audio-link-web.cmd
```

## V2 dev: Android mic -> Windows (Teams)

Objetivo: usar el microfono del Android como entrada en Windows a traves de un dispositivo virtual.

1. Instala un dispositivo virtual de audio en Windows (ejemplo: VB-Cable).
2. En Windows ejecuta el receptor:

```powershell
cd windows-receiver
cargo run --release -- --transport tcp --port 50010 --output-device "CABLE Input (VB-Audio Virtual Cable)"
```

O con launcher 1 clic:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\launcher\start-windows-mic-bridge.ps1 -Transport tcp -Port 50010 -OutputDevice "CABLE Input (VB-Audio Virtual Cable)"
```

Si no sabes el nombre exacto:

```powershell
cargo run --release -- --list-output-devices
```

3. En Android, en la app:
   - Seccion `Android Mic -> Windows (Sender)`
   - `Target IP`: IP de tu PC (o `127.0.0.1` si usas USB con adb forward a ese puerto).
   - `Port`: `50010`
   - `Transport`: `tcp` (recomendado)
   - `Frame`: `5`
   - `Mic source`: `auto` (por defecto), `phone` o `bluetooth`
   - Pulsa `Start Mic Sender`.

Tambien puedes arrancarlo por ADB:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\launcher\start-android-mic.ps1 -TargetIp 192.168.100.20 -Port 50010 -Transport tcp -MicSource auto
```

Parar sender de mic:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\launcher\stop-android-mic.ps1
```

Parar bridge de Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\launcher\stop-windows-mic-bridge.ps1
```

4. En Teams selecciona como microfono el endpoint de entrada del cable virtual (ej: `CABLE Output`).

## Empaquetado release

Genera carpeta `dist/audio-link-v1-personal-...` con `windows-sender.exe`, APK y scripts:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\release\package-release.ps1
```

Opcional (firmar APK release si pasas keystore):

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\release\package-release.ps1 `
  -AndroidBuildType release `
  -KeystorePath C:\keys\my-release.jks `
  -KeystoreAlias myalias `
  -KeystorePassword "secret"
```

## Parametros clave (sender)

- `--target-ip`: IP destino (`127.0.0.1` si usas USB + `adb forward`).
- `--port`: puerto receptor.
- `--frame-ms`: 1..20 ms por paquete. Menor latencia, mayor sensibilidad.
- `--transport`: `udp` o `tcp`.
- `--source`: `desktop` o `mic`.
- `--desktop-device`: nombre exacto del dispositivo de salida para loopback.
- `--list-desktop-devices`: lista dispositivos render disponibles.
