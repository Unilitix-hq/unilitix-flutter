package com.unilitix.unilitix_flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PendingFramesTest {

    private fun frame(n: Int) = EncodedFrame(ByteArray(n), n, n)

    @Test
    fun aFrameIsTakenOnce() {
        val p = PendingFrames()
        val id = p.put(frame(1))
        assertNotNull(p.take(id))
        assertNull(p.take(id))
    }

    @Test
    fun orphansAreDroppedOldestFirst() {
        val p = PendingFrames()
        val first = p.put(frame(1))
        p.put(frame(2))
        val third = p.put(frame(3))
        assertEquals(PendingFrames.MAX, p.size)
        assertNull(p.take(first))
        assertEquals(3, p.take(third)!!.width)
    }
}
