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
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.math.max

class UdpAudioService : Service() {
    private var socket: DatagramSocket? = null
    private var receiverThread: Thread? = null
    private var playerThread: Thread? = null
    private var statsThread: Thread? = null
    private var audioTrack: AudioTrack? = null
    private var jitterBuffer: JitterBuffer? = null
    private var expectedFrameSamples: Int = 0
    private var silenceFrame: ShortArray = shortArrayOf()
    private var frameMs: Int = 5

    @Volatile
    private var running = false

    private val rxPackets = AtomicLong(0)
    private val rxBytes = AtomicLong(0)
    private val parseErrors = AtomicLong(0)
    private val payloadMismatch = AtomicLong(0)
    private val playoutUnderruns = AtomicLong(0)
    private val netDelayUsSum = AtomicLong(0)
    private val netDelaySamples = AtomicLong(0)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val port = intent.getIntExtra(EXTRA_PORT, 50000)
                val jitterMs = intent.getIntExtra(EXTRA_JITTER_MS, 20)
                startStreaming(port, jitterMs)
            }

            ACTION_STOP -> stopStreaming()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopStreaming()
        super.onDestroy()
    }

    private fun startStreaming(port: Int, jitterMs: Int) {
        if (running) return

        resetStats()
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification("Listening on UDP $port"))

        running = true
        receiverThread = thread(name = "udp-receiver", isDaemon = true) {
            receiveLoop(port, jitterMs)
        }
        statsThread = thread(name = "udp-stats", isDaemon = true) {
            statsLoop()
        }
    }

    private fun stopStreaming() {
        running = false
        socket?.close()
        socket = null

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

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun receiveLoop(port: Int, jitterMs: Int) {
        try {
            DatagramSocket(port).use { sock ->
                socket = sock
                sock.soTimeout = 500
                sock.receiveBufferSize = 256 * 1024
                val packetBuf = ByteArray(8192)

                while (running) {
                    try {
                        val datagram = DatagramPacket(packetBuf, packetBuf.size)
                        sock.receive(datagram)

                        rxPackets.incrementAndGet()
                        rxBytes.addAndGet(datagram.length.toLong())

                        val packet = AudioPacket.parse(datagram.data, datagram.length)
                        if (packet == null) {
                            parseErrors.incrementAndGet()
                            continue
                        }
                        updateEstimatedNetDelay(packet.sendTimeUs)
                        if (audioTrack == null) {
                            initAudio(packet, jitterMs)
                        }

                        if (packet.payload.size == expectedFrameSamples) {
                            jitterBuffer?.push(packet.seq, packet.payload)
                        } else {
                            payloadMismatch.incrementAndGet()
                        }
                    } catch (_: java.net.SocketTimeoutException) {
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
            stopStreaming()
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
        val maxFrames = targetFrames + 16
        jitterBuffer = JitterBuffer(
            targetFrames = targetFrames,
            maxFrames = maxFrames,
            frameSamples = expectedFrameSamples
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
            "audio initialized: ${packet.sampleRate}Hz ch=${packet.channels} frame=${packet.samplesPerChannel} frameMs=$frameMs targetFrames=$targetFrames"
        )
    }

    private fun playLoop() {
        while (running) {
            val frame = jitterBuffer?.pop(frameMs.toLong())
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
            val avgDelayMs = averageNetDelayMs()
            val delayText = if (avgDelayMs >= 0.0) {
                String.format(Locale.US, "%.1f", avgDelayMs)
            } else {
                "n/a"
            }

            val missingDelta = if (jitter != null) jitter.missing - lastJitter.missing else 0L
            val lateDelta = if (jitter != null) jitter.late - lastJitter.late else 0L
            val overflowDelta = if (jitter != null) jitter.overflowDropped - lastJitter.overflowDropped else 0L
            val bufferedFrames = jitter?.bufferedFrames ?: 0
            val bufferedMs = bufferedFrames * frameMs

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
    }

    private fun updateEstimatedNetDelay(sendTimeUs: Long) {
        if (sendTimeUs <= 0) return
        val nowUs = System.currentTimeMillis() * 1000L
        val ageUs = nowUs - sendTimeUs
        if (ageUs in 0L..5_000_000L) {
            netDelayUsSum.addAndGet(ageUs)
            netDelaySamples.incrementAndGet()
        }
    }

    private fun averageNetDelayMs(): Double {
        val samples = netDelaySamples.getAndSet(0)
        if (samples <= 0) return -1.0
        val totalUs = netDelayUsSum.getAndSet(0)
        return (totalUs.toDouble() / samples.toDouble()) / 1000.0
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
    }
}
