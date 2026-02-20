# Audio Report Workflow

Este flujo genera un reporte que prioriza metricas objetivas para encontrar el punto dulce.

## 1) Capturar logs por corrida

Usa una etiqueta por prueba, por ejemplo `25ms`, `35ms`, `45ms`.

### Sender (Windows)

```powershell
cd C:\Users\RX\Proyectos\Audio\windows-sender
cargo run --release -- --target-ip <IP_ANDROID> --port 50000 --frame-ms 5 --source desktop `
  2>&1 | Tee-Object C:\Users\RX\Proyectos\Audio\reports\sender_35ms.log
```

### Receiver (Android logcat)

En otra terminal:

```powershell
adb logcat -c
adb logcat | Select-String UdpAudioService `
  | Tee-Object C:\Users\RX\Proyectos\Audio\reports\receiver_35ms.log
```

Repite para distintas etiquetas cambiando solo nombre de archivo y jitter configurado en la app.

## 2) Generar reporte

```powershell
cd C:\Users\RX\Proyectos\Audio
python tools\audio-report\audio_report.py `
  --logs-dir reports `
  --out-json reports\audio_report.json `
  --out-md reports\audio_report.md
```

## Automatizacion (1 comando por corrida)

Antes de cada corrida, configura manualmente en la app Android el jitter que quieres evaluar.

Ejemplo (35 ms):

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\RX\Proyectos\Audio\tools\audio-report\run-audio-test.ps1 `
  -TargetIp 192.168.100.49 `
  -JitterMs 35 `
  -DeviceSerial 344b5d65 `
  -Source desktop `
  -ReferenceAudioFile ".\mi_referencia.m4a" `
  -DesktopDevice "Headphones (HUAWEI USB-C HEADSET)" `
  -DurationSec 40
```

Notas:

- No uses `127.0.0.1` como `TargetIp` (eso envia al mismo PC, no al telefono).
- Inicia manualmente la app Android y pulsa `Start` antes de correr el script.
- Si tu build permite arrancar el servicio desde ADB, puedes probar `-AutoStartReceiver`.
- Si no escuchas nada en `desktop`, usa `-DesktopDevice` para fijar el endpoint correcto.
- Para pruebas parecidas, el script reproduce audio de referencia en loop cuando `-Source desktop`.
- Si no pasas `-ReferenceAudioFile`, intenta autodetectar 1 archivo de audio en la raiz del proyecto.
- Si hay varios audios en raiz, debes indicar uno con `-ReferenceAudioFile`.

El script guarda:

- `reports\sender_35ms.log`
- `reports\receiver_35ms.log`
- y actualiza `reports\audio_report.json` + `reports\audio_report.md`

Ejemplo de barrido rapido:

```powershell
foreach ($j in 25,35,45,55) {
  powershell -ExecutionPolicy Bypass -File C:\Users\RX\Proyectos\Audio\tools\audio-report\run-audio-test.ps1 `
    -TargetIp 192.168.100.49 `
    -JitterMs $j `
    -DeviceSerial 344b5d65 `
    -Source desktop `
    -DurationSec 40
}
```

## 3) Interpretacion

El script calcula un `sweet_score` (0-100) y hace ranking.

- Mejor run: score mas alto.
- Desempate: menor `buffer_ms`, luego menor `underrun` y `loss`.
- Si hay `parseErr` o `payloadErr`, esa corrida se penaliza fuerte.
