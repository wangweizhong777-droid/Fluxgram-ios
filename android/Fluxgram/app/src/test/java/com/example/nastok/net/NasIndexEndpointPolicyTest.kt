package com.example.nastok.net

import com.example.nastok.data.NasSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NasIndexEndpointPolicyTest {
    @Test
    fun `index endpoints prefer the local TGAPP service before the HTTPS gateway`() {
        val endpoints = nasIndexEndpoints(
            NasSettings(
                localGatewayBaseUrl = "http://192.0.2.10:30177",
                remoteGatewayBaseUrl = "https://your-gateway.example.com/api/nastok-webdav",
                remoteGatewayToken = "token",
            )
        )

        assertEquals("http://192.0.2.10:30177/api/nastok-index", endpoints.first().url)
        assertTrue(endpoints.first().isLocal)
        assertEquals("https://your-gateway.example.com/api/nastok-index", endpoints.last().url)
        assertEquals(
            "http://192.0.2.10:30177/api/nastok-index?root=%2Fddd4%2Fmp4",
            nasIndexUrl(endpoints.first(), "/ddd4/mp4"),
        )
    }

    @Test
    fun `index endpoints omit unavailable routes`() {
        assertTrue(nasIndexEndpoints(NasSettings()).isEmpty())
    }
}
