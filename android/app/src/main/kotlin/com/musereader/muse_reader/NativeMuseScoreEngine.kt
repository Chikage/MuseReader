package com.musereader.muse_reader

/** JNI boundary for the optional MuseScore 3.6.2 core. */
object NativeMuseScoreEngine {
    private var loaded = false

    init {
        try {
            System.loadLibrary("muse_reader_engine")
            loaded = true
        } catch (_: UnsatisfiedLinkError) {
            // The default reader APK contains the compatibility parser only.
        }
    }

    fun open(path: String): String? {
        if (!loaded) return null
        return try {
            openJsonNative(path)
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    @JvmStatic
    private external fun openJsonNative(path: String): String?
}
