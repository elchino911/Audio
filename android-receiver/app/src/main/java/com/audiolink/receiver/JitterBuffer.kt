package com.audiolink.receiver

import java.util.ArrayDeque
import kotlin.math.max

data class JitterSnapshot(
    val bufferedFrames: Int,
    val targetFrames: Int,
    val maxFrames: Int,
    val pushed: Long,
    val played: Long,
    val missing: Long,
    val late: Long,
    val overflowDropped: Long
)

class JitterBuffer(
    initialTargetFrames: Int,
    private val maxFrames: Int
) {
    private val lock = java.lang.Object()
    private val queue = ArrayDeque<ShortArray>()
    private var primed = false
    private var targetFrames: Int = initialTargetFrames.coerceIn(2, max(2, maxFrames - 1))

    private var pushed: Long = 0
    private var played: Long = 0
    private var missing: Long = 0
    private var late: Long = 0
    private var overflowDropped: Long = 0

    fun push(@Suppress("UNUSED_PARAMETER") seq: Long, frame: ShortArray) {
        synchronized(lock) {
            pushed++
            if (queue.size >= maxFrames) {
                queue.removeFirst()
                overflowDropped++
            }
            queue.addLast(frame)
            if (!primed && queue.size >= targetFrames) {
                primed = true
            }
            lock.notifyAll()
        }
    }

    fun pop(timeoutMs: Long): ShortArray? {
        synchronized(lock) {
            val deadline = System.currentTimeMillis() + max(1, timeoutMs)
            while (!primed && System.currentTimeMillis() < deadline) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) break
                try {
                    lock.wait(remaining)
                } catch (_: InterruptedException) {
                    return null
                }
            }
            if (!primed) return null

            val lowWaterFrames = max(1, targetFrames / 2)
            while (queue.size <= lowWaterFrames && System.currentTimeMillis() < deadline) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) break
                try {
                    lock.wait(remaining)
                } catch (_: InterruptedException) {
                    return null
                }
            }

            while (queue.isEmpty() && System.currentTimeMillis() < deadline) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) break
                try {
                    lock.wait(remaining)
                } catch (_: InterruptedException) {
                    return null
                }
            }

            if (queue.isEmpty()) {
                missing++
                played++
                return null
            }
            played++
            return queue.removeFirst()
        }
    }

    fun setTargetFrames(newTargetFrames: Int): Int {
        synchronized(lock) {
            targetFrames = newTargetFrames.coerceIn(2, max(2, maxFrames - 1))
            if (!primed && queue.size >= targetFrames) {
                primed = true
            }
            lock.notifyAll()
            return targetFrames
        }
    }

    fun snapshot(): JitterSnapshot {
        synchronized(lock) {
            return JitterSnapshot(
                bufferedFrames = queue.size,
                targetFrames = targetFrames,
                maxFrames = maxFrames,
                pushed = pushed,
                played = played,
                missing = missing,
                late = late,
                overflowDropped = overflowDropped
            )
        }
    }
}
