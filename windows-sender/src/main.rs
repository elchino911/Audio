use std::collections::VecDeque;
use std::io::Write;
use std::net::{SocketAddr, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc as std_mpsc;
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use clap::{Parser, ValueEnum};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};
use crossbeam_channel::{bounded, Receiver, Sender, TrySendError};
use wasapi::{DeviceEnumerator, Direction as WasapiDirection, SampleType, StreamMode, WaveFormat};

const MAGIC: [u8; 4] = *b"AUD0";
const VERSION: u8 = 1;
const CODEC_PCM16: u8 = 0;
const HEADER_SIZE: usize = 28;

const DESKTOP_SAMPLE_RATE: u32 = 48_000;
const DESKTOP_CHANNELS: usize = 2;

#[derive(Default)]
struct SenderStats {
    captured_chunks: AtomicU64,
    captured_samples: AtomicU64,
    captured_nonzero_samples: AtomicU64,
    captured_abs_sum: AtomicU64,
    capture_drops: AtomicU64,
    capture_queue_us_sum: AtomicU64,
    capture_queue_count: AtomicU64,
    capture_to_send_us_sum: AtomicU64,
    capture_to_send_count: AtomicU64,
    packet_build_us_sum: AtomicU64,
    packet_build_count: AtomicU64,
    socket_send_us_sum: AtomicU64,
    socket_send_count: AtomicU64,
    sent_packets: AtomicU64,
    sent_bytes: AtomicU64,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum AudioSource {
    Desktop,
    Mic,
}

impl AudioSource {
    fn as_str(self) -> &'static str {
        match self {
            AudioSource::Desktop => "desktop",
            AudioSource::Mic => "mic",
        }
    }
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum Transport {
    Udp,
    Tcp,
}

impl Transport {
    fn as_str(self) -> &'static str {
        match self {
            Transport::Udp => "udp",
            Transport::Tcp => "tcp",
        }
    }
}

enum CaptureGuard {
    Mic(cpal::Stream),
    Desktop(thread::JoinHandle<()>),
}

impl CaptureGuard {
    fn keepalive_ref(&self) {
        match self {
            CaptureGuard::Mic(stream) => {
                let _ = stream;
            }
            CaptureGuard::Desktop(handle) => {
                let _ = handle;
            }
        }
    }
}

struct CaptureSetup {
    sample_rate: u32,
    channels: usize,
    source_name: String,
    guard: CaptureGuard,
}

struct CaptureChunk {
    samples: Vec<i16>,
    captured_at: Instant,
}

#[derive(Parser, Debug)]
#[command(
    author,
    version,
    about = "Low-latency UDP audio sender (Windows -> Android)"
)]
struct Args {
    #[arg(long)]
    target_ip: Option<String>,
    #[arg(long, default_value_t = 50000)]
    port: u16,
    #[arg(long, default_value_t = 5)]
    frame_ms: u32,
    #[arg(long, value_enum, default_value_t = AudioSource::Desktop)]
    source: AudioSource,
    #[arg(long)]
    desktop_device: Option<String>,
    #[arg(long, default_value_t = false)]
    list_desktop_devices: bool,
    #[arg(long, value_enum, default_value_t = Transport::Udp)]
    transport: Transport,
}

