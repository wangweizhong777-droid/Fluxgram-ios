package com.example.nastok.data

/** NAS WebDAV connection settings. */
data class NasSettings(
    val baseUrl: String = "https://192.0.2.10:5006",
    val username: String = "",
    val password: String = "",
    val rootPath: String = "/ddd4/mp4/",
    val tagApiBaseUrl: String = "",
    val tagApiToken: String = "",
    val localGatewayBaseUrl: String = "http://192.0.2.10:30177",
    val remoteGatewayBaseUrl: String = "",
    val remoteGatewayToken: String = "",
) {
    /** True when enough is filled in to attempt a connection. */
    val isConfigured: Boolean
        get() = baseUrl.isNotBlank() && rootPath.isNotBlank()

    /** baseUrl without a trailing slash, so paths can be appended cleanly. */
    val normalizedBaseUrl: String
        get() = baseUrl.trim().trimEnd('/')

    /** rootPath normalized to start with '/' and not end with one (unless it's just "/"). */
    val normalizedRootPath: String
        get() {
            var p = rootPath.trim()
            if (!p.startsWith("/")) p = "/$p"
            if (p.length > 1) p = p.trimEnd('/')
            return p
        }

    private val normalizedConfiguredRemoteGatewayBaseUrl: String
        get() = remoteGatewayBaseUrl.trim().trimEnd('/')

    val normalizedLocalGatewayBaseUrl: String
        get() = localGatewayBaseUrl.trim().trimEnd('/')

    /** Tag lookup reuses the remote gateway when it is the only configured TGAPP service. */
    val isTagApiConfigured: Boolean
        get() = normalizedTagApiBaseUrl.isNotBlank() && effectiveTagApiToken.isNotBlank()

    val normalizedTagApiBaseUrl: String
        get() {
            val explicit = tagApiBaseUrl.trim().trimEnd('/')
            if (explicit.isNotBlank()) return explicit
            return normalizedConfiguredRemoteGatewayBaseUrl
                .removeSuffix("/api/nastok-webdav")
        }

    val effectiveTagApiToken: String
        get() = tagApiToken.takeIf { it.isNotBlank() } ?: remoteGatewayToken

    /** Optional HTTPS gateway used only after the direct LAN WebDAV connection is unreachable. */
    val isRemoteGatewayConfigured: Boolean
        get() = (normalizedConfiguredRemoteGatewayBaseUrl.isNotBlank() && remoteGatewayToken.isNotBlank()) || isTagApiConfigured

    val normalizedRemoteGatewayBaseUrl: String
        get() = normalizedConfiguredRemoteGatewayBaseUrl.ifBlank {
            normalizedTagApiBaseUrl.takeIf { isTagApiConfigured }
                ?.plus("/api/nastok-webdav")
                .orEmpty()
        }

    val effectiveRemoteGatewayToken: String
        get() = remoteGatewayToken.takeIf { it.isNotBlank() } ?: effectiveTagApiToken
}
