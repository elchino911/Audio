package com.audiolink.receiver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.BufferedInputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

class UdpAudioService : Service() {
    private var udpSocket: DatagramSocket? = null
    private var tcpServerSocket: ServerSocket? = null
    private var tcpClientSocket: Socket? = null
    private var receiverThread: Thread? = null
    private var playerThread: Thread? = null
    private var statsThread: Thread? = null
    private var audioTrack: AudioTrack? = null
    private var jitterBuffer: JitterBuffer? = null
    private var expectedFrameSamples: Int = 0
    private var silenceFrame: ShortArray = shortArrayOf()
    private var frameMs: Int = 5
    private var adaptiveBaseTargetFrames: Int = 0
    private var adaptiveTargetFrames: Int = 0
    private var adaptiveMinTargetFrames: Int = 2
    private var adaptiveMaxTargetFrames: Int = 2
    private var adaptiveScoreEma: Double = 100.0
    private var adaptiveBadStreak: Int = 0
    private var adaptiveGoodStreak: Int = 0
    private var adaptiveZeroBufferStreak: Int = 0
    private var adaptiveCooldownSec: Int = 0
    private var adaptiveLastReason: String = "init"

    @Volatile
    private var running = false

    private val rxPackets = AtomicLong(0)
    private val rxBytes = AtomicLong(0)
    private val parseErrors = AtomicLong(0)
    private val payloadMismatch = AtomicLong(0)
    private val playoutUnderruns = AtomicLong(0)
    private val netDelayUsSum = AtomicLong(0)
    private val netDelaySamples = AtomicLong(0)
    private val netDelayUsMin = AtomicLong(Long.MAX_VALUE)
    private val netPathUsSum = AtomicLong(0)
    private val netPathSamples = AtomicLong(0)
    private val netJitterUsSum = AtomicLong(0)
    private val netJitterSamples = AtomicLong(0)
    private val lastNetAgeUs = AtomicLong(-1)
    private val decodeUsSum = AtomicLong(0)
    private val decodeSamples = AtomicLong(0)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val port = intent.getIntExtra(EXTRA_PORT, 50000)
                val jitterMs = intent.getIntExtra(EXTRA_JITTER_MS, 20)
                val transport = normalizeTransport(intent.getStringExtra(EXTRA_TRANSPORT))
                startStreaming(port, jitterMs, transport)
            }

            ACTION_STOP -> stopStreaming()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopStreaming()
        super.onDestroy()
    }

    private fun startStreaming(port: Int, jitterMs: Int, transport: String) {
        if (running) return

        resetStats()
        createNotificationChannel()
        startForeground(
            NOTIF_ID,
            buildNotification("Listening on ${transport.uppercase(Locale.US)} $port")
        )

        running = true
        receiverThread = thread(name = "udp-receiver", isDaemon = true) {
            when (transport) {
                TRANSPORT_TCP -> receiveTcpLoop(port, jitterMs)
                else -> receiveUdpLoop(port, jitterMs)
            }
        }
        statsThread = thread(name = "udp-stats", isDaemon = true) {
            statsLoop()
        }
    }

    private fun stopStreaming() {
        running = false
        udpSocket?.close()
        udpSocket = null
        tcpClientSocket?.close()
        tcpClientSocket = null
        tcpServerSocket?.close()
        tcpServerSocket = null

        receiverThread?.interrupt()
        receiverThread = null

        playerThread?.interrupt()
        playerThread = null

        statsThread?.interrupt()
        statsThread = null

        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null

        jitterBuffer = null
        expectedFrameSamples = 0
        silenceFrame = shortArrayOf()
        frameMs = 5
        resetAdaptiveController()

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun receiveUdpLoop(port: Int, jitterMs: Int) {
        try {
            DatagramSocket(port).use { sock ->
                udpSocket = sock
                sock.soTimeout = 500
                sock.receiveBufferSize = 256 * 1024
                val packetBuf = ByteArray(8192)

                while (running) {
                    try {
                        val datagram = DatagramPacket(packetBuf, packetBuf.size)
                        sock.receive(datagram)
                        processPacketBytes(datagram.data, datagram.length, jitterMs, 0)
                    } catch (_: SocketTimeoutException) {
                        // Keep service alive while waiting for packets.
                    } catch (e: Exception) {
                        Log.e(TAG, "receive error", e)
                        parseErrors.incrementAndGet()
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "receiver loop failed", e)
        } finally {
            udpSocket = null
            stopStreaming()
        }
    }

    private fun receiveTcpLoop(port: Int, jitterMs: Int) {
        try {
            ServerSocket(port).use { server ->
                tcpServerSocket = server
                server.reuseAddress = true
                server.soTimeout = 800
                Log.i(TAG, "TCP receiver listening on $port")

                while (running) {
                    var client: Socket? = null
                    try {
                        client = server.accept()
                        tcpClientSocket = client
                        client.tcpNoDelay = true
                        client.soTimeout = 800
                        Log.i(
                            TAG,
                            "TCP sender connected from ${client.inetAddress?.hostAddress}:${client.port}"
                        )
                        readTcpClientLoop(client, jitterMs)
                    } catch (_: SocketTimeoutException) {
                        // Keep service alive while waiting for a sender.
                    } catch (e: Exception) {
                        if (running) {
                            Log.e(TAG, "tcp accept/read error", e)
                            parseErrors.incrementAndGet()
                        }
                    } finally {
                        try {
                            client?.close()
                        } catch (_: Exception) {
                        }
                        tcpClientSocket = null
                    }
                }
            }
        } catch (e: Exception) {
            if (running) {
                Log.e(TAG, "tcp receiver loop failed", e)
            }
        } finally {
            tcpServerSocket = null
            stopStreaming()
        }
    }

    private fun readTcpClientLoop(client: Socket, jitterMs: Int) {
        val input = BufferedInputStream(client.getInputStream())
        val lenBuf = ByteArray(2)
        var packetBuf = ByteArray(8192)

        while (running) {
            if (!readFully(input, lenBuf, 2)) {
                break
            }

            val packetLen = (lenBuf[0].toInt() and 0xFF) or ((lenBuf[1].toInt() and 0xFF) shl 8)
            if (packetLen <= 0 || packetLen > 65535) {
                parseErrors.incrementAndGet()
                Log.w(TAG, "invalid tcp packet length: $packetLen")
                break
            }
            if (packetLen > packetBuf.size) {
                packetBuf = ByteArray(packetLen)
            }
            if (!readFully(input, packetBuf, packetLen)) {
                break
            }

            processPacketBytes(packetBuf, packetLen, jitterMs, 2)
        }
    }

    private fun readFully(input: BufferedInputStream, out: ByteArray, len: Int): Boolean {
        var offset = 0
        while (offset < len && running) {
            try {
                val n = input.read(out, offset, len - offset)
                if (n < 0) {
                    return false
                }
                if (n == 0) {
                    continue
                }
                offset += n
            } catch (_: SocketTimeoutException) {
                if (!running) {
                    return false
                }
            }
        }
        return offset == len
    }

    private fun processPacketBytes(
        data: ByteArray,
        packetLen: Int,
        jitterMs: Int,
        wireOverheadBytes: Int
    ) {
        rxPackets.incrementAndGet()
        rxBytes.addAndGet((packetLen + wireOverheadBytes).toLong())

        val parseStartNs = System.nanoTime()
        val packet = AudioPacket.parse(data, packetLen)
        val parseUs = (System.nanoTime() - parseStartNs) / 1000L
        if (packet == null) {
            parseErrors.incrementAndGet()
            return
        }
        decodeUsSum.addAndGet(parseUs)
        decodeSamples.incrementAndGet()
        updateEstimatedNetDelay(packet.sendTimeUs)
        if (audioTrack == null) {
            initAudio(packet, jitterMs)
        }

        if (packet.payload.size == expectedFrameSamples) {
            jitterBuffer?.push(packet.seq, packet.payload)
        } else {
            payloadMismatch.incrementAndGet()
        }
    }

    private fun initAudio(packet: AudioPacket, jitterMs: Int) {
        val channelsMask = if (packet.channels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }

        expectedFrameSamples = packet.samplesPerChannel * packet.channels
        if (expectedFrameSamples <= 0) return
        silenceFrame = ShortArray(expectedFrameSamples)

        frameMs = max(1, (packet.samplesPerChannel * 1000) / packet.sampleRate)
        val targetFrames = max(2, jitterMs / frameMs)
        adaptiveBaseTargetFrames = targetFrames
        adaptiveMinTargetFrames = max(2, targetFrames - 1)
        adaptiveMaxTargetFrames = max(
            adaptiveMinTargetFrames + 2,
            min(32, targetFrames + 8)
        )
        adaptiveTargetFrames = targetFrames.coerceIn(adaptiveMinTargetFrames, adaptiveMaxTargetFrames)
        adaptiveScoreEma = 100.0
        adaptiveBadStreak = 0
        adaptiveGoodStreak = 0
        adaptiveZeroBufferStreak = 0
        adaptiveCooldownSec = 0
        adaptiveLastReason = "start"
        val maxFrames = max(targetFrames + 16, adaptiveMaxTargetFrames + 4)
        jitterBuffer = JitterBuffer(
            initialTargetFrames = adaptiveTargetFrames,
            maxFrames = maxFrames
        )

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(packet.sampleRate)
            .setChannelMask(channelsMask)
            .build()

        val minBuffer = AudioTrack.getMinBufferSize(
            packet.sampleRate,
            channelsMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val desiredBuffer = expectedFrameSamples * 2 * (maxFrames + 2)
        val bufferBytes = max(minBuffer, desiredBuffer)

        audioTrack = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
            format,
            bufferBytes,
            AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE
        )
        audioTrack?.play()

        playerThread = thread(name = "audio-player", isDaemon = true) {
            playLoop()
        }
        Log.i(
            TAG,
            "audio initialized: ${packet.sampleRate}Hz ch=${packet.channels} frame=${packet.samplesPerChannel} frameMs=$frameMs targetFrames=$targetFrames autoJitter=${adaptiveMinTargetFrames}..${adaptiveMaxTargetFrames}"
        )
    }

    private fun playLoop() {
        val popTimeoutMs = max(10, frameMs * 2).toLong()
        while (running) {
            val frame = jitterBuffer?.pop(popTimeoutMs)
            val safeFrame = if (frame == null) {
                playoutUnderruns.incrementAndGet()
                silenceFrame
            } else if (frame.size == expectedFrameSamples) {
                frame
            } else {
                payloadMismatch.incrementAndGet()
                silenceFrame
            }
            audioTrack?.write(safeFrame, 0, safeFrame.size, AudioTrack.WRITE_BLOCKING)
        }
    }

    private fun statsLoop() {
        var lastRxPackets = 0L
        var lastRxBytes = 0L
        var lastParseErrors = 0L
        var lastPayloadMismatch = 0L
        var lastUnderruns = 0L
        var lastJitter = JitterSnapshot(
            bufferedFrames = 0,
            targetFrames = 0,
            maxFrames = 0,
            pushed = 0,
            played = 0,
            missing = 0,
            late = 0,
            overflowDropped = 0
        )

        while (running) {
            try {
                Thread.sleep(1000)
            } catch (_: InterruptedException) {
                break
            }

            val currRxPackets = rxPackets.get()
            val currRxBytes = rxBytes.get()
            val currParseErrors = parseErrors.get()
            val currPayloadMismatch = payloadMismatch.get()
            val currUnderruns = playoutUnderruns.get()
            val jitter = jitterBuffer?.snapshot()

            val dPackets = currRxPackets - lastRxPackets
            val dBytes = currRxBytes - lastRxBytes
            val dParseErrors = currParseErrors - lastParseErrors
            val dPayloadMismatch = currPayloadMismatch - lastPayloadMismatch
            val dUnderruns = currUnderruns - lastUnderruns

            val kbps = (dBytes * 8.0) / 1000.0
            val netPerf = sampleNetworkPerf()
            val avgDelayMs = netPerf.avgAgeMs
            val delayText = if (avgDelayMs >= 0.0) {
                String.format(Locale.US, "%.1f", avgDelayMs)
            } else {
                "n/a"
            }
            val avgDecodeMs = averageDecodeMs()
            val decodeText = if (avgDecodeMs >= 0.0) {
                String.format(Locale.US, "%.3f", avgDecodeMs)
            } else {
                "n/a"
            }
            val netPathText = if (netPerf.avgPathMs >= 0.0) {
                String.format(Locale.US, "%.1f", netPerf.avgPathMs)
            } else {
                "n/a"
            }
            val netJitterText = if (netPerf.avgJitterMs >= 0.0) {
                String.format(Locale.US, "%.1f", netPerf.avgJitterMs)
            } else {
                "n/a"
            }

            val missingDelta = if (jitter != null) jitter.missing - lastJitter.missing else 0L
            val lateDelta = if (jitter != null) jitter.late - lastJitter.late else 0L
            val overflowDelta = if (jitter != null) jitter.overflowDropped - lastJitter.overflowDropped else 0L
            val bufferedFrames = jitter?.bufferedFrames ?: 0
            val targetFramesNow = jitter?.targetFrames ?: adaptiveTargetFrames
            val bufferedMs = bufferedFrames * frameMs
            val (windowScore, adjustInfo, effectiveTargetFrames) = if (jitter != null && adaptiveTargetFrames > 0) {
                val score = computeWindowScore(
                    underrunDelta = dUnderruns,
                    missingDelta = missingDelta,
                    overflowDelta = overflowDelta,
                    parseErrDelta = dParseErrors,
                    payloadErrDelta = dPayloadMismatch,
                    bufferedFrames = bufferedFrames,
                    targetFrames = targetFramesNow
                )
                adaptiveScoreEma = (adaptiveScoreEma * 0.85) + (score * 0.15)
                val adjust = maybeAdjustAutoJitter(
                    jitter = jitter,
                    underrunDelta = dUnderruns,
                    missingDelta = missingDelta,
                    overflowDelta = overflowDelta,
                    parseErrDelta = dParseErrors,
                    payloadErrDelta = dPayloadMismatch,
                    bufferedFrames = bufferedFrames
                )
                Triple(score, adjust, adjust?.targetFrames ?: targetFramesNow)
            } else {
                adaptiveScoreEma = 100.0
                Triple(100.0, null, targetFramesNow)
            }
            val autoReason = adjustInfo?.reason ?: "hold"
            val effectiveTargetMs = effectiveTargetFrames * frameMs
            val netForE2eMs = when {
                netPerf.avgPathMs >= 0.0 -> netPerf.avgPathMs
                netPerf.avgAgeMs >= 0.0 -> netPerf.avgAgeMs
                else -> -1.0
            }
            val e2eMs = if (netForE2eMs >= 0.0) {
                netForE2eMs + max(0.0, avgDecodeMs) + bufferedMs.toDouble()
            } else {
                -1.0
            }
            val e2eText = if (e2eMs >= 0.0) {
                String.format(Locale.US, "%.1f", e2eMs)
            } else {
                "n/a"
            }

            Log.i(
                TAG,
                String.format(
                    Locale.US,
                    "stats rx=%d pps %.1f kbps delay=%s ms buffer=%d ms loss=%d late=%d over=%d underrun=%d parseErr=%d payloadErr=%d",
                    dPackets,
                    kbps,
                    delayText,
                    bufferedMs,
                    missingDelta,
                    lateDelta,
                    overflowDelta,
                    dUnderruns,
                    dParseErrors,
                    dPayloadMismatch
                )
            )
            Log.i(
                TAG,
                String.format(
                    Locale.US,
                    "autojitter target=%d (%dms) base=%d (%dms) score=%.1f win=%.1f reason=%s",
                    effectiveTargetFrames,
                    effectiveTargetMs,
                    adaptiveBaseTargetFrames,
                    adaptiveBaseTargetFrames * frameMs,
                    adaptiveScoreEma,
                    windowScore,
                    autoReason
                )
            )
            Log.i(
                TAG,
                String.format(
                    Locale.US,
                    "perf netAge=%sms netPath=%sms netJit=%sms decode=%sms playout=%.1fms e2e=%sms",
                    delayText,
                    netPathText,
                    netJitterText,
                    decodeText,
                    bufferedMs.toDouble(),
                    e2eText
                )
            )

            lastRxPackets = currRxPackets
            lastRxBytes = currRxBytes
            lastParseErrors = currParseErrors
            lastPayloadMismatch = currPayloadMismatch
            lastUnderruns = currUnderruns
            if (jitter != null) {
                lastJitter = jitter
            }
        }
    }

    private fun resetStats() {
        rxPackets.set(0)
        rxBytes.set(0)
        parseErrors.set(0)
        payloadMismatch.set(0)
        playoutUnderruns.set(0)
        netDelayUsSum.set(0)
        netDelaySamples.set(0)
        netDelayUsMin.set(Long.MAX_VALUE)
        netPathUsSum.set(0)
        netPathSamples.set(0)
        netJitterUsSum.set(0)
        netJitterSamples.set(0)
        lastNetAgeUs.set(-1)
        decodeUsSum.set(0)
        decodeSamples.set(0)
        resetAdaptiveController()
    }

    private fun resetAdaptiveController() {
        adaptiveBaseTargetFrames = 0
        adaptiveTargetFrames = 0
        adaptiveMinTargetFrames = 2
        adaptiveMaxTargetFrames = 2
        adaptiveScoreEma = 100.0
        adaptiveBadStreak = 0
        adaptiveGoodStreak = 0
        adaptiveZeroBufferStreak = 0
        adaptiveCooldownSec = 0
        adaptiveLastReason = "init"
    }

    private fun updateEstimatedNetDelay(sendTimeUs: Long) {
        if (sendTimeUs <= 0) return
        val nowUs = System.currentTimeMillis() * 1000L
        val ageUs = nowUs - sendTimeUs
        if (ageUs in 0L..5_000_000L) {
            netDelayUsSum.addAndGet(ageUs)
            netDelaySamples.incrementAndGet()
            var currentMin = netDelayUsMin.get()
            while (ageUs < currentMin) {
                if (netDelayUsMin.compareAndSet(currentMin, ageUs)) {
                    currentMin = ageUs
                    break
                }
                currentMin = netDelayUsMin.get()
            }
            val baseline = netDelayUsMin.get()
            if (baseline != Long.MAX_VALUE && ageUs >= baseline) {
                netPathUsSum.addAndGet(ageUs - baseline)
                netPathSamples.incrementAndGet()
            }
            val prevAge = lastNetAgeUs.getAndSet(ageUs)
            if (prevAge > 0L) {
                netJitterUsSum.addAndGet(abs(ageUs - prevAge))
                netJitterSamples.incrementAndGet()
            }
        }
    }

    private fun sampleNetworkPerf(): NetworkPerf {
        val ageSamples = netDelaySamples.getAndSet(0)
        val ageTotalUs = netDelayUsSum.getAndSet(0)
        val pathSamples = netPathSamples.getAndSet(0)
        val pathTotalUs = netPathUsSum.getAndSet(0)
        val jitterSamples = netJitterSamples.getAndSet(0)
        val jitterTotalUs = netJitterUsSum.getAndSet(0)
        val avgAgeMs = if (ageSamples > 0) {
            (ageTotalUs.toDouble() / ageSamples.toDouble()) / 1000.0
        } else {
            -1.0
        }
        val avgPathMs = if (pathSamples > 0) {
            (pathTotalUs.toDouble() / pathSamples.toDouble()) / 1000.0
        } else {
            -1.0
        }
        val avgJitterMs = if (jitterSamples > 0) {
            (jitterTotalUs.toDouble() / jitterSamples.toDouble()) / 1000.0
        } else {
            -1.0
        }
        return NetworkPerf(
            avgAgeMs = avgAgeMs,
            avgPathMs = avgPathMs,
            avgJitterMs = avgJitterMs
        )
    }

    private fun averageDecodeMs(): Double {
        val samples = decodeSamples.getAndSet(0)
        if (samples <= 0) return -1.0
        val totalUs = decodeUsSum.getAndSet(0)
        return (totalUs.toDouble() / samples.toDouble()) / 1000.0
    }

    private fun computeWindowScore(
        underrunDelta: Long,
        missingDelta: Long,
        overflowDelta: Long,
        parseErrDelta: Long,
        payloadErrDelta: Long,
        bufferedFrames: Int,
        targetFrames: Int
    ): Double {
        var score = 100.0
        score -= underrunDelta * 25.0
        score -= missingDelta * 18.0
        score -= parseErrDelta * 50.0
        score -= payloadErrDelta * 40.0
        score -= overflowDelta * 2.0

        val lowWater = max(1, targetFrames / 2)
        if (bufferedFrames < lowWater) {
            score -= (lowWater - bufferedFrames) * 3.0
        }
        return score.coerceIn(0.0, 100.0)
    }

    private fun maybeAdjustAutoJitter(
        jitter: JitterSnapshot?,
        underrunDelta: Long,
        missingDelta: Long,
        overflowDelta: Long,
        parseErrDelta: Long,
        payloadErrDelta: Long,
        bufferedFrames: Int
    ): AutoAdjustInfo? {
        if (jitterBuffer == null) return null
        if (adaptiveTargetFrames <= 0) return null

        if (adaptiveCooldownSec > 0) {
            adaptiveCooldownSec -= 1
        }

        val badNow = underrunDelta > 0 ||
            missingDelta > 0 ||
            parseErrDelta > 0 ||
            payloadErrDelta > 0
        val targetFramesNow = jitter?.targetFrames ?: adaptiveTargetFrames
        val zeroBufferNow = bufferedFrames == 0
        if (zeroBufferNow) {
            adaptiveZeroBufferStreak += 1
        } else {
            adaptiveZeroBufferStreak = 0
        }

        if (badNow || adaptiveScoreEma < 90.0) {
            adaptiveBadStreak += 1
        } else {
            adaptiveBadStreak = max(0, adaptiveBadStreak - 1)
        }

        val goodNow = !badNow &&
            overflowDelta == 0L &&
            adaptiveScoreEma > 97.0 &&
            bufferedFrames >= max(1, targetFramesNow / 2) &&
            !zeroBufferNow
        if (goodNow) {
            adaptiveGoodStreak += 1
        } else {
            adaptiveGoodStreak = 0
        }

        var desired = adaptiveTargetFrames
        var reason: String? = null
        if (adaptiveCooldownSec <= 0) {
            val severe = underrunDelta >= 2 ||
                missingDelta >= 2 ||
                parseErrDelta > 0 ||
                payloadErrDelta > 0
            val raiseByBuffer = adaptiveZeroBufferStreak >= 2

            if ((adaptiveBadStreak >= 1 || raiseByBuffer) && desired < adaptiveMaxTargetFrames) {
                val raiseStep = if (severe || adaptiveZeroBufferStreak >= 3) 2 else 1
                desired += raiseStep
                reason = if (severe) "raise-severe" else "raise"
            } else if (adaptiveGoodStreak >= 8 && desired > adaptiveMinTargetFrames) {
                desired -= if (desired > adaptiveBaseTargetFrames + 3) 2 else 1
                reason = "lower-stable"
            }
        }

        desired = desired.coerceIn(adaptiveMinTargetFrames, adaptiveMaxTargetFrames)
        if (desired == adaptiveTargetFrames) {
            return null
        }

        val applied = jitterBuffer?.setTargetFrames(desired) ?: desired
        adaptiveTargetFrames = applied
        adaptiveLastReason = reason ?: "hold"
        adaptiveCooldownSec = if (applied > targetFramesNow) 2 else 2
        adaptiveBadStreak = 0
        adaptiveGoodStreak = 0
        adaptiveZeroBufferStreak = 0
        return AutoAdjustInfo(targetFrames = applied, reason = adaptiveLastReason)
    }

    private fun normalizeTransport(raw: String?): String {
        return when (raw?.lowercase(Locale.US)) {
            TRANSPORT_TCP -> TRANSPORT_TCP
            else -> TRANSPORT_UDP
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Audio Receiver",
            NotificationManager.IMPORTANCE_LOW
        )
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Audio Receiver")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_headset)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "UdpAudioService"
        private const val CHANNEL_ID = "audio_rx"
        private const val NOTIF_ID = 1001

        const val ACTION_START = "com.audiolink.receiver.action.START"
        const val ACTION_STOP = "com.audiolink.receiver.action.STOP"
        const val EXTRA_PORT = "extra_port"
        const val EXTRA_JITTER_MS = "extra_jitter_ms"
        const val EXTRA_TRANSPORT = "extra_transport"
        const val TRANSPORT_UDP = "udp"
        const val TRANSPORT_TCP = "tcp"
    }

    private data class NetworkPerf(
        val avgAgeMs: Double,
        val avgPathMs: Double,
        val avgJitterMs: Double
    )

    private data class AutoAdjustInfo(
        val targetFrames: Int,
        val reason: String
    )
}
