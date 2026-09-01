#include "muse_reader_engine.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#if defined(MUSE_READER_WITH_FLUIDSYNTH)
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>
#include <QString>

#include "event.h"
#include "fluid/fluid.h"
#endif

namespace {

constexpr int kAudioSampleRate = 44100;
// MuseScore's playback channel is an unsigned byte.  A score may allocate
// more than the sixteen wire-MIDI channels when articulation channels and
// instrument changes are present.
constexpr int kMaxPlaybackChannel = 255;

#if defined(MUSE_READER_WITH_FLUIDSYNTH)

struct AudioAction {
  enum class Kind : unsigned char { program = 0, note_off = 1, note_on = 2 };

  double time_us = 0.0;
  // Preserve the source event order for actions sharing a timestamp.  A
  // program change must stay adjacent to the note it configures; sorting all
  // program actions ahead of all note-ons would make simultaneous notes with
  // different instruments use whichever program happened to be last.
  std::uint64_t order = 0;
  Kind kind = Kind::note_on;
  int channel = 0;
  int pitch = 60;
  // Per-note cent offset carried by MuseScore's PlayEvent.  FluidSynth's
  // voice API expects this as a midicent adjustment rather than a channel
  // pitch bend, so simultaneous notes can have independent tunings.
  double tuning = 0.0;
  int velocity = 80;
  int program = 0;
  int bank = 0;
};

std::mutex g_audio_mutex;
std::unique_ptr<FluidS::Fluid> g_fluid;
std::vector<AudioAction> g_actions;
std::vector<float> g_effect1;
std::vector<float> g_effect2;
size_t g_next_action = 0;
double g_audio_cursor_us = 0.0;
double g_audio_speed = 1.0;
double g_audio_tail_end_us = 0.0;
bool g_audio_active = false;
std::string g_audio_error;

void set_audio_error(const std::string& message) {
  g_audio_error = message;
}

qint64 json_integer(const QJsonObject& object, const char* key, qint64 fallback) {
  const QJsonValue value = object.value(QLatin1String(key));
  if (value.isDouble()) return qRound64(value.toDouble());
  if (value.isString()) return value.toString().toLongLong();
  return fallback;
}

int json_int(const QJsonObject& object, const char* key, int fallback) {
  const qint64 value = json_integer(object, key, fallback);
  return static_cast<int>(qBound<qint64>(INT_MIN, value, INT_MAX));
}

double json_double(const QJsonObject& object, const char* key,
                   double fallback) {
  const QJsonValue value = object.value(QLatin1String(key));
  double result = fallback;
  if (value.isDouble()) {
    result = value.toDouble();
  } else if (value.isString()) {
    bool ok = false;
    const double parsed = value.toString().toDouble(&ok);
    if (ok) result = parsed;
  }
  if (!std::isfinite(result)) return fallback;
  // Keep the same safety envelope as MuseScore's
  // normalizedPlayEventTuning() helper.
  return std::clamp(result, -1000000.0, 1000000.0);
}

bool ensure_fluid_locked() {
  if (g_fluid) return true;

  try {
    auto candidate = std::make_unique<FluidS::Fluid>();
    candidate->init(static_cast<float>(kAudioSampleRate));
    if (!candidate->addSoundFont(QStringLiteral(":/sound/MS Basic.sf3"))) {
      set_audio_error("Unable to load embedded MS Basic.sf3");
      return false;
    }
    g_fluid = std::move(candidate);
    // Most platform callbacks request 512 or 1024 frames. Reserve enough
    // space up front so the first render does not grow these scratch buffers.
    g_effect1.reserve(2048);
    g_effect2.reserve(2048);
    return true;
  } catch (const std::exception& error) {
    set_audio_error(std::string("Unable to initialize FluidSynth: ") +
                    error.what());
    g_fluid.reset();
    return false;
  } catch (...) {
    set_audio_error("Unable to initialize FluidSynth");
    g_fluid.reset();
    return false;
  }
}

void dispatch_controller(int channel, int controller, int value) {
  if (!g_fluid) return;
  const Ms::NPlayEvent event(
      Ms::ME_CONTROLLER, static_cast<uchar>(channel),
      static_cast<uchar>(controller), static_cast<uchar>(value));
  g_fluid->play(event);
}

void dispatch_action(const AudioAction& action) {
  if (!g_fluid) return;
  Ms::NPlayEvent event;
  switch (action.kind) {
    case AudioAction::Kind::program:
      // Bank select is part of the MuseScore instrument state. Replaying it
      // immediately before the program change keeps channel 10 percussion
      // and higher-bank MuseScore variants intact after a seek.
      dispatch_controller(action.channel, Ms::CTRL_HBANK,
                          (action.bank >> 7) & 0x7f);
      dispatch_controller(action.channel, Ms::CTRL_LBANK, action.bank & 0x7f);
      dispatch_controller(action.channel, Ms::CTRL_PROGRAM, action.program);
      return;
    case AudioAction::Kind::note_off:
      event = Ms::NPlayEvent(Ms::ME_NOTEOFF,
                             static_cast<uchar>(action.channel),
                             static_cast<uchar>(action.pitch), 0);
      event.setTuning(static_cast<float>(action.tuning));
      break;
    case AudioAction::Kind::note_on:
      event = Ms::NPlayEvent(Ms::ME_NOTEON,
                             static_cast<uchar>(action.channel),
                             static_cast<uchar>(action.pitch),
                             static_cast<uchar>(action.velocity));
      event.setTuning(static_cast<float>(action.tuning));
      break;
  }
  g_fluid->play(event);
}

bool parse_actions(const char* events_json, int64_t position_us) {
  g_actions.clear();
  g_next_action = 0;
  g_audio_cursor_us = std::max<double>(0.0, static_cast<double>(position_us));
  g_audio_tail_end_us = g_audio_cursor_us;

  if (!events_json || events_json[0] == '\0') {
    set_audio_error("The audio event list is empty");
    return false;
  }

  QJsonParseError parse_error;
  const QJsonDocument document = QJsonDocument::fromJson(
      QByteArray(events_json), &parse_error);
  if (!document.isArray()) {
    set_audio_error("The audio event list is not a JSON array: " +
                    parse_error.errorString().toStdString());
    return false;
  }

  const double position = g_audio_cursor_us;
  std::uint64_t next_order = 0;
  for (const QJsonValue& value : document.array()) {
    if (!value.isObject()) continue;
    const QJsonObject object = value.toObject();
    const qint64 start_value = json_integer(object, "startUs", 0);
    const qint64 default_end =
        start_value == std::numeric_limits<qint64>::max() ? start_value
                                                           : start_value + 1;
    const qint64 end_value = json_integer(object, "endUs", default_end);
    const double start_us = static_cast<double>(start_value);
    const double end_us = std::max(start_us + 1.0,
                                   static_cast<double>(end_value));
    if (end_us <= position) continue;

    const int channel =
        qBound(0, json_int(object, "channel", 0), kMaxPlaybackChannel);
    const int pitch = qBound(0, json_int(object, "pitch", 60), 127);
    const int velocity = qBound(1, json_int(object, "velocity", 80), 127);
    const int program = qBound(0, json_int(object, "program", 0), 127);
    const int bank = qBound(0, json_int(object, "bank", 0), 16383);
    const double tuning = object.contains(QLatin1String("tuning"))
                              ? json_double(object, "tuning", 0.0)
                              : json_double(object, "cents", 0.0);
    const double note_on_us = std::max(start_us, position);

    // Program changes are attached to notes by the MuseScore bridge. Sending
    // one immediately before each note preserves instrument changes without
    // requiring a second platform channel or a separate event stream.
    g_actions.push_back(
        {note_on_us, next_order++, AudioAction::Kind::program, channel, pitch,
         tuning, 0, program, bank});
    g_actions.push_back(
        {note_on_us, next_order++, AudioAction::Kind::note_on, channel, pitch,
         tuning, velocity, program, bank});
    g_actions.push_back({end_us, next_order++, AudioAction::Kind::note_off,
                         channel, pitch, tuning, 0, program, bank});
    g_audio_tail_end_us = std::max(g_audio_tail_end_us, end_us);
  }

  if (g_actions.empty()) {
    set_audio_error("The audio event list contains no playable notes");
    return false;
  }

  std::stable_sort(g_actions.begin(), g_actions.end(),
                   [](const AudioAction& left, const AudioAction& right) {
                     if (left.time_us != right.time_us)
                       return left.time_us < right.time_us;
                     return left.order < right.order;
                   });
  // Allow the SoundFont release envelope to ring out without holding the
  // platform audio stream open indefinitely.
  g_audio_tail_end_us += 750000.0 * g_audio_speed;
  return true;
}

#endif  // MUSE_READER_WITH_FLUIDSYNTH

}  // namespace

