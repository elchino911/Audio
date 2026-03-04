use std::collections::VecDeque;
use std::io::Read;
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use clap::{Parser, ValueEnum};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, SampleRate, Stream, StreamConfig};

const MAGIC: [u8; 4] = *b"AUD0";
const VERSION: u8 = 1;
const CODEC_PCM16: u8 = 0;
const HEADER_SIZE: usize = 28;

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

#[derive(Parser, Debug)]
#[command(
    author,
    version,
    about = "Low-latency network audio receiver for Windows (Android mic -> virtual input)"
)]
struct Args {
    #[arg(long, default_value = "0.0.0.0")]
    listen_ip: String,
    #[arg(long, default_value_t = 50010)]
    port: u16,
    #[arg(long, value_enum, default_value_t = Transport::Tcp)]
    transport: Transport,
    #[arg(long, default_value_t = 30)]
    target_buffer_ms: u32,
    #[arg(long, default_value_t = 250)]
    max_buffer_ms: u32,
    #[arg(long)]
    output_device: Option<String>,
    #[arg(long, default_value_t = false)]
    list_output_devices: bool,
}

#[derive(Default)]
struct ReceiverStats {
    rx_packets: AtomicU64,
    rx_bytes: AtomicU64,
    parse_errors: AtomicU64,
    format_mismatch: AtomicU64,
    stream_restarts: AtomicU64,
}

struct ParsedPacket {
    sample_rate: u32,
    channels: u8,
    payload: Vec<i16>,
}

#[derive(Default)]
struct AudioBufferState {
    queue: VecDeque<i16>,
    primed: bool,
    input_channels: usize,
    output_channels: usize,
    target_frames: usize,
    max_frames: usize,
    underruns: u64,
    drops: u64,
    meter_sum_sq: u64,
    meter_samples: u64,
    meter_peak: i16,
}

impl AudioBufferState {
    fn set_config(
        &mut self,
        input_channels: usize,
        output_channels: usize,
        target_frames: usize,
        max_frames: usize,
    ) {
        self.queue.clear();
        self.primed = false;
        self.input_channels = input_channels;
        self.output_channels = output_channels;
        self.target_frames = target_frames.max(1);
        self.max_frames = max_frames.max(self.target_frames + 1);
        self.underruns = 0;
        self.drops = 0;
        self.meter_sum_sq = 0;
        self.meter_samples = 0;
        self.meter_peak = 0;
    }

    fn available_frames(&self) -> usize {
        if self.input_channels == 0 {
            0
        } else {
            self.queue.len() / self.input_channels
        }
    }

    fn push_payload(&mut self, payload: &[i16]) {
        if self.input_channels == 0 || payload.is_empty() {
            return;
        }
        let incoming_frames = payload.len() / self.input_channels;
        if incoming_frames == 0 {
            return;
        }

        let max_samples = self.max_frames * self.input_channels;
        while self.queue.len() + payload.len() > max_samples {
            for _ in 0..self.input_channels {
                let _ = self.queue.pop_front();
            }
            self.drops += 1;
        }

        for s in payload.iter().copied() {
            let v = s as i32;
            self.meter_sum_sq = self
                .meter_sum_sq
                .saturating_add((v * v) as u64);
            self.meter_samples = self.meter_samples.saturating_add(1);
            let abs_v = v.abs().min(i16::MAX as i32) as i16;
            if abs_v > self.meter_peak {
                self.meter_peak = abs_v;
            }
        }
        self.queue.extend(payload.iter().copied());
        if !self.primed && self.available_frames() >= self.target_frames {
            self.primed = true;
        }
    }

    fn take_meter(&mut self) -> (u64, u64, i16) {
        let out = (self.meter_sum_sq, self.meter_samples, self.meter_peak);
        self.meter_sum_sq = 0;
        self.meter_samples = 0;
        self.meter_peak = 0;
        out
    }

    fn pop_frame(&mut self) -> Option<[i16; 2]> {
        if self.available_frames() == 0 {
            return None;
        }
        match self.input_channels {
            1 => self.queue.pop_front().map(|m| [m, m]),
            _ => {
                let l = self.queue.pop_front()?;
                let r = self.queue.pop_front().unwrap_or(l);
                Some([l, r])
            }
        }
    }