fn main() -> Result<()> {
    let args = Args::parse();
    if args.list_desktop_devices {
        list_desktop_devices()?;
        return Ok(());
    }
    if !(1..=20).contains(&args.frame_ms) {
        bail!("--frame-ms must be in range [1, 20]");
    }

    let target_ip = args
        .target_ip
        .as_deref()
        .context("--target-ip is required unless --list-desktop-devices is used")?;

    let target: SocketAddr = format!("{}:{}", target_ip, args.port)
        .parse()
        .context("invalid target endpoint")?;

    let (tx, rx) = bounded::<CaptureChunk>(512);
    let stats = Arc::new(SenderStats::default());

    let capture = match args.source {
        AudioSource::Mic => start_mic_capture(tx, Arc::clone(&stats))?,
        AudioSource::Desktop => {
            start_desktop_capture(tx, Arc::clone(&stats), args.desktop_device.as_deref())?
        }
    };

    let sample_rate = capture.sample_rate;
    let channels = capture.channels;
    let _capture_guard = capture.guard;
    _capture_guard.keepalive_ref();

    let samples_per_channel = ((sample_rate as u64 * args.frame_ms as u64) / 1000) as usize;
    let samples_per_packet = samples_per_channel * channels;

    println!("Source: {} ({})", args.source.as_str(), capture.source_name);
    println!(
        "Config: {} Hz, {} ch, frame={} ms ({} samples/ch)",
        sample_rate, channels, args.frame_ms, samples_per_channel
    );
    println!("Target: {target}");
    println!("Transport: {}", args.transport.as_str());
    println!("Stats: one line per second (pps/kbps/drops/backlog)");

    let _stats_thread = spawn_stats_logger(Arc::clone(&stats), rx.clone(), args.frame_ms);

    match args.transport {
        Transport::Udp => {
            let socket = UdpSocket::bind("0.0.0.0:0").context("failed to bind UDP sender socket")?;
            socket
                .set_nonblocking(false)
                .context("failed to configure UDP socket")?;

            send_loop(
                rx,
                sample_rate,
                channels as u8,
                samples_per_channel as u16,
                samples_per_packet,
                0,
                stats,
                move |packet: &[u8], seq| {
                    socket
                        .send_to(packet, target)
                        .with_context(|| format!("failed to send UDP packet seq={seq}"))?;
                    Ok(())
                },
            )
        }
        Transport::Tcp => {
            let mut stream = TcpStream::connect(target)
                .with_context(|| format!("failed to connect TCP stream to {target}"))?;
            stream
                .set_nodelay(true)
                .context("failed to set TCP_NODELAY on sender socket")?;

            send_loop(
                rx,
                sample_rate,
                channels as u8,
                samples_per_channel as u16,
                samples_per_packet,
                2,
                stats,
                move |packet: &[u8], seq| {
                    let len = u16::try_from(packet.len())
                        .context("packet too large for TCP length prefix")?;
                    stream
                        .write_all(&len.to_le_bytes())
                        .with_context(|| format!("failed to send TCP packet length seq={seq}"))?;
                    stream
                        .write_all(packet)
                        .with_context(|| format!("failed to send TCP packet payload seq={seq}"))?;
                    Ok(())
                },
            )
        }
    }
}

fn start_mic_capture(tx: Sender<CaptureChunk>, stats: Arc<SenderStats>) -> Result<CaptureSetup> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .context("no default input device found")?;
    let device_name = device.name().unwrap_or_else(|_| "unknown".to_string());
    let supported = device
        .default_input_config()
        .context("failed to read default input config")?;

    let sample_format = supported.sample_format();
    let config: StreamConfig = supported.into();
    let sample_rate = config.sample_rate.0;
    let channels = config.channels as usize;

    let stream = build_input_stream(&device, &config, sample_format, tx, stats)?;
    stream.play().context("failed to start input stream")?;

    Ok(CaptureSetup {
        sample_rate,
        channels,
        source_name: device_name,
        guard: CaptureGuard::Mic(stream),
    })
}

fn start_desktop_capture(
    tx: Sender<CaptureChunk>,
    stats: Arc<SenderStats>,
    desktop_device_name: Option<&str>,
) -> Result<CaptureSetup> {
    let sample_rate = DESKTOP_SAMPLE_RATE;
    let channels = DESKTOP_CHANNELS;
    let (ready_tx, ready_rx) = std_mpsc::sync_channel::<Result<String, String>>(1);
    let desktop_device_name_owned = desktop_device_name.map(|s| s.to_string());

    let handle = thread::Builder::new()
        .name("wasapi-loopback".to_string())
        .spawn(move || {
            desktop_capture_loop(
                tx,
                stats,
                sample_rate,
                channels,
                desktop_device_name_owned,
                ready_tx,
            );
        })
        .context("failed to spawn desktop capture thread")?;

    let source_name = ready_rx
        .recv_timeout(Duration::from_secs(5))
        .context("desktop capture thread did not initialize in time")?
        .map_err(|msg| anyhow::anyhow!(msg))?;

    Ok(CaptureSetup {
        sample_rate,
        channels,
        source_name,
        guard: CaptureGuard::Desktop(handle),
    })
}

fn desktop_capture_loop(
    tx: Sender<CaptureChunk>,
    stats: Arc<SenderStats>,
    sample_rate: u32,
    channels: usize,
    desktop_device_name: Option<String>,
    ready_tx: std_mpsc::SyncSender<Result<String, String>>,
) {
    if let Err(err) = desktop_capture_inner(
        tx,
        stats,
        sample_rate,
        channels,
        desktop_device_name.as_deref(),
        &ready_tx,
    ) {
        let _ = ready_tx.send(Err(format!("{err:#}")));
        eprintln!("desktop loopback stopped: {err:#}");
    }
}

