package com.audiolink.receiver

import java.util.ArrayDeque

class JitterBuffer(
    private val targetFrames: Int,
    private val maxFrames: Int
) {
    private val queue = ArrayDeque<ShortArray>()
    private var primed = false

    @Synchronized
    fun push(frame: ShortArray) {
        if (queue.size >= maxFrames) {
            queue.removeFirst()
        }
        queue.addLast(frame)
        if (!primed && queue.size >= targetFrames) {
            primed = true
        }
        notifyAll()
    }

    @Synchronized
    fun pop(timeoutMs: Long): ShortArray? {
        if (!primed) {
            try {
                wait(timeoutMs)
            } catch (_: InterruptedException) {
                return null
            }
            if (!primed) return null
        }

        while (queue.isEmpty()) {
            try {
                wait(timeoutMs)
            } catch (_: InterruptedException) {
                return null
            }
            if (queue.isEmpty()) return null
        }

        return queue.removeFirst()
    }
}
