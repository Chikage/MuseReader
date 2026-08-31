#include "muse_reader_engine.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

#if defined(MUSE_READER_WITH_MUSESCORE)
#include "all.h"
#include <QBuffer>
#include <QComboBox>
#include <QByteArray>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QRectF>
#include <QString>
#include <QStringRef>

#include <deque>
#include <map>

#include "chord.h"
#include "event.h"
#include "measure.h"
#include "mscore.h"
#include "note.h"
#include "page.h"
#include "repeatlist.h"
#include "score.h"
#include "synthesizerstate.h"
#include "system.h"
#include "tempo.h"
#endif

namespace {
std::mutex g_engine_mutex;
std::string g_last_error;

const char* copy_string(const std::string& value) {
  auto* result = static_cast<char*>(std::malloc(value.size() + 1));
  if (!result) return nullptr;
  std::memcpy(result, value.data(), value.size());
  result[value.size()] = '\0';
  return result;
}

#if defined(MUSE_READER_WITH_MUSESCORE)
void set_error(const QString& error) {
  g_last_error = error.toUtf8().toStdString();
}

QString render_page(Ms::MasterScore* score, int page_index) {
  Ms::Page* page = score->pages().at(page_index);
  const QRectF box = page->abbox();
  const int width = qMax(1, qCeil(box.width()));
  const int height = qMax(1, qCeil(box.height()));
  QImage image(width, height, QImage::Format_ARGB32_Premultiplied);
  image.fill(Qt::white);

  QPainter painter(&image);
  painter.setRenderHint(QPainter::Antialiasing, true);
  painter.setRenderHint(QPainter::TextAntialiasing, true);
  painter.translate(-box.topLeft());
  score->print(&painter, page_index);
  painter.end();

  QByteArray png;
  QBuffer buffer(&png);
  buffer.open(QIODevice::WriteOnly);
  image.save(&buffer, "PNG");
  return QString::fromLatin1(png.toBase64());
}

struct PendingNote {
  int tick;
  int velocity;
  int staff;
  int measure;
  int page;
  QRectF page_rect;
};

QJsonObject note_json(
    Ms::MasterScore* score,
    const PendingNote& note,
    int end_tick) {
  QJsonObject result;
  const qreal start_time = score->utick2utime(note.tick);
  const qreal end_time = score->utick2utime(end_tick);
  result.insert("startTick", note.tick);
  result.insert("endTick", end_tick);
  result.insert("startUs", qRound64(start_time * 1000000.0));
  result.insert("endUs", qRound64(end_time * 1000000.0));
  result.insert("pitch", 0);
  result.insert("velocity", note.velocity);
  result.insert("staff", note.staff);
  result.insert("voice", 0);
  result.insert("measure", note.measure);
  result.insert("page", note.page);
  if (!note.page_rect.isEmpty()) {
    QJsonObject rect;
    rect.insert("x", note.page_rect.x());
    rect.insert("y", note.page_rect.y());
    rect.insert("width", note.page_rect.width());
    rect.insert("height", note.page_rect.height());
    result.insert("rect", rect);
  }
  return result;
}

QJsonObject open_with_musescore(const char* utf8_path) {
  static std::once_flag init_flag;
  std::call_once(init_flag, [] {
    Ms::MScore::init();
  });

  Ms::MasterScore score;
  const auto error = score.loadMsc(QString::fromUtf8(utf8_path), true);
  if (error != Ms::Score::FileError::FILE_NO_ERROR) {
    set_error(QStringLiteral("MuseScore failed to load the score (%1)")
                  .arg(static_cast<int>(error)));
    return {};
  }

  // Layout is the source of truth for every page image. No Flutter-side
  // geometry is used when this backend is enabled.
  score.doLayout();

  QJsonObject document;
  document.insert("title", score.metaTags().value("workTitle"));
  document.insert("composer", score.metaTags().value("composer"));
  document.insert("division", Ms::MScore::division);

  QJsonArray tempos;
  if (score.tempomap() && !score.tempomap()->empty()) {
    for (const auto& entry : *score.tempomap()) {
      QJsonObject tempo;
      tempo.insert("tick", entry.first);
      tempo.insert("qps", entry.second.tempo);
      tempos.append(tempo);
    }
  } else {
    QJsonObject tempo;
    tempo.insert("tick", 0);
    tempo.insert("qps", 2.0);
    tempos.append(tempo);
  }
  document.insert("tempos", tempos);

  QJsonArray pages;
  for (int index = 0; index < score.pages().size(); ++index) {
    Ms::Page* page = score.pages().at(index);
    const QRectF box = page->abbox();
    QJsonObject page_json;
    page_json.insert("index", index);
    page_json.insert("width", box.width());
    page_json.insert("height", box.height());
    page_json.insert("image", render_page(&score, index));
    pages.append(page_json);
  }
  document.insert("pages", pages);

  QJsonArray measures;
  for (Ms::Measure* measure = score.firstMeasure(); measure;
       measure = measure->nextMeasure()) {
    QJsonObject measure_json;
    measure_json.insert("number", measure->no());
    measure_json.insert("startTick", measure->tick().ticks());
    measure_json.insert("endTick", measure->endTick().ticks());
    measures.append(measure_json);
  }
  document.insert("measures", measures);

  // renderMidi(..., expandRepeats=true, ...) is the canonical unrolled event
  // stream. Its map key is a playback tick; utick2utime applies tempo changes,
  // pauses and repeat offsets exactly as the MuseScore sequencer does.
  Ms::EventMap midi_events;
  score.renderMidi(&midi_events, false, true, Ms::SynthesizerState());
  using NoteKey = std::pair<int, int>;
  std::map<NoteKey, std::deque<PendingNote>> active;
  QJsonArray events;
  int end_tick = score.repeatList().ticks();
  if (end_tick <= 0 && score.lastMeasure()) {
    end_tick = score.lastMeasure()->endTick().ticks();
  }
  for (const auto& item : midi_events) {
    const int tick = item.first;
    const Ms::NPlayEvent& event = item.second;
    end_tick = qMax(end_tick, tick);
    const int pitch = event.pitch();
    const NoteKey key(event.channel(), pitch);
    if (event.type() == Ms::ME_NOTEON && event.velo() > 0) {
      int staff = event.getOriginatingStaff();
      int measure_number = 1;
      int page = 0;
      QRectF page_rect;
      if (event.note() && event.note()->chord() && event.note()->chord()->measure()) {
        Ms::Measure* measure = event.note()->chord()->measure();
        staff = qMax(0, event.note()->staffIdx());
        measure_number = measure->no();
        if (measure->system() && measure->system()->page()) {
          Ms::Page* note_page = measure->system()->page();
          page = score.pageIdx(note_page);
          page_rect = event.note()
                          ->pageBoundingRect()
                          .translated(-note_page->abbox().topLeft())
                          .normalized();
        }
      }
      active[key].push_back(
          {tick, event.velo(), staff, measure_number, page, page_rect});
    } else if (event.type() == Ms::ME_NOTEOFF ||
               (event.type() == Ms::ME_NOTEON && event.velo() == 0)) {
      auto open = active.find(key);
      if (open == active.end() || open->second.empty()) continue;
      PendingNote note = open->second.front();
      open->second.pop_front();
      QJsonObject item_json =
          note_json(&score, note, qMax(tick, note.tick + 1));
      item_json.insert("pitch", pitch);
      events.append(item_json);
    }
  }
  for (const auto& entry : active) {
    for (const PendingNote& note : entry.second) {
      QJsonObject item_json = note_json(
          &score, note, note.tick + Ms::MScore::division);
      item_json.insert("pitch", entry.first.second);
      events.append(item_json);
      end_tick = qMax(end_tick, note.tick + Ms::MScore::division);
    }
  }
  document.insert("events", events);
  document.insert("endTick", end_tick);
  document.insert("durationUs", qRound64(score.utick2utime(end_tick) * 1000000.0));
  return document;
}
#endif
}  // namespace

extern "C" MUSE_READER_EXPORT const char* muse_reader_open_json(
    const char* utf8_path) {
  std::lock_guard<std::mutex> guard(g_engine_mutex);
  g_last_error.clear();
  if (!utf8_path || utf8_path[0] == '\0') {
    g_last_error = "The score path is empty";
    return nullptr;
  }

#if defined(MUSE_READER_WITH_MUSESCORE)
  const QJsonObject document = open_with_musescore(utf8_path);
  if (document.isEmpty()) return nullptr;
  const QByteArray json = QJsonDocument(document).toJson(QJsonDocument::Compact);
  return copy_string(json.toStdString());
#else
  (void)utf8_path;
  g_last_error =
      "MuseScore native core is disabled; configure MUSE_READER_WITH_MUSESCORE";
  return nullptr;
#endif
}

extern "C" MUSE_READER_EXPORT void muse_reader_free_json(const char* json) {
  std::free(const_cast<char*>(json));
}

extern "C" MUSE_READER_EXPORT const char* muse_reader_last_error(void) {
  std::lock_guard<std::mutex> guard(g_engine_mutex);
  return g_last_error.c_str();
}
