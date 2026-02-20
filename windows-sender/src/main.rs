use std::collections::VecDeque;
use std::net::{SocketAddr, UdpSocket};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use clap::Parser;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};
use crossbeam_channel::{bounded, Receiver, Sender};

const MAGIC: [u8; 4] = *b"AUD0";
const VERSION: u8 = 1;
const CODEC_PCM16: u8 = 0;
const HEADER_SIZE: usize = 28;

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

    let (tx, rx) = bounded::<Vec<i16>>(128);
    let stream = build_input_stream(&device, &config, sample_format, tx)?;
    stream.play().context("failed to start input stream")?;

    let socket = UdpSocket::bind("0.0.0.0:0").context("failed to bind UDP sender socket")?;
    socket
        .set_nonblocking(false)
        .context("failed to configure UDP socket")?;

    send_loop(
        &socket,
        target,
        rx,
        sample_rate,
        channels as u8,
        samples_per_channel as u16,
        samples_per_packet,
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
) -> Result<cpal::Stream> {
    let err_fn = |err| eprintln!("cpal stream error: {err}");

    let stream = match sample_format {
        SampleFormat::I16 => device.build_input_stream(
            config,
            move |data: &[i16], _| {
                let _ = tx.try_send(data.to_vec());
            },
            err_fn,
            None,
        )?,
        SampleFormat::U16 => device.build_input_stream(
            config,
            move |data: &[u16], _| {
                let converted = data
                    .iter()
                    .map(|s| (*s as i32 - 32768) as i16)
                    .collect::<Vec<i16>>();
                let _ = tx.try_send(converted);
            },
            err_fn,
            None,
        )?,
        SampleFormat::F32 => device.build_input_stream(
            config,
            move |data: &[f32], _| {
                let converted = data
                    .iter()
                    .map(|s| {
                        let clamped = s.clamp(-1.0, 1.0);
                        (clamped * i16::MAX as f32) as i16
                    })
                    .collect::<Vec<i16>>();
                let _ = tx.try_send(converted);
            },
            err_fn,
            None,
        )?,
        other => bail!("unsupported sample format: {other:?}"),
    };

    Ok(stream)
}
