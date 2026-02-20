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
