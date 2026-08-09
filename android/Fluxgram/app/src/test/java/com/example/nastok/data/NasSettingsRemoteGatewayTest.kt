package com.example.nastok.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NasSettingsRemoteGatewayTest {
    @Test
    fun remoteGatewayRequiresBothItsHttpsAddressAndAccessToken() {
        assertFalse(NasSettings(remoteGatewayBaseUrl = "https://your-gateway.example.com/api/nastok-webdav").isRemoteGatewayConfigured)
        assertFalse(NasSettings(remoteGatewayToken = "token").isRemoteGatewayConfigured)
        assertTrue(
            NasSettings(
                remoteGatewayBaseUrl = " https://your-gateway.example.com/api/nastok-webdav/ ",
                remoteGatewayToken = "token",
            ).isRemoteGatewayConfigured,
        )
    }

    @Test
    fun tagServiceConfigurationCanBeReusedAsTheRemoteGateway() {
        val settings = NasSettings(
            tagApiBaseUrl = "https://your-gateway.example.com",
            tagApiToken = "tag-token",
        )

        assertTrue(settings.isRemoteGatewayConfigured)
        assertTrue(settings.normalizedRemoteGatewayBaseUrl.endsWith("/api/nastok-webdav"))
        assertTrue(settings.effectiveRemoteGatewayToken == "tag-token")
    }

    @Test
    fun remoteGatewayConfigurationAlsoSuppliesTheTagService() {
        val settings = NasSettings(
            remoteGatewayBaseUrl = "https://your-gateway.example.com/api/nastok-webdav/",
            remoteGatewayToken = "remote-token",
        )

        assertTrue(settings.isTagApiConfigured)
        assertEquals("https://your-gateway.example.com", settings.normalizedTagApiBaseUrl)
        assertEquals("remote-token", settings.effectiveTagApiToken)
    }
}
