package com.audiolink.receiver

import java.util.TreeMap
import kotlin.math.max

data class JitterSnapshot(
    val bufferedFrames: Int,
    val pushed: Long,
    val played: Long,
    val missing: Long,
    val late: Long,
    val overflowDropped: Long
)

class JitterBuffer(
    private val targetFrames: Int,
    private val maxFrames: Int,
    private val frameSamples: Int
) {
    private val lock = java.lang.Object()
    private val pending = TreeMap<Long, ShortArray>()
    private var primed = false
    private var nextSeq: Long? = null
    private var lastGoodFrame: ShortArray? = null

    private var pushed: Long = 0
    private var played: Long = 0
    private var missing: Long = 0
    private var late: Long = 0
    private var overflowDropped: Long = 0

    fun push(seq: Long, frame: ShortArray) {
        synchronized(lock) {
            pushed++
            val expected = nextSeq
            if (expected != null && seq < expected) {
                late++
                return
            }

            if (!pending.containsKey(seq)) {
                pending[seq] = frame
            }

            if (nextSeq == null) {
                nextSeq = seq
            }
            if (!primed && pending.size >= targetFrames) {
                primed = true
            }

            trimOverflow()
            lock.notifyAll()
        }
    }

    fun pop(timeoutMs: Long): ShortArray? {
        synchronized(lock) {
            val deadline = System.currentTimeMillis() + max(1, timeoutMs)
            while ((!primed || nextSeq == null) && System.currentTimeMillis() < deadline) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) break
                try {
                    lock.wait(remaining)
                } catch (_: InterruptedException) {
                    return null
                }
            }
            var expected = nextSeq ?: return null
            if (!primed) return null

            while (System.currentTimeMillis() < deadline) {
                val frame = pending.remove(expected)
                if (frame != null) {
                    nextSeq = expectedSeqAdvance(expected)
                    played++
                    lastGoodFrame = frame
                    return frame
                }

                val firstPending = firstKeyOrNull()
                if (firstPending != null && firstPending > expected) {
                    val remaining = deadline - System.currentTimeMillis()
                    if (remaining > 0) {
                        try {
                            lock.wait(remaining)
                        } catch (_: InterruptedException) {
                            return null
                        }
                        expected = nextSeq ?: expected
                        continue
                    }
                }
                break
            }

            missing++
            played++
            nextSeq = expectedSeqAdvance(expected)
            return packetLossConcealment()
        }
    }

    fun snapshot(): JitterSnapshot {
        synchronized(lock) {
            return JitterSnapshot(
                bufferedFrames = pending.size,
                pushed = pushed,
                played = played,
                missing = missing,
                late = late,
                overflowDropped = overflowDropped
            )
        }
    }

    private fun trimOverflow() {
        if (pending.size <= maxFrames) return
        val highest = pending.lastKey()
        val keepFrom = highest - (targetFrames.toLong() - 1L)

        val toDrop = pending.headMap(keepFrom, false).keys.toList()
        for (key in toDrop) {
            pending.remove(key)
            overflowDropped++
        }

        val expected = nextSeq
        if (expected != null && expected < keepFrom) {
            missing += keepFrom - expected
            nextSeq = keepFrom
        }
    }

    private fun packetLossConcealment(): ShortArray {
        val previous = lastGoodFrame
        if (previous == null || previous.size != frameSamples) {
            return ShortArray(frameSamples)
        }

        val concealed = ShortArray(previous.size)
        for (i in previous.indices) {
            concealed[i] = (previous[i] * 0.92f).toInt().toShort()
        }
        lastGoodFrame = concealed
        return concealed
    }

    private fun expectedSeqAdvance(seq: Long): Long {
        return (seq + 1L) and 0xFFFF_FFFFL
    }

    private fun firstKeyOrNull(): Long? {
        return if (pending.isEmpty()) null else pending.firstKey()
    }
}
