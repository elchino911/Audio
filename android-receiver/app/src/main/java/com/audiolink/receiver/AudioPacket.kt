package com.audiolink.receiver

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class AudioPacket(
    val sampleRate: Int,
    val channels: Int,
    val seq: Long,
    val samplesPerChannel: Int,
    val payload: ShortArray
) {
    companion object {
        private val MAGIC = byteArrayOf('A'.code.toByte(), 'U'.code.toByte(), 'D'.code.toByte(), '0'.code.toByte())
        private const val VERSION: Int = 1
        private const val CODEC_PCM16: Int = 0
        const val HEADER_SIZE = 28

        fun parse(packetBytes: ByteArray, packetLen: Int): AudioPacket? {
            if (packetLen < HEADER_SIZE) return null
            if (!packetBytes.copyOfRange(0, 4).contentEquals(MAGIC)) return null

            val version = packetBytes[4].toInt() and 0xFF
            val codec = packetBytes[5].toInt() and 0xFF
            val channels = packetBytes[6].toInt() and 0xFF

            if (version != VERSION || codec != CODEC_PCM16 || channels !in 1..2) {
                return null
            }

            val bb = ByteBuffer.wrap(packetBytes, 8, packetLen - 8).order(ByteOrder.LITTLE_ENDIAN)
            val sampleRate = bb.int
            val seq = bb.int.toLong() and 0xFFFF_FFFFL
            bb.long // send_time_us, unused in this MVP
            val samplesPerChannel = bb.short.toInt() and 0xFFFF
            val payloadLen = bb.short.toInt() and 0xFFFF

            if (payloadLen <= 0 || HEADER_SIZE + payloadLen > packetLen || payloadLen % 2 != 0) {
                return null
            }

            val pcm = ShortArray(payloadLen / 2)
            var idx = HEADER_SIZE
            var out = 0
            while (idx + 1 < HEADER_SIZE + payloadLen) {
                val lo = packetBytes[idx].toInt() and 0xFF
                val hi = packetBytes[idx + 1].toInt()
                pcm[out++] = ((hi shl 8) or lo).toShort()
                idx += 2
            }

            return AudioPacket(
                sampleRate = sampleRate,
                channels = channels,
                seq = seq,
                samplesPerChannel = samplesPerChannel,
                payload = pcm
            )
        }
    }
}