    fn render_i16(&mut self, out: &mut [i16]) {
        let out_ch = self.output_channels.max(1);
        if out_ch == 0 {
            out.fill(0);
            return;
        }

        let frames = out.len() / out_ch;
        for frame_idx in 0..frames {
            let base = frame_idx * out_ch;

            if !self.primed {
                if self.available_frames() >= self.target_frames {
                    self.primed = true;
                } else {
                    for c in 0..out_ch {
                        out[base + c] = 0;
                    }
                    continue;
                }
            }

            let sample = match self.pop_frame() {
                Some(s) => s,
                None => {
                    self.underruns += 1;
                    self.primed = false;
                    for c in 0..out_ch {
                        out[base + c] = 0;
                    }
                    continue;
                }
            };

            if out_ch == 1 {
                let mono = ((sample[0] as i32 + sample[1] as i32) / 2) as i16;
                out[base] = mono;
            } else {
                out[base] = sample[0];
                out[base + 1] = sample[1];
                for c in 2..out_ch {
                    out[base + c] = sample[1];
                }
            }
        }
    }
}

fn main() -> Result<()> {
    let args = Args::parse();
    if args.list_output_devices {
        list_output_devices()?;
        return Ok(());
    }
    if !(5..=1000).contains(&args.target_buffer_ms) {
        bail!("--target-buffer-ms must be in range [5, 1000]");
    }
    if !(20..=3000).contains(&args.max_buffer_ms) {
        bail!("--max-buffer-ms must be in range [20, 3000]");
    }

    let listen_addr: SocketAddr = format!("{}:{}", args.listen_ip, args.port)
        .parse()
        .context("invalid listen endpoint")?;
    let host = cpal::default_host();
    let device = resolve_output_device(&host, args.output_device.as_deref())?;

    let device_name = device.name().unwrap_or_else(|_| "<unknown>".to_string());
    println!("Output device: {device_name}");
    println!("Listen: {} ({})", listen_addr, args.transport.as_str());
    println!(
        "Buffer target={}ms max={}ms",
        args.target_buffer_ms, args.max_buffer_ms
    );
    println!("Tip: in Teams choose VB-Cable capture endpoint (e.g. 'CABLE Output').");

    let stats = Arc::new(ReceiverStats::default());
    let buffer = Arc::new(Mutex::new(AudioBufferState::default()));
    let stream_holder: Arc<Mutex<Option<Stream>>> = Arc::new(Mutex::new(None));
    let expected_format = Arc::new(Mutex::new(None::<(u32, u8)>));

    let _stats_thread = spawn_stats_thread(Arc::clone(&stats), Arc::clone(&buffer));

    let mut handle_packet = {
        let device = device;
        let stats = Arc::clone(&stats);
        let buffer = Arc::clone(&buffer);
        let stream_holder = Arc::clone(&stream_holder);
        let expected_format = Arc::clone(&expected_format);

        move |packet: ParsedPacket| -> Result<()> {
            let mut expected = expected_format.lock().expect("format mutex poisoned");
            if expected.is_none() {
                let stream = start_output_stream(
                    &device,
                    packet.sample_rate,
                    packet.channels as usize,
                    args.target_buffer_ms,
                    args.max_buffer_ms,
                    Arc::clone(&buffer),
                )?;
                *stream_holder.lock().expect("stream mutex poisoned") = Some(stream);
                *expected = Some((packet.sample_rate, packet.channels));
                stats.stream_restarts.fetch_add(1, Ordering::Relaxed);
            } else if expected
                .as_ref()
                .map(|(sr, ch)| *sr != packet.sample_rate || *ch != packet.channels)
                .unwrap_or(false)
            {
                stats.format_mismatch.fetch_add(1, Ordering::Relaxed);
                return Ok(());
            }

            drop(expected);
            let mut state = buffer.lock().expect("buffer mutex poisoned");
            state.push_payload(&packet.payload);
            Ok(())
        }
    };

    match args.transport {
        Transport::Udp => receive_udp(listen_addr, Arc::clone(&stats), &mut handle_packet),
        Transport::Tcp => receive_tcp(listen_addr, Arc::clone(&stats), &mut handle_packet),
    }
}

