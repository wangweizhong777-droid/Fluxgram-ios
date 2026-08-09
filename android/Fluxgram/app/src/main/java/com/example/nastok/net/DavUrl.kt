package com.example.nastok.net

import com.example.nastok.data.NasSettings
import java.net.URLEncoder

/** Shared WebDAV URL building, so the scanner and the player encode paths identically. */
object DavUrl {

    /** Encode each path segment individually, preserving '/'. URLEncoder emits '+'
     *  for spaces which servers reject in paths, so convert to %20. */
    fun encodePath(path: String): String =
        path.split("/").joinToString("/") { seg ->
            if (seg.isEmpty()) seg
            else URLEncoder.encode(seg, "UTF-8").replace("+", "%20")
        }

    fun streamUrl(settings: NasSettings, path: String): String =
        DavEndpointPolicy.localUrl(settings.davEndpointSettings(), path)
}
