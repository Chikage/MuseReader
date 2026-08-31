#include <jni.h>

#include "muse_reader_engine.h"

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
