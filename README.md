# Audio Link (Windows -> Android)

MVP de streaming de audio de baja latencia para uso diario.

## Estado actual

- `windows-sender`: funcional en Rust, envia audio PCM16LE por UDP.
- `android-receiver`: app Android (Kotlin) que recibe UDP, aplica jitter buffer y reproduce con `AudioTrack`.
- Protocolo propio de paquetes con `seq` y `timestamp`.

Nota: esta v1 usa `cpal` en Windows, por lo que captura **entrada por defecto (microfono/line-in)**. El siguiente paso es cambiar a WASAPI loopback para capturar audio del sistema.

## Estructura

- `windows-sender/` emisor CLI en Rust
- `android-receiver/` app receptor Android

## Protocolo UDP (v1)

Header fijo de 28 bytes + payload PCM16LE:

1. magic `AUD0` (4 bytes)
2. version `1` (u8)
3. codec `0 = PCM16LE` (u8)
4. channels (u8)
5. reserved (u8)
6. sample_rate (u32 LE)
7. seq (u32 LE)
8. send_time_us (u64 LE, unix micros)
9. samples_per_channel (u16 LE)
10. payload_len (u16 LE)

## Uso rapido

### 1) Android receiver

1. Abre `android-receiver` en Android Studio.
2. Ejecuta la app en tu telefono.
3. Ingresa puerto (por defecto `50000`) y jitter objetivo (por defecto `20 ms`).
4. Pulsa `Start`.

### 2) Windows sender

Compila y ejecuta:

```powershell
cd windows-sender
cargo run --release -- --target-ip <IP_DEL_ANDROID> --port 50000 --frame-ms 5
```

Ejemplo:

```powershell
cargo run --release -- --target-ip 192.168.0.45 --port 50000 --frame-ms 5
```

## USB tethering

Activa "USB tethering" en Android y usa la IP de la interfaz tether. El protocolo es el mismo (UDP), solo cambia la red.

## Siguientes pasos recomendados

1. Cambiar PCM por Opus (5 ms, FEC) para menor ancho de banda.
2. Migrar captura Windows a WASAPI loopback (audio del sistema).
3. Añadir cifrado y descubrimiento de peers.