fn desktop_capture_inner(
    tx: Sender<CaptureChunk>,
    stats: Arc<SenderStats>,
    sample_rate: u32,
    channels: usize,
    desktop_device_name: Option<&str>,
    ready_tx: &std_mpsc::SyncSender<Result<String, String>>,
) -> Result<()> {
    wasapi::initialize_mta()
        .ok()
        .context("failed to initialize COM MTA for WASAPI")?;

    let enumerator =
        DeviceEnumerator::new().context("failed to create WASAPI device enumerator")?;
    let device = if let Some(name) = desktop_device_name {
        let collection = enumerator
            .get_device_collection(&WasapiDirection::Render)
            .context("failed to get render device collection")?;
        collection
            .get_device_with_name(name)
            .with_context(|| format!("failed to find render device with name '{name}'"))?
    } else {
        enumerator
            .get_default_device(&WasapiDirection::Render)
            .context("failed to get default render device")?
    };
    let device_name = device
        .get_friendlyname()
        .unwrap_or_else(|_| "default render device".to_string());

    let mut audio_client = device
        .get_iaudioclient()
        .context("failed to get IAudioClient")?;
    let desired_format = WaveFormat::new(
        32,
        32,
        &SampleType::Float,
        sample_rate as usize,
        channels,
        None,
    );
    let mode = StreamMode::EventsShared {
        autoconvert: true,
        buffer_duration_hns: 0,
    };
    audio_client
        .initialize_client(&desired_format, &WasapiDirection::Capture, &mode)
        .context("failed to initialize desktop loopback client")?;
    let event = audio_client
        .set_get_eventhandle()
        .context("failed to set WASAPI event handle")?;
    let capture_client = audio_client
        .get_audiocaptureclient()
        .context("failed to get WASAPI capture client")?;
    audio_client
        .start_stream()
        .context("failed to start desktop loopback stream")?;

    let _ = ready_tx.send(Ok(device_name));

    let mut byte_queue = VecDeque::<u8>::with_capacity(32 * 1024);
    let frame_bytes = channels * 4;

    loop {
        if let Err(err) = event.wait_for_event(1000) {
            eprintln!("desktop loopback event wait timeout/error: {err}");
            continue;
        }

        if let Err(err) = capture_client.read_from_device_to_deque(&mut byte_queue) {
            eprintln!("desktop loopback read error: {err}");
            thread::sleep(Duration::from_millis(10));
            continue;
        }

        if byte_queue.len() < frame_bytes {
            continue;
        }

        let available_frames = byte_queue.len() / frame_bytes;
        let mut chunk = Vec::<i16>::with_capacity(available_frames * channels);
        for _ in 0..available_frames {
            for _ in 0..channels {
                let sample = pop_f32_le(&mut byte_queue).unwrap_or(0.0);
                let clamped = sample.clamp(-1.0, 1.0);
                chunk.push((clamped * i16::MAX as f32) as i16);
            }
        }
        enqueue_audio_chunk(&tx, &stats, chunk);
    }
}

fn pop_f32_le(queue: &mut VecDeque<u8>) -> Option<f32> {
    if queue.len() < 4 {
        return None;
    }
    let b0 = queue.pop_front()?;
    let b1 = queue.pop_front()?;
    let b2 = queue.pop_front()?;
    let b3 = queue.pop_front()?;
    Some(f32::from_le_bytes([b0, b1, b2, b3]))
}

fn enqueue_audio_chunk(tx: &Sender<CaptureChunk>, stats: &Arc<SenderStats>, chunk: Vec<i16>) {
    if chunk.is_empty() {
        return;
    }

    let mut abs_sum = 0_u64;
    let mut nonzero = 0_u64;
    for s in &chunk {
        let v = *s as i32;
        abs_sum += v.unsigned_abs() as u64;
        if *s != 0 {
            nonzero += 1;
        }
    }
    stats
        .captured_samples
        .fetch_add(chunk.len() as u64, Ordering::Relaxed);
    stats.captured_abs_sum.fetch_add(abs_sum, Ordering::Relaxed);
    stats
        .captured_nonzero_samples
        .fetch_add(nonzero, Ordering::Relaxed);
    match tx.try_send(CaptureChunk {
        samples: chunk,
        captured_at: Instant::now(),
    }) {
        Ok(_) => {
            stats.captured_chunks.fetch_add(1, Ordering::Relaxed);
        }
        Err(TrySendError::Full(_)) => {
            stats.capture_drops.fetch_add(1, Ordering::Relaxed);
        }
        Err(TrySendError::Disconnected(_)) => {}
    }
}

