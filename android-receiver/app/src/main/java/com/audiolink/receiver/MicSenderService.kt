package com.audiolink.receiver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.math.max
import kotlin.math.min

class MicSenderService : Service() {
    private var senderThread: Thread? = null
    private var statsThread: Thread? = null
    private var audioRecord: AudioRecord? = null
    private var udpSocket: DatagramSocket? = null
    private var tcpSocket: Socket? = null
    private var tcpOut: OutputStream? = null
    private var audioManager: AudioManager? = null
    private var scoActive = false

    @Volatile
    private var running = false
    @Volatile
    private var activeSessionId = 0L

    private val sessionCounter = AtomicLong(0)
    private val txPackets = AtomicLong(0)
    private val txBytes = AtomicLong(0)
    private val readErrors = AtomicLong(0)
    private val sendErrors = AtomicLong(0)
    private val captureSamples = AtomicLong(0)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val targetIp = intent.getStringExtra(EXTRA_TARGET_IP)?.trim().orEmpty()
                val port = intent.getIntExtra(EXTRA_PORT, 50010)
                val frameMs = intent.getIntExtra(EXTRA_FRAME_MS, 5)
                val transport = normalizeTransport(intent.getStringExtra(EXTRA_TRANSPORT))
                val inputMode = normalizeInputMode(intent.getStringExtra(EXTRA_INPUT_MODE))
                startSending(targetIp, port, frameMs, transport, inputMode)
            }

            ACTION_STOP -> stopSending()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopSending()
        super.onDestroy()
    }

    private fun startSending(
        targetIp: String,
        port: Int,
        frameMs: Int,
        transport: String,
        inputMode: String
    ) {
        if (running) {
            Log.i(TAG, "restart mic sender with new config mode=$inputMode transport=$transport target=$targetIp:$port")
            stopRuntimeOnly()
        }
        if (targetIp.isBlank()) {
            Log.e(TAG, "target ip requerido")
            return
        }

        resetStats()
        createNotificationChannel()
        startForeground(
            NOTIF_ID,
            buildNotification(
                "Mic($inputMode) -> $targetIp:$port (${transport.uppercase(Locale.US)})"
            )
        )

        val sessionId = sessionCounter.incrementAndGet()
        activeSessionId = sessionId
        running = true
        senderThread = thread(name = "mic-sender", isDaemon = true) {
            sendLoop(targetIp, port, frameMs.coerceIn(1, 20), transport, inputMode, sessionId)
        }
        statsThread = thread(name = "mic-stats", isDaemon = true) {
            statsLoop(frameMs.coerceIn(1, 20), transport, targetIp, port, inputMode, sessionId)
        }
    }

    private fun stopRuntimeOnly() {
        running = false
        activeSessionId = sessionCounter.incrementAndGet()

        senderThread?.interrupt()
        senderThread = null

        statsThread?.interrupt()
        statsThread = null

        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        audioRecord?.release()
        audioRecord = null
        teardownAudioRoute()

        udpSocket?.close()
        udpSocket = null
        closeTcp()
    }

    private fun stopSending() {
        stopRuntimeOnly()

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun sendLoop(
        targetIp: String,
        port: Int,
        frameMs: Int,
        transport: String,
        inputMode: String,
        sessionId: Long
    ) {
        val sampleRate = SAMPLE_RATE
        val channels = CHANNELS
        val samplesPerChannel = max(1, (sampleRate * frameMs) / 1000)
        val frameSamples = samplesPerChannel * channels
        val minBufferBytes = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val desiredBufferBytes = max(minBufferBytes, frameSamples * 2 * 8)

        audioManager = getSystemService(AudioManager::class.java)
        val recorder = buildAudioRecorder(
            sampleRate = sampleRate,
            inputMode = inputMode,
            bufferBytes = desiredBufferBytes
        )
        audioRecord = recorder

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord no pudo inicializarse")
            stopSending()
            return
        }

        val targetAddress = InetAddress.getByName(targetIp)
        if (transport == TRANSPORT_UDP) {
            udpSocket = DatagramSocket()
        }

        val temp = ShortArray(max(frameSamples * 2, 1024))
        val frame = ShortArray(frameSamples)
        var pending = 0
        var seq = 0

        try {
            prepareAudioRouteForInputMode(inputMode, recorder)
            recorder.startRecording()
            Log.i(
                TAG,
                "mic sender started: mode=$inputMode target=$targetIp:$port transport=$transport sr=$sampleRate ch=$channels frame=${frameMs}ms"
            )

            while (isSessionActive(sessionId)) {
                val n = recorder.read(temp, 0, temp.size, AudioRecord.READ_BLOCKING)
                if (n <= 0) {
                    readErrors.incrementAndGet()
                    continue
                }
                captureSamples.addAndGet(n.toLong())
                var offset = 0
                while (offset < n && isSessionActive(sessionId)) {
                    val need = frameSamples - pending
                    val take = min(need, n - offset)
                    System.arraycopy(temp, offset, frame, pending, take)
                    pending += take
                    offset += take
                    if (pending >= frameSamples) {
                        val packet = buildPacket(
                            seq = seq,
                            sampleRate = sampleRate,
                            channels = channels,
                            samplesPerChannel = samplesPerChannel,
                            payload = frame
                        )
                        if (sendPacket(packet, transport, targetAddress, port)) {
                            txPackets.incrementAndGet()
                            txBytes.addAndGet(packet.size.toLong())
                            seq = seq + 1
                        } else {
                            sendErrors.incrementAndGet()
                        }
                        pending = 0
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "mic sender loop error", e)
        } finally {
            if (sessionId == activeSessionId && running) {
                Log.w(TAG, "active mic sender session ended unexpectedly; stopping service")
                stopSending()
            }
        }
    }

    private fun buildAudioRecorder(sampleRate: Int, inputMode: String, bufferBytes: Int): AudioRecord {
        val source = when (inputMode) {
            INPUT_MODE_BLUETOOTH -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
            INPUT_MODE_PHONE -> MediaRecorder.AudioSource.MIC
            else -> MediaRecorder.AudioSource.MIC
        }

        return AudioRecord.Builder()
            .setAudioSource(source)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                    .build()
            )
            .setBufferSizeInBytes(bufferBytes)
            .build()
    }

    private fun prepareAudioRouteForInputMode(inputMode: String, recorder: AudioRecord) {
        val manager = audioManager ?: return
        when (inputMode) {
            INPUT_MODE_BLUETOOTH -> {
                manager.mode = AudioManager.MODE_IN_COMMUNICATION
                Log.i(TAG, "BT route: inputs(before)=${describeInputDevices(manager)}")

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    try {
                        val commBt = manager.availableCommunicationDevices
                            .firstOrNull { isBluetoothInputDevice(it) || isBluetoothCommDevice(it) }
                        if (commBt != null) {
                            val ok = manager.setCommunicationDevice(commBt)
                            Log.i(TAG, "BT route: setCommunicationDevice=${ok} device=${commBt.productName}/${commBt.type}")
                        } else {
                            Log.w(TAG, "BT route: no communication BT device available")
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "BT route: setCommunicationDevice failed", e)
                    }
                }

                try {
                    if (manager.isBluetoothScoAvailableOffCall) {
                        manager.startBluetoothSco()
                        manager.isBluetoothScoOn = true
                        scoActive = true
                        Log.i(TAG, "BT route: startBluetoothSco requested")
                    } else {
                        Log.w(TAG, "BT route: SCO not available off call on this device")
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "No se pudo activar Bluetooth SCO", e)
                }

                var selected = false
                val deadline = System.currentTimeMillis() + 3000L
                while (System.currentTimeMillis() < deadline) {
                    try {
                        val btInput = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
                            .firstOrNull { isBluetoothInputDevice(it) }
                        if (btInput != null) {
                            val ok = recorder.setPreferredDevice(btInput)
                            Log.i(TAG, "Mic route: bluetooth input selected=${ok} device=${btInput.productName}/${btInput.type}")
                            if (ok) {
                                selected = true
                                break
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "No se pudo fijar preferredDevice Bluetooth", e)
                    }
                    Thread.sleep(100)
                }

                if (!selected) {
                    Log.w(
                        TAG,
                        "BT route: no input BT selected after wait; inputs(after)=${describeInputDevices(manager)}"
                    )
                }
            }

            INPUT_MODE_PHONE -> {
                teardownAudioRoute()
                manager.mode = AudioManager.MODE_NORMAL
            }

            else -> {
                teardownAudioRoute()
            }
        }
    }

    private fun teardownAudioRoute() {
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                manager.clearCommunicationDevice()
            } catch (_: Exception) {
            }
        }
        if (scoActive) {
            try {
                manager.isBluetoothScoOn = false
                manager.stopBluetoothSco()
            } catch (_: Exception) {
            }
        }
        scoActive = false
        try {
            manager.mode = AudioManager.MODE_NORMAL
        } catch (_: Exception) {
        }
    }

    private fun sendPacket(
        packet: ByteArray,
        transport: String,
        targetAddress: InetAddress,
        port: Int
    ): Boolean {
        return if (transport == TRANSPORT_TCP) {
            sendTcpPacket(packet, targetAddress.hostAddress ?: "", port)
        } else {
            sendUdpPacket(packet, targetAddress, port)
        }
    }

    private fun sendUdpPacket(packet: ByteArray, targetAddress: InetAddress, port: Int): Boolean {
        return try {
            val socket = udpSocket ?: return false
            val datagram = DatagramPacket(packet, packet.size, targetAddress, port)
            socket.send(datagram)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun sendTcpPacket(packet: ByteArray, targetIp: String, port: Int): Boolean {
        if (!ensureTcpConnected(targetIp, port)) {
            return false
        }
        val out = tcpOut ?: return false
        return try {
            val size = packet.size
            if (size > 0xFFFF) return false
            out.write(size and 0xFF)
            out.write((size shr 8) and 0xFF)
            out.write(packet)
            out.flush()
            true
        } catch (_: Exception) {
            closeTcp()
            false
        }
    }

    private fun ensureTcpConnected(targetIp: String, port: Int): Boolean {
        val existing = tcpSocket
        if (existing != null && existing.isConnected && !existing.isClosed && tcpOut != null) {
            return true
        }
        closeTcp()
        return try {
            val socket = Socket()
            socket.tcpNoDelay = true
            socket.connect(InetSocketAddress(targetIp, port), 1500)
            tcpSocket = socket
            tcpOut = socket.getOutputStream()
            true
        } catch (_: Exception) {
            closeTcp()
            false
        }
    }

    private fun closeTcp() {
        try {
            tcpOut?.close()
        } catch (_: Exception) {
        }
        try {
            tcpSocket?.close()
        } catch (_: Exception) {
        }
        tcpOut = null
        tcpSocket = null
    }

    private fun buildPacket(
        seq: Int,
        sampleRate: Int,
        channels: Int,
        samplesPerChannel: Int,
        payload: ShortArray
    ): ByteArray {
        val payloadLen = payload.size * 2
        val bb = ByteBuffer.allocate(AudioPacket.HEADER_SIZE + payloadLen).order(ByteOrder.LITTLE_ENDIAN)
        bb.put(MAGIC)
        bb.put(VERSION.toByte())
        bb.put(CODEC_PCM16.toByte())
        bb.put(channels.toByte())
        bb.put(0)
        bb.putInt(sampleRate)
        bb.putInt(seq)
        bb.putLong(System.currentTimeMillis() * 1000L)
        bb.putShort(samplesPerChannel.toShort())
        bb.putShort(payloadLen.toShort())
        for (s in payload) {
            bb.putShort(s)
        }
        return bb.array()
    }

    private fun statsLoop(
        frameMs: Int,
        transport: String,
        targetIp: String,
        port: Int,
        inputMode: String,
        sessionId: Long
    ) {
        var lastPackets = 0L
        var lastBytes = 0L
        var lastReadErrors = 0L
        var lastSendErrors = 0L
        var lastSamples = 0L
        while (isSessionActive(sessionId)) {
            try {
                Thread.sleep(1000)
            } catch (_: InterruptedException) {
                break
            }
            val packets = txPackets.get()
            val bytes = txBytes.get()
            val readErr = readErrors.get()
            val sendErr = sendErrors.get()
            val samples = captureSamples.get()

            val dPackets = packets - lastPackets
            val dBytes = bytes - lastBytes
            val dReadErr = readErr - lastReadErrors
            val dSendErr = sendErr - lastSendErrors
            val dSamples = samples - lastSamples
            val kbps = (dBytes * 8.0) / 1000.0
            Log.i(
                TAG,
                String.format(
                    Locale.US,
                    "mic tx=%dpps %.1fkbps samples=%d/s readErr=%d sendErr=%d frame=%dms target=%s:%d transport=%s",
                    dPackets,
                    kbps,
                    dSamples,
                    dReadErr,
                    dSendErr,
                    frameMs,
                    targetIp,
                    port,
                    "$transport mode=$inputMode"
                )
            )

            lastPackets = packets
            lastBytes = bytes
            lastReadErrors = readErr
            lastSendErrors = sendErr
            lastSamples = samples
        }
    }

    private fun isSessionActive(sessionId: Long): Boolean {
        return running && activeSessionId == sessionId
    }

    private fun isBluetoothInputDevice(device: AudioDeviceInfo): Boolean {
        return when (device.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> true
            AudioDeviceInfo.TYPE_BLE_HEADSET -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            else -> false
        }
    }

    private fun isBluetoothCommDevice(device: AudioDeviceInfo): Boolean {
        return when (device.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> true
            AudioDeviceInfo.TYPE_BLE_HEADSET -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            AudioDeviceInfo.TYPE_BLE_SPEAKER -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            else -> false
        }
    }

    private fun describeInputDevices(manager: AudioManager): String {
        return try {
            val list = manager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            if (list.isEmpty()) {
                "<none>"
            } else {
                list.joinToString(",") { "${it.productName}/${it.type}" }
            }
        } catch (_: Exception) {
            "<error>"
        }
    }

    private fun resetStats() {
        txPackets.set(0)
        txBytes.set(0)
        readErrors.set(0)
        sendErrors.set(0)
        captureSamples.set(0)
    }

    private fun normalizeTransport(raw: String?): String {
        return when (raw?.lowercase(Locale.US)) {
            TRANSPORT_TCP -> TRANSPORT_TCP
            else -> TRANSPORT_UDP
        }
    }

    private fun normalizeInputMode(raw: String?): String {
        return when (raw?.lowercase(Locale.US)) {
            INPUT_MODE_BLUETOOTH -> INPUT_MODE_BLUETOOTH
            INPUT_MODE_PHONE -> INPUT_MODE_PHONE
            else -> INPUT_MODE_AUTO
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Audio Link Sender",
            NotificationManager.IMPORTANCE_LOW
        )
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Audio Link Mic Sender")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_speakerphone)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "MicSenderService"
        private const val CHANNEL_ID = "audio_tx"
        private const val NOTIF_ID = 2001

        private val MAGIC = byteArrayOf('A'.code.toByte(), 'U'.code.toByte(), 'D'.code.toByte(), '0'.code.toByte())
        private const val VERSION = 1
        private const val CODEC_PCM16 = 0
        private const val SAMPLE_RATE = 48_000
        private const val CHANNELS = 1

        const val ACTION_START = "com.audiolink.receiver.action.MIC_START"
        const val ACTION_STOP = "com.audiolink.receiver.action.MIC_STOP"
        const val EXTRA_TARGET_IP = "extra_target_ip"
        const val EXTRA_PORT = "extra_port"
        const val EXTRA_FRAME_MS = "extra_frame_ms"
        const val EXTRA_TRANSPORT = "extra_transport"
        const val EXTRA_INPUT_MODE = "extra_input_mode"
        const val TRANSPORT_UDP = "udp"
        const val TRANSPORT_TCP = "tcp"
        const val INPUT_MODE_AUTO = "auto"
        const val INPUT_MODE_PHONE = "phone"
        const val INPUT_MODE_BLUETOOTH = "bluetooth"
    }
}
