#include <jni.h>

#include "muse_reader_engine.h"

extern "C" JNIEXPORT jboolean JNICALL
Java_com_musereader_muse_1reader_NativeMuseScoreEngine_initializeNative(
    JNIEnv* /* env */,
    jclass /* clazz */) {
  return muse_reader_initialize() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_musereader_muse_1reader_NativeMuseScoreEngine_isAvailableNative(
    JNIEnv* /* env */,
    jclass /* clazz */) {
  return muse_reader_is_available() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_musereader_muse_1reader_NativeMuseScoreEngine_openJsonNative(
    JNIEnv* env,
    jclass /* clazz */,
    jstring path) {
  if (path == nullptr) return nullptr;

  const char* utf8_path = env->GetStringUTFChars(path, nullptr);
  if (utf8_path == nullptr) return nullptr;
  const char* json = muse_reader_open_json(utf8_path);
  env->ReleaseStringUTFChars(path, utf8_path);

  if (json == nullptr) return nullptr;
  jstring result = env->NewStringUTF(json);
  muse_reader_free_json(json);
  return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_musereader_muse_1reader_NativeMuseScoreEngine_lastErrorNative(
    JNIEnv* env,
    jclass /* clazz */) {
  const char* error = muse_reader_last_error();
  if (error == nullptr || error[0] == '\0') return nullptr;
  return env->NewStringUTF(error);
}