extern "C" MUSE_READER_EXPORT int muse_reader_audio_is_available(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  return 1;
#else
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_audio_initialize(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  if (!muse_reader_initialize()) {
    std::lock_guard<std::mutex> guard(g_audio_mutex);
    const char* error = muse_reader_last_error();
    set_audio_error(error && error[0] ? error :
                    "MuseScore core initialization failed");
    return 0;
  }
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  g_audio_error.clear();
  return ensure_fluid_locked() ? 1 : 0;
#else
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_audio_start_json(
    const char* events_json,
    int64_t position_us,
    double speed) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  if (!muse_reader_audio_initialize()) return 0;
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  g_audio_error.clear();
  g_audio_speed = std::isfinite(speed) ? std::clamp(speed, 0.1, 4.0) : 1.0;
  if (!parse_actions(events_json, position_us)) {
    g_audio_active = false;
    return 0;
  }
  if (!ensure_fluid_locked()) {
    g_audio_active = false;
    return 0;
  }
  g_fluid->system_reset();
  g_audio_active = true;
  return 1;
#else
  (void)events_json;
  (void)position_us;
  (void)speed;
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT size_t muse_reader_audio_render(
    float* stereo_interleaved,
    size_t frames) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  if (!stereo_interleaved || frames == 0 ||
      frames > std::numeric_limits<size_t>::max() / 2) {
    return 0;
  }
  std::fill(stereo_interleaved, stereo_interleaved + frames * 2, 0.0f);

  std::lock_guard<std::mutex> guard(g_audio_mutex);
  if (!g_audio_active || !g_fluid) return 0;

  size_t produced = 0;
  while (produced < frames) {
    while (g_next_action < g_actions.size() &&
           g_actions[g_next_action].time_us <= g_audio_cursor_us + 0.01) {
      dispatch_action(g_actions[g_next_action++]);
    }

    if (g_next_action >= g_actions.size() &&
        g_audio_cursor_us >= g_audio_tail_end_us) {
      g_audio_active = false;
      break;
    }

    size_t chunk = std::min<size_t>(frames - produced, 1024);
    if (g_next_action < g_actions.size()) {
      const double next_time = g_actions[g_next_action].time_us;
      if (next_time > g_audio_cursor_us) {
        const double frames_until =
            (next_time - g_audio_cursor_us) * kAudioSampleRate /
            (1000000.0 * g_audio_speed);
        if (frames_until < 1.0) {
          chunk = 1;
        } else {
          chunk = std::min<size_t>(chunk,
                                   static_cast<size_t>(frames_until));
        }
      }
    }
    if (chunk == 0) chunk = 1;

    g_effect1.resize(chunk * 2);
    g_effect2.resize(chunk * 2);
    std::fill(g_effect1.begin(), g_effect1.end(), 0.0f);
    std::fill(g_effect2.begin(), g_effect2.end(), 0.0f);
    g_fluid->process(static_cast<unsigned>(chunk),
                     stereo_interleaved + produced * 2, g_effect1.data(),
                     g_effect2.data());
    for (size_t index = 0; index < chunk * 2; ++index) {
      float& sample = stereo_interleaved[produced * 2 + index];
      sample = std::clamp(sample * 0.85f, -1.0f, 1.0f);
    }
    g_audio_cursor_us +=
        static_cast<double>(chunk) * 1000000.0 * g_audio_speed /
        kAudioSampleRate;
    produced += chunk;
  }
  return produced;
#else
  (void)stereo_interleaved;
  (void)frames;
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_audio_is_active(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  return g_audio_active ? 1 : 0;
#else
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT void muse_reader_audio_stop(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  if (g_fluid) g_fluid->allSoundsOff(-1);
  g_actions.clear();
  g_next_action = 0;
  g_audio_cursor_us = 0.0;
  g_audio_tail_end_us = 0.0;
  g_audio_active = false;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_audio_sample_rate(void) {
  return kAudioSampleRate;
}

extern "C" MUSE_READER_EXPORT const char* muse_reader_audio_last_error(void) {
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  std::lock_guard<std::mutex> guard(g_audio_mutex);
  return g_audio_error.c_str();
#else
  return "Bundled FluidSynth is disabled";
#endif
}