fn resolve_output_device(host: &cpal::Host, output_device_name: Option<&str>) -> Result<cpal::Device> {
    if let Some(name) = output_device_name {
        for device in host
            .output_devices()
            .context("failed to enumerate output devices")?
        {
            let candidate = device.name().unwrap_or_default();
            if candidate == name {
                return Ok(device);
            }
        }
        bail!("output device not found: {name}");
    }
    host.default_output_device()
        .context("no default output device found")
}

fn list_output_devices() -> Result<()> {
    let host = cpal::default_host();
    let default_name = host
        .default_output_device()
        .and_then(|d| d.name().ok())
        .unwrap_or_default();
    println!("Output devices:");
    for device in host
        .output_devices()
        .context("failed to enumerate output devices")?
    {
        let name = device.name().unwrap_or_else(|_| "<unknown>".to_string());
        if name == default_name {
            println!("* {name} [default]");
        } else {
            println!("* {name}");
        }
    }
    Ok(())
}

fn pick_config(
    device: &cpal::Device,
    sample_rate: u32,
    input_channels: usize,
) -> Result<(StreamConfig, SampleFormat)> {
    let mut selected: Option<(StreamConfig, SampleFormat)> = None;
    let mut fallback: Option<(StreamConfig, SampleFormat)> = None;

    let ranges = device
        .supported_output_configs()
        .context("failed to query supported output configs")?;

    for range in ranges {
        let ch = range.channels() as usize;
        if !(range.min_sample_rate().0..=range.max_sample_rate().0).contains(&sample_rate) {
            continue;
        }

        let config = StreamConfig {
            channels: range.channels(),
            sample_rate: SampleRate(sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };
        if fallback.is_none() {
            fallback = Some((config.clone(), range.sample_format()));
        }
        if ch == input_channels {
            selected = Some((config, range.sample_format()));
            break;
        }
    }

    if let Some(sel) = selected {
        return Ok(sel);
    }
    if let Some(fb) = fallback {
        return Ok(fb);
    }

    let default_cfg = device
        .default_output_config()
        .context("failed to read default output config")?;
    Ok((
        StreamConfig {
            channels: default_cfg.channels(),
            sample_rate: default_cfg.sample_rate(),
            buffer_size: cpal::BufferSize::Default,
        },
        default_cfg.sample_format(),
    ))
}

fn start_output_stream(
    device: &cpal::Device,
    sample_rate: u32,
    input_channels: usize,
    target_buffer_ms: u32,
    max_buffer_ms: u32,
    buffer: Arc<Mutex<AudioBufferState>>,
) -> Result<Stream> {
    let (config, sample_format) = pick_config(device, sample_rate, input_channels)?;
    let out_channels = config.channels as usize;
    {
        let mut state = buffer.lock().expect("buffer mutex poisoned");
        let target_frames = ((sample_rate as u64 * target_buffer_ms as u64) / 1000) as usize;
        let max_frames = ((sample_rate as u64 * max_buffer_ms as u64) / 1000) as usize;
        state.set_config(
            input_channels.max(1),
            out_channels.max(1),
            target_frames.max(1),
            max_frames.max(2),
        );
    }

    let err_fn = |err| eprintln!("output stream error: {err}");
    let stream = match sample_format {
        SampleFormat::I16 => {
            let buffer = Arc::clone(&buffer);
            device.build_output_stream(
                &config,
                move |out: &mut [i16], _| {
                    let mut state = buffer.lock().expect("buffer mutex poisoned");
                    state.render_i16(out);
                },
                err_fn,
                None,
            )?
        }
        SampleFormat::U16 => {
            let buffer = Arc::clone(&buffer);
            device.build_output_stream(
                &config,
                move |out: &mut [u16], _| {
                    let mut scratch = vec![0i16; out.len()];
                    {
                        let mut state = buffer.lock().expect("buffer mutex poisoned");
                        state.render_i16(&mut scratch);
                    }
                    for (dst, src) in out.iter_mut().zip(scratch.iter()) {
                        *dst = (*src as i32 + 32768) as u16;
                    }
                },
                err_fn,
                None,
            )?
        }
        SampleFormat::F32 => {
            let buffer = Arc::clone(&buffer);
            device.build_output_stream(
                &config,
                move |out: &mut [f32], _| {
                    let mut scratch = vec![0i16; out.len()];
                    {
                        let mut state = buffer.lock().expect("buffer mutex poisoned");
                        state.render_i16(&mut scratch);
                    }
                    for (dst, src) in out.iter_mut().zip(scratch.iter()) {
                        *dst = *src as f32 / i16::MAX as f32;
                    }
                },
                err_fn,
                None,
            )?
        }
        SampleFormat::U8 => {
            let buffer = Arc::clone(&buffer);
            device.build_output_stream(
                &config,
                move |out: &mut [u8], _| {
                    let mut scratch = vec![0i16; out.len()];
                    {
                        let mut state = buffer.lock().expect("buffer mutex poisoned");
                        state.render_i16(&mut scratch);
                    }
                    for (dst, src) in out.iter_mut().zip(scratch.iter()) {
                        let s = ((*src as i32) / 256).clamp(-128, 127);
                        *dst = (s + 128) as u8;
                    }
                },
                err_fn,
                None,
            )?
        }
        other => bail!("unsupported output sample format: {other:?}"),
    };

    stream.play().context("failed to start output stream")?;
    println!(
        "Output stream: {} Hz, {} ch, {:?}",
        config.sample_rate.0, config.channels, sample_format
    );
    Ok(stream)
}

fn receive_udp<F>(listen_addr: SocketAddr, stats: Arc<ReceiverStats>, on_packet: &mut F) -> Result<()>
where
    F: FnMut(ParsedPacket) -> Result<()>,
{
    let socket = UdpSocket::bind(listen_addr).context("failed to bind UDP socket")?;
    socket
        .set_nonblocking(false)
        .context("failed to configure UDP socket")?;
    let mut buf = vec![0u8; 8192];
    loop {
        let (len, _src) = socket.recv_from(&mut buf).context("udp recv failed")?;
        stats.rx_packets.fetch_add(1, Ordering::Relaxed);
        stats.rx_bytes.fetch_add(len as u64, Ordering::Relaxed);
        match parse_packet(&buf[..len]) {
            Some(packet) => on_packet(packet)?,
            None => {
                stats.parse_errors.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

fn receive_tcp<F>(listen_addr: SocketAddr, stats: Arc<ReceiverStats>, on_packet: &mut F) -> Result<()>
where
    F: FnMut(ParsedPacket) -> Result<()>,
{
    let listener = TcpListener::bind(listen_addr).context("failed to bind TCP listener")?;
    loop {
        let (mut stream, peer) = listener.accept().context("tcp accept failed")?;
        stream
            .set_nodelay(true)
            .context("failed to set TCP_NODELAY")?;
        println!("TCP sender connected: {peer}");
        if let Err(err) = read_tcp_stream(&mut stream, Arc::clone(&stats), on_packet) {
            eprintln!("tcp stream ended: {err:#}");
        }
        println!("TCP sender disconnected: {peer}");
    }
}

fn read_tcp_stream<F>(
    stream: &mut TcpStream,
    stats: Arc<ReceiverStats>,
    on_packet: &mut F,
) -> Result<()>
where
    F: FnMut(ParsedPacket) -> Result<()>,
{
    loop {
        let mut len_buf = [0u8; 2];
        stream
            .read_exact(&mut len_buf)
            .context("tcp read length failed")?;
        let len = u16::from_le_bytes(len_buf) as usize;
        if len == 0 || len > 65535 {
            stats.parse_errors.fetch_add(1, Ordering::Relaxed);
            bail!("invalid tcp payload length: {len}");
        }
        let mut packet_buf = vec![0u8; len];
        stream
            .read_exact(&mut packet_buf)
            .context("tcp read payload failed")?;
        stats.rx_packets.fetch_add(1, Ordering::Relaxed);
        stats
            .rx_bytes
            .fetch_add((len + 2) as u64, Ordering::Relaxed);
        match parse_packet(&packet_buf) {
            Some(packet) => on_packet(packet)?,
            None => {
                stats.parse_errors.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

fn parse_packet(data: &[u8]) -> Option<ParsedPacket> {
    if data.len() < HEADER_SIZE {
        return None;
    }
    if data[0..4] != MAGIC {
        return None;
    }

    let version = data[4];
    let codec = data[5];
    let channels = data[6];
    if version != VERSION || codec != CODEC_PCM16 || !(1..=2).contains(&channels) {
        return None;
    }

    let sample_rate = u32::from_le_bytes([data[8], data[9], data[10], data[11]]);
    let _seq = u32::from_le_bytes([data[12], data[13], data[14], data[15]]);
    let _send_time_us = u64::from_le_bytes([
        data[16], data[17], data[18], data[19], data[20], data[21], data[22], data[23],
    ]);
    let samples_per_channel = u16::from_le_bytes([data[24], data[25]]) as usize;
    let payload_len = u16::from_le_bytes([data[26], data[27]]) as usize;
    if payload_len == 0 || payload_len % 2 != 0 || HEADER_SIZE + payload_len > data.len() {
        return None;
    }

    let expected_samples = samples_per_channel * channels as usize;
    if expected_samples * 2 != payload_len {
        return None;
    }

    let mut payload = Vec::<i16>::with_capacity(expected_samples);
    let payload_bytes = &data[HEADER_SIZE..HEADER_SIZE + payload_len];
    for chunk in payload_bytes.chunks_exact(2) {
        payload.push(i16::from_le_bytes([chunk[0], chunk[1]]));
    }

    Some(ParsedPacket {
        sample_rate,
        channels,
        payload,
    })
}

fn spawn_stats_thread(
    stats: Arc<ReceiverStats>,
    buffer: Arc<Mutex<AudioBufferState>>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut last_packets = 0u64;
        let mut last_bytes = 0u64;
        let mut last_parse = 0u64;
        let mut last_mismatch = 0u64;
        let mut last_restarts = 0u64;
        let mut last_underruns = 0u64;
        let mut last_drops = 0u64;
        loop {
            thread::sleep(Duration::from_secs(1));
            let packets = stats.rx_packets.load(Ordering::Relaxed);
            let bytes = stats.rx_bytes.load(Ordering::Relaxed);
            let parse = stats.parse_errors.load(Ordering::Relaxed);
            let mismatch = stats.format_mismatch.load(Ordering::Relaxed);
            let restarts = stats.stream_restarts.load(Ordering::Relaxed);

            let (buffer_frames, target_frames, underruns, drops, meter_sum_sq, meter_samples, meter_peak) = {
                let mut state = buffer.lock().expect("buffer mutex poisoned");
                // Pull meter from the same critical section so level stats match this 1s window.
                let (sum_sq, samples, peak) = state.take_meter();
                (
                    state.available_frames(),
                    state.target_frames,
                    state.underruns,
                    state.drops,
                    sum_sq,
                    samples,
                    peak,
                )
            };

            let d_packets = packets.saturating_sub(last_packets);
            let d_bytes = bytes.saturating_sub(last_bytes);
            let d_parse = parse.saturating_sub(last_parse);
            let d_mismatch = mismatch.saturating_sub(last_mismatch);
            let d_restarts = restarts.saturating_sub(last_restarts);
            let d_underruns = underruns.saturating_sub(last_underruns);
            let d_drops = drops.saturating_sub(last_drops);
            let kbps = (d_bytes as f64 * 8.0) / 1000.0;
            let rms_norm = if meter_samples > 0 {
                ((meter_sum_sq as f64 / meter_samples as f64).sqrt()) / i16::MAX as f64
            } else {
                0.0
            };
            let rms_db = if rms_norm > 1e-9 {
                20.0 * rms_norm.log10()
            } else {
                -120.0
            };
            let peak_norm = meter_peak as f64 / i16::MAX as f64;

            println!(
                "stats rx={}pps {:.1}kbps parseErr={} fmtErr={} streamInit={} bufferFrames={} target={} underrun={} drop={} rmsDb={:.1} peak={:.3}",
                d_packets,
                kbps,
                d_parse,
                d_mismatch,
                d_restarts,
                buffer_frames,
                target_frames,
                d_underruns,
                d_drops,
                rms_db,
                peak_norm
            );

            last_packets = packets;
            last_bytes = bytes;
            last_parse = parse;
            last_mismatch = mismatch;
            last_restarts = restarts;
            last_underruns = underruns;
            last_drops = drops;
        }
    })
}
