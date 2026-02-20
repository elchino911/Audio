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
import kotlin.concurrent.thread
import kotlin.math.max

class UdpAudioService : Service() {
    private var socket: DatagramSocket? = null
    private var receiverThread: Thread? = null
    private var playerThread: Thread? = null
    private var audioTrack: AudioTrack? = null
    private var jitterBuffer: JitterBuffer? = null
    private var expectedFrameSamples: Int = 0
    private var silenceFrame: ShortArray = shortArrayOf()

    @Volatile
    private var running = false

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

        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification("Listening on UDP $port"))

        running = true
        receiverThread = thread(name = "udp-receiver", isDaemon = true) {
            receiveLoop(port, jitterMs)
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

        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null

        jitterBuffer = null
        expectedFrameSamples = 0
        silenceFrame = shortArrayOf()

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun receiveLoop(port: Int, jitterMs: Int) {
        try {
            DatagramSocket(port).use { sock ->
                socket = sock
                sock.soTimeout = 500
                val packetBuf = ByteArray(2048)

                while (running) {
                    try {
                        val datagram = DatagramPacket(packetBuf, packetBuf.size)
                        sock.receive(datagram)

                        val packet = AudioPacket.parse(datagram.data, datagram.length) ?: continue
                        if (audioTrack == null) {
                            initAudio(packet, jitterMs)
                        }

                        if (packet.payload.size == expectedFrameSamples) {
                            jitterBuffer?.push(packet.payload)
                        }
                    } catch (_: java.net.SocketTimeoutException) {
                        // Keep service alive while waiting for packets.
                    } catch (e: Exception) {
                        Log.e(TAG, "receive error", e)
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

        val frameMs = max(1, (packet.samplesPerChannel * 1000) / packet.sampleRate)
        val targetFrames = max(1, jitterMs / frameMs)
        val maxFrames = targetFrames + 8
        jitterBuffer = JitterBuffer(targetFrames = targetFrames, maxFrames = maxFrames)

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
        val desiredBuffer = expectedFrameSamples * 2 * maxFrames
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
            "audio initialized: ${packet.sampleRate}Hz ch=${packet.channels} frame=${packet.samplesPerChannel}"
        )
    }

    private fun playLoop() {
        while (running) {
            val frame = jitterBuffer?.pop(10) ?: silenceFrame
            val safeFrame = if (frame.size == expectedFrameSamples) {
                frame
            } else {
                silenceFrame
            }
            audioTrack?.write(safeFrame, 0, safeFrame.size, AudioTrack.WRITE_BLOCKING)
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
    }
}
