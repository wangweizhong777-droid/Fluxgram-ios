package com.example.nastok

import androidx.media3.exoplayer.SeekParameters
import org.junit.Assert.assertSame
import org.junit.Test

class SeekParametersPolicyTest {
    @Test
    fun `short clips seek to the closest sync frame instead of always rewinding`() {
        assertSame(SeekParameters.CLOSEST_SYNC, seekParametersFor(20_000))
    }

    @Test
    fun `long clips seek to the closest sync frame near the requested position`() {
        assertSame(SeekParameters.CLOSEST_SYNC, seekParametersFor(60_000))
    }
}
