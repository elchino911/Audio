use std::collections::VecDeque;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use clap::Parser;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};
use crossbeam_channel::{bounded, Receiver, Sender, TrySendError};

const MAGIC: [u8; 4] = *b"AUD0";
const VERSION: u8 = 1;
const CODEC_PCM16: u8 = 0;
const HEADER_SIZE: usize = 28;

#[derive(Default)]
struct SenderStats {
    captured_chunks: AtomicU64,
    captured_samples: AtomicU64,
    capture_drops: AtomicU64,
    sent_packets: AtomicU64,
    sent_bytes: AtomicU64,
}

#[derive(Parser, Debug)]
#[command(author, version, about = "Low-latency UDP audio sender (Windows -> Android)")]
struct Args {
    #[arg(long)]
    target_ip: String,
    #[arg(long, default_value_t = 50000)]
    port: u16,
    #[arg(long, default_value_t = 5)]
    frame_ms: u32,
}

fn main() -> Result<()> {
    let args = Args::parse();
    if !(1..=20).contains(&args.frame_ms) {
        bail!("--frame-ms must be in range [1, 20]");
    }

    let target: SocketAddr = format!("{}:{}", args.target_ip, args.port)
        .parse()
        .context("invalid target endpoint")?;

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
    let samples_per_channel = ((sample_rate as u64 * args.frame_ms as u64) / 1000) as usize;
    let samples_per_packet = samples_per_channel * channels;

    println!("Input device: {device_name}");
    println!(
        "Config: {} Hz, {} ch, {:?}, frame={} ms ({} samples/ch)",
        sample_rate, channels, sample_format, args.frame_ms, samples_per_channel
    );
    println!("Target: {target}");
    println!("Stats: one line per second (pps/kbps/drops/backlog)");

    let (tx, rx) = bounded::<Vec<i16>>(512);
    let stats = Arc::new(SenderStats::default());
    let stream = build_input_stream(&device, &config, sample_format, tx, Arc::clone(&stats))?;
    stream.play().context("failed to start input stream")?;

    let socket = UdpSocket::bind("0.0.0.0:0").context("failed to bind UDP sender socket")?;
    socket
        .set_nonblocking(false)
        .context("failed to configure UDP socket")?;
    let _stats_thread = spawn_stats_logger(Arc::clone(&stats), rx.clone(), args.frame_ms);

    send_loop(
        &socket,
        target,
        rx,
        sample_rate,
        channels as u8,
        samples_per_channel as u16,
        samples_per_packet,
        stats,
    )
}

fn send_loop(
    socket: &UdpSocket,
    target: SocketAddr,
    rx: Receiver<Vec<i16>>,
    sample_rate: u32,
    channels: u8,
    samples_per_channel: u16,
    samples_per_packet: usize,
    stats: Arc<SenderStats>,
) -> Result<()> {
    let mut seq: u32 = 0;
    let mut acc = VecDeque::<i16>::with_capacity(samples_per_packet * 4);

    loop {
        let chunk = rx.recv().context("audio capture channel closed")?;
        for s in chunk {
            acc.push_back(s);
        }

        while acc.len() >= samples_per_packet {
            let mut payload = vec![0u8; samples_per_packet * 2];
            for i in 0..samples_per_packet {
                let sample = acc.pop_front().unwrap_or(0);
                let bytes = sample.to_le_bytes();
                payload[i * 2] = bytes[0];
                payload[i * 2 + 1] = bytes[1];
            }

            let packet = build_packet(
                seq,
                sample_rate,
                channels,
                samples_per_channel,
                &payload,
            )?;
            socket
                .send_to(&packet, target)
                .with_context(|| format!("failed to send UDP packet seq={seq}"))?;
            stats.sent_packets.fetch_add(1, Ordering::Relaxed);
            stats
                .sent_bytes
                .fetch_add(packet.len() as u64, Ordering::Relaxed);
            seq = seq.wrapping_add(1);
        }
    }
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
    tx: Sender<Vec<i16>>,
    stats: Arc<SenderStats>,
) -> Result<cpal::Stream> {
    let err_fn = |err| eprintln!("cpal stream error: {err}");

    let stream = match sample_format {
        SampleFormat::I16 => device.build_input_stream(
            config,
            move |data: &[i16], _| {
                stats
                    .captured_samples
                    .fetch_add(data.len() as u64, Ordering::Relaxed);
                match tx.try_send(data.to_vec()) {
                    Ok(_) => {
                        stats.captured_chunks.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(TrySendError::Full(_)) => {
                        stats.capture_drops.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(TrySendError::Disconnected(_)) => {}
                }
            },
            err_fn,
            None,
        )?,
        SampleFormat::U16 => device.build_input_stream(
            config,
            move |data: &[u16], _| {
                stats
                    .captured_samples
                    .fetch_add(data.len() as u64, Ordering::Relaxed);
                let converted = data
                    .iter()
                    .map(|s| (*s as i32 - 32768) as i16)
                    .collect::<Vec<i16>>();
                match tx.try_send(converted) {
                    Ok(_) => {
                        stats.captured_chunks.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(TrySendError::Full(_)) => {
                        stats.capture_drops.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(TrySendError::Disconnected(_)) => {}
                }
            },
            err_fn,
            None,
        )?,
        SampleFormat::F32 => device.build_input_stream(
            config,
            move |data: &[f32], _| {
                stats
                    .captured_samples
                    .fetch_add(data.len() as u64, Ordering::Relaxed);
                let converted = data
                    .iter()
                    .map(|s| {
                        let clamped = s.clamp(-1.0, 1.0);
                        (clamped * i16::MAX as f32) as i16
                    })
                    .collect::<Vec<i16>>();
                match tx.try_send(converted) {
                    Ok(_) => {
                        stats.captured_chunks.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(TrySendError::Full(_)) => {
                        stats.capture_drops.fetch_add(1, Ordering::Relaxed);
                    }
                    Err(TrySendError::Disconnected(_)) => {}
                }
            },
            err_fn,
            None,
        )?,
        other => bail!("unsupported sample format: {other:?}"),
    };

    Ok(stream)
}

fn spawn_stats_logger(
    stats: Arc<SenderStats>,
    rx: Receiver<Vec<i16>>,
    frame_ms: u32,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut last_chunks = 0_u64;
        let mut last_samples = 0_u64;
        let mut last_drops = 0_u64;
        let mut last_packets = 0_u64;
        let mut last_bytes = 0_u64;

        loop {
            thread::sleep(Duration::from_secs(1));
            let chunks = stats.captured_chunks.load(Ordering::Relaxed);
            let samples = stats.captured_samples.load(Ordering::Relaxed);
            let drops = stats.capture_drops.load(Ordering::Relaxed);
            let packets = stats.sent_packets.load(Ordering::Relaxed);
            let bytes = stats.sent_bytes.load(Ordering::Relaxed);

            let d_chunks = chunks.saturating_sub(last_chunks);
            let d_samples = samples.saturating_sub(last_samples);
            let d_drops = drops.saturating_sub(last_drops);
            let d_packets = packets.saturating_sub(last_packets);
            let d_bytes = bytes.saturating_sub(last_bytes);
            let kbps = (d_bytes as f64 * 8.0) / 1000.0;
            let queue_backlog = rx.len();

            println!(
                "stats frame={}ms tx={}pps {:.1}kbps cap={}chunks/s {}samples/s drop={} q={}",
                frame_ms, d_packets, kbps, d_chunks, d_samples, d_drops, queue_backlog
            );

            last_chunks = chunks;
            last_samples = samples;
            last_drops = drops;
            last_packets = packets;
            last_bytes = bytes;
        }
    })
}
