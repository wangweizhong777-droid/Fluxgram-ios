package com.example.nastok.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import okhttp3.Request

class DavEndpointPolicyTest {

    private val settings = DavEndpointSettings(
        localBaseUrl = "https://192.0.2.10:5006",
        remoteGatewayBaseUrl = "https://your-gateway.example.com/api/nastok-webdav",
    )

    @Test
    fun buildsLocalUrlWithSegmentEncoding() {
        assertEquals(
            "https://192.0.2.10:5006/ddd4/mp4/%E7%BB%8F%E5%85%B8/%E7%AC%AC%2001.mp4",
            DavEndpointPolicy.localUrl(settings, "/ddd4/mp4/经典/第 01.mp4"),
        )
    }

    @Test
    fun buildsRemoteGatewayUrlWithTheSameServerRelativePath() {
        assertEquals(
            "https://your-gateway.example.com/api/nastok-webdav/ddd4/mp4/%E7%BB%8F%E5%85%B8/%E7%AC%AC%2001.mp4",
            DavEndpointPolicy.remoteUrl(settings, "/ddd4/mp4/经典/第 01.mp4"),
        )
    }

    @Test
    fun onlyNetworkErrorsAreEligibleForRemoteFallback() {
        assertTrue(DavEndpointPolicy.shouldFallback(ConnectException("refused")))
        assertTrue(DavEndpointPolicy.shouldFallback(UnknownHostException("offline")))
        assertTrue(DavEndpointPolicy.shouldFallback(SocketTimeoutException("timeout")))
        assertFalse(DavEndpointPolicy.shouldFallback(IllegalArgumentException("401 unauthorized")))
    }

    @Test
    fun remoteRequestsKeepWebDavBasicAuthAndAddTheGatewayToken() {
        val request = Request.Builder().url("https://your-gateway.example.com/api/nastok-webdav/a.mp4")
        DavRequestHeaders.apply(
            request,
            username = "nas-user",
            password = "nas-password",
            remoteGatewayToken = "gateway-token",
            isRemote = true,
        )

        assertTrue(request.build().header("Authorization")!!.startsWith("Basic "))
        assertEquals("gateway-token", request.build().header("X-TGAPP-Token"))
    }
}