fn send_loop<F>(
    rx: Receiver<CaptureChunk>,
    sample_rate: u32,
    channels: u8,
    samples_per_channel: u16,
    samples_per_packet: usize,
    per_packet_overhead_bytes: usize,
    stats: Arc<SenderStats>,
    mut send_packet: F,
) -> Result<()>
where
    F: FnMut(&[u8], u32) -> Result<()>,
{
    let mut seq: u32 = 0;
    let mut acc = VecDeque::<i16>::with_capacity(samples_per_packet * 4);
    let mut acc_capture = VecDeque::<(usize, Instant)>::with_capacity(64);

    loop {
        let chunk = rx.recv().context("audio capture channel closed")?;
        let chunk_queue_us = chunk.captured_at.elapsed().as_micros() as u64;
        stats
            .capture_queue_us_sum
            .fetch_add(chunk_queue_us, Ordering::Relaxed);
        stats.capture_queue_count.fetch_add(1, Ordering::Relaxed);

        let chunk_samples = chunk.samples.len();
        for s in chunk.samples {
            acc.push_back(s);
        }
        if chunk_samples > 0 {
            acc_capture.push_back((chunk_samples, chunk.captured_at));
        }

        while acc.len() >= samples_per_packet {
            let packet_capture_time = consume_capture_time(&mut acc_capture, samples_per_packet);
            let mut payload = vec![0u8; samples_per_packet * 2];
            for i in 0..samples_per_packet {
                let sample = acc.pop_front().unwrap_or(0);
                let bytes = sample.to_le_bytes();
                payload[i * 2] = bytes[0];
                payload[i * 2 + 1] = bytes[1];
            }

            let packet_build_start = Instant::now();
            let packet = build_packet(seq, sample_rate, channels, samples_per_channel, &payload)?;
            let packet_build_us = packet_build_start.elapsed().as_micros() as u64;
            stats
                .packet_build_us_sum
                .fetch_add(packet_build_us, Ordering::Relaxed);
            stats.packet_build_count.fetch_add(1, Ordering::Relaxed);

            let send_start = Instant::now();
            send_packet(&packet, seq)?;
            let socket_send_us = send_start.elapsed().as_micros() as u64;
            stats
                .socket_send_us_sum
                .fetch_add(socket_send_us, Ordering::Relaxed);
            stats.socket_send_count.fetch_add(1, Ordering::Relaxed);
            stats.sent_packets.fetch_add(1, Ordering::Relaxed);
            stats
                .sent_bytes
                .fetch_add((packet.len() + per_packet_overhead_bytes) as u64, Ordering::Relaxed);
            if let Some(captured_at) = packet_capture_time {
                let capture_to_send_us = captured_at.elapsed().as_micros() as u64;
                stats
                    .capture_to_send_us_sum
                    .fetch_add(capture_to_send_us, Ordering::Relaxed);
                stats.capture_to_send_count.fetch_add(1, Ordering::Relaxed);
            }
            seq = seq.wrapping_add(1);
        }
    }
}

fn consume_capture_time(
    acc_capture: &mut VecDeque<(usize, Instant)>,
    mut samples_to_consume: usize,
) -> Option<Instant> {
    let oldest = acc_capture.front().map(|(_, captured_at)| *captured_at);
    while samples_to_consume > 0 {
        let Some((count, captured_at)) = acc_capture.pop_front() else {
            break;
        };
        if count > samples_to_consume {
            acc_capture.push_front((count - samples_to_consume, captured_at));
            break;
        }
        samples_to_consume -= count;
    }
    oldest
}

fn build_packet(
    seq: u32,
    sample_rate: u32,
    channels: u8,
    samples_per_channel: u16,
    payload: &[u8],
) -> Result<Vec<u8>> {
    if payload.len() > u16::MAX as usize {
        bail!("payload too large");
    }

    let send_time_us = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock before unix epoch")?
        .as_micros() as u64;

    let mut packet = Vec::with_capacity(HEADER_SIZE + payload.len());
    packet.extend_from_slice(&MAGIC);
    packet.push(VERSION);
    packet.push(CODEC_PCM16);
    packet.push(channels);
    packet.push(0);
    packet.extend_from_slice(&sample_rate.to_le_bytes());
    packet.extend_from_slice(&seq.to_le_bytes());
    packet.extend_from_slice(&send_time_us.to_le_bytes());
    packet.extend_from_slice(&samples_per_channel.to_le_bytes());
    packet.extend_from_slice(&(payload.len() as u16).to_le_bytes());
    packet.extend_from_slice(payload);
    Ok(packet)
}

