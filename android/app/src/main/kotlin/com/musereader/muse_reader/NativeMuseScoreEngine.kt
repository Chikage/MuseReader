package com.musereader.muse_reader

/** JNI boundary for the packaged MuseScore 3.6.2 reader core. */
object NativeMuseScoreEngine {
    private var loaded = false

    init {
        try {
            System.loadLibrary("muse_reader_engine")
            loaded = true
        } catch (_: UnsatisfiedLinkError) {
            // Dart strict mode turns this into a visible load failure.
        }
    }

    fun isAvailable(): Boolean {
        if (!loaded) return false
        return try {
            isAvailableNative()
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    fun initialize(): Boolean {
        if (!loaded) return false
        return try {
            initializeNative()
        } catch (_: UnsatisfiedLinkError) {
            false
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

    fun lastError(): String? {
        if (!loaded) return null
        return try {
            lastErrorNative()
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    @JvmStatic
    private external fun initializeNative(): Boolean

    @JvmStatic
    private external fun isAvailableNative(): Boolean

    @JvmStatic
    private external fun openJsonNative(path: String): String?

    @JvmStatic
    private external fun lastErrorNative(): String?
}
