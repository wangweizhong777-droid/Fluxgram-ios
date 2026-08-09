package com.example.nastok

import androidx.media3.exoplayer.SeekParameters

/** Prefer the nearby sync frame so long NAS videos do not rewind far before playback resumes. */
fun seekParametersFor(@Suppress("UNUSED_PARAMETER") durationMs: Long): SeekParameters =
    SeekParameters.CLOSEST_SYNC