fn build_input_stream(
    device: &cpal::Device,
    config: &StreamConfig,
    sample_format: SampleFormat,
    tx: Sender<CaptureChunk>,
    stats: Arc<SenderStats>,
) -> Result<cpal::Stream> {
    let err_fn = |err| eprintln!("cpal stream error: {err}");

    let stream = match sample_format {
        SampleFormat::I16 => {
            let tx = tx.clone();
            let stats = Arc::clone(&stats);
            device.build_input_stream(
                config,
                move |data: &[i16], _| {
                    enqueue_audio_chunk(&tx, &stats, data.to_vec());
                },
                err_fn,
                None,
            )?
        }
        SampleFormat::U16 => {
            let tx = tx.clone();
            let stats = Arc::clone(&stats);
            device.build_input_stream(
                config,
                move |data: &[u16], _| {
                    let converted = data
                        .iter()
                        .map(|s| (*s as i32 - 32768) as i16)
                        .collect::<Vec<i16>>();
                    enqueue_audio_chunk(&tx, &stats, converted);
                },
                err_fn,
                None,
            )?
        }
        SampleFormat::F32 => {
            let tx = tx.clone();
            let stats = Arc::clone(&stats);
            device.build_input_stream(
                config,
                move |data: &[f32], _| {
                    let converted = data
                        .iter()
                        .map(|s| {
                            let clamped = s.clamp(-1.0, 1.0);
                            (clamped * i16::MAX as f32) as i16
                        })
                        .collect::<Vec<i16>>();
                    enqueue_audio_chunk(&tx, &stats, converted);
                },
                err_fn,
                None,
            )?
        }
        other => bail!("unsupported sample format: {other:?}"),
    };

    Ok(stream)
}

