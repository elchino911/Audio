package com.audiolink.receiver

import java.util.ArrayDeque

class JitterBuffer(
    private val targetFrames: Int,
    private val maxFrames: Int
) {
    private val lock = java.lang.Object()
    private val queue = ArrayDeque<ShortArray>()
    private var primed = false

    fun push(frame: ShortArray) {
        synchronized(lock) {
            if (queue.size >= maxFrames) {
                queue.removeFirst()
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
            val deadline = System.currentTimeMillis() + timeoutMs
            var remaining = timeoutMs

            while (!primed && remaining > 0) {
                try {
                    lock.wait(remaining)
                } catch (_: InterruptedException) {
                    return null
                }
                remaining = deadline - System.currentTimeMillis()
            }
            if (!primed) return null

            remaining = timeoutMs
            val popDeadline = System.currentTimeMillis() + timeoutMs
            while (queue.isEmpty() && remaining > 0) {
                try {
                    lock.wait(remaining)
                } catch (_: InterruptedException) {
                    return null
                }
                remaining = popDeadline - System.currentTimeMillis()
            }
            if (queue.isEmpty()) return null

            return queue.removeFirst()
        }
    }
}
