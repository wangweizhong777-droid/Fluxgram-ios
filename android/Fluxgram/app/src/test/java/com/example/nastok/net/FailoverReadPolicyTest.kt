package com.example.nastok.net

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.SocketTimeoutException

class FailoverReadPolicyTest {
    @Test
    fun `the first two failed local reads stay on the local route`() {
        assertFalse(
            shouldRetryReadViaRemote(
                isReadingRemote = false,
                remoteAvailable = true,
                error = SocketTimeoutException("LAN stalled"),
                consecutiveLocalFailures = 1,
            ),
        )
        assertFalse(
            shouldRetryReadViaRemote(
                isReadingRemote = false,
                remoteAvailable = true,
                error = SocketTimeoutException("LAN stalled"),
                consecutiveLocalFailures = 2,
            ),
        )
    }

    @Test
    fun `the third consecutive local read failure is eligible for remote resume`() {
        assertTrue(
            shouldRetryReadViaRemote(
                isReadingRemote = false,
                remoteAvailable = true,
                error = SocketTimeoutException("LAN stalled"),
                consecutiveLocalFailures = 3,
            ),
        )
    }

    @Test
    fun `a failed remote read is not retried through the same remote gateway`() {
        assertFalse(
            shouldRetryReadViaRemote(
                isReadingRemote = true,
                remoteAvailable = true,
                error = SocketTimeoutException("gateway stalled"),
                consecutiveLocalFailures = 3,
            ),
        )
    }
}