fn spawn_stats_logger(
    stats: Arc<SenderStats>,
    rx: Receiver<CaptureChunk>,
    frame_ms: u32,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut last_chunks = 0_u64;
        let mut last_samples = 0_u64;
        let mut last_nonzero_samples = 0_u64;
        let mut last_abs_sum = 0_u64;
        let mut last_drops = 0_u64;
        let mut last_capture_queue_us_sum = 0_u64;
        let mut last_capture_queue_count = 0_u64;
        let mut last_capture_to_send_us_sum = 0_u64;
        let mut last_capture_to_send_count = 0_u64;
        let mut last_packet_build_us_sum = 0_u64;
        let mut last_packet_build_count = 0_u64;
        let mut last_socket_send_us_sum = 0_u64;
        let mut last_socket_send_count = 0_u64;
        let mut last_packets = 0_u64;
        let mut last_bytes = 0_u64;

        loop {
            thread::sleep(Duration::from_secs(1));
            let chunks = stats.captured_chunks.load(Ordering::Relaxed);
            let samples = stats.captured_samples.load(Ordering::Relaxed);
            let nonzero_samples = stats.captured_nonzero_samples.load(Ordering::Relaxed);
            let abs_sum = stats.captured_abs_sum.load(Ordering::Relaxed);
            let drops = stats.capture_drops.load(Ordering::Relaxed);
            let capture_queue_us_sum = stats.capture_queue_us_sum.load(Ordering::Relaxed);
            let capture_queue_count = stats.capture_queue_count.load(Ordering::Relaxed);
            let capture_to_send_us_sum = stats.capture_to_send_us_sum.load(Ordering::Relaxed);
            let capture_to_send_count = stats.capture_to_send_count.load(Ordering::Relaxed);
            let packet_build_us_sum = stats.packet_build_us_sum.load(Ordering::Relaxed);
            let packet_build_count = stats.packet_build_count.load(Ordering::Relaxed);
            let socket_send_us_sum = stats.socket_send_us_sum.load(Ordering::Relaxed);
            let socket_send_count = stats.socket_send_count.load(Ordering::Relaxed);
            let packets = stats.sent_packets.load(Ordering::Relaxed);
            let bytes = stats.sent_bytes.load(Ordering::Relaxed);

            let d_chunks = chunks.saturating_sub(last_chunks);
            let d_samples = samples.saturating_sub(last_samples);
            let d_nonzero_samples = nonzero_samples.saturating_sub(last_nonzero_samples);
            let d_abs_sum = abs_sum.saturating_sub(last_abs_sum);
            let d_drops = drops.saturating_sub(last_drops);
            let d_capture_queue_us_sum =
                capture_queue_us_sum.saturating_sub(last_capture_queue_us_sum);
            let d_capture_queue_count =
                capture_queue_count.saturating_sub(last_capture_queue_count);
            let d_capture_to_send_us_sum =
                capture_to_send_us_sum.saturating_sub(last_capture_to_send_us_sum);
            let d_capture_to_send_count =
                capture_to_send_count.saturating_sub(last_capture_to_send_count);
            let d_packet_build_us_sum =
                packet_build_us_sum.saturating_sub(last_packet_build_us_sum);
            let d_packet_build_count = packet_build_count.saturating_sub(last_packet_build_count);
            let d_socket_send_us_sum = socket_send_us_sum.saturating_sub(last_socket_send_us_sum);
            let d_socket_send_count = socket_send_count.saturating_sub(last_socket_send_count);
            let d_packets = packets.saturating_sub(last_packets);
            let d_bytes = bytes.saturating_sub(last_bytes);
            let kbps = (d_bytes as f64 * 8.0) / 1000.0;
            let queue_backlog = rx.len();
            let avg_abs = if d_samples > 0 {
                d_abs_sum as f64 / d_samples as f64
            } else {
                0.0
            };
            let active_pct = if d_samples > 0 {
                (d_nonzero_samples as f64 * 100.0) / d_samples as f64
            } else {
                0.0
            };
            let capq_ms = if d_capture_queue_count > 0 {
                (d_capture_queue_us_sum as f64 / d_capture_queue_count as f64) / 1000.0
            } else {
                0.0
            };
            let capsend_ms = if d_capture_to_send_count > 0 {
                (d_capture_to_send_us_sum as f64 / d_capture_to_send_count as f64) / 1000.0
            } else {
                0.0
            };
            let pkt_ms = if d_packet_build_count > 0 {
                (d_packet_build_us_sum as f64 / d_packet_build_count as f64) / 1000.0
            } else {
                0.0
            };
            let sock_ms = if d_socket_send_count > 0 {
                (d_socket_send_us_sum as f64 / d_socket_send_count as f64) / 1000.0
            } else {
                0.0
            };

            println!(
                "stats frame={}ms tx={}pps {:.1}kbps cap={}chunks/s {}samples/s drop={} q={} avgAbs={:.1} active={:.1}% perf capQ={:.3}ms capSend={:.3}ms pkt={:.3}ms sock={:.3}ms",
                frame_ms, d_packets, kbps, d_chunks, d_samples, d_drops, queue_backlog, avg_abs, active_pct, capq_ms, capsend_ms, pkt_ms, sock_ms
            );

            last_chunks = chunks;
            last_samples = samples;
            last_nonzero_samples = nonzero_samples;
            last_abs_sum = abs_sum;
            last_drops = drops;
            last_capture_queue_us_sum = capture_queue_us_sum;
            last_capture_queue_count = capture_queue_count;
            last_capture_to_send_us_sum = capture_to_send_us_sum;
            last_capture_to_send_count = capture_to_send_count;
            last_packet_build_us_sum = packet_build_us_sum;
            last_packet_build_count = packet_build_count;
            last_socket_send_us_sum = socket_send_us_sum;
            last_socket_send_count = socket_send_count;
            last_packets = packets;
            last_bytes = bytes;
        }
    })
}

fn list_desktop_devices() -> Result<()> {
    wasapi::initialize_mta()
        .ok()
        .context("failed to initialize COM MTA for WASAPI")?;
    let enumerator =
        DeviceEnumerator::new().context("failed to create WASAPI device enumerator")?;
    let default = enumerator
        .get_default_device(&WasapiDirection::Render)
        .ok()
        .and_then(|d| d.get_friendlyname().ok());
    let collection = enumerator
        .get_device_collection(&WasapiDirection::Render)
        .context("failed to get render device collection")?;

    println!("Desktop render devices:");
    for device_result in &collection {
        let device = match device_result {
            Ok(device) => device,
            Err(err) => {
                println!("* <error reading device: {err}>");
                continue;
            }
        };
        let name = device
            .get_friendlyname()
            .unwrap_or_else(|_| "<unknown>".to_string());
        let is_default = default.as_ref().map(|d| d == &name).unwrap_or(false);
        if is_default {
            println!("* {name} [default]");
        } else {
            println!("* {name}");
        }
    }
    Ok(())
}
