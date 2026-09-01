#include "muse_reader_engine.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <mutex>
#include <string>

#if defined(MUSE_READER_WITH_MUSESCORE)
#if defined(MUSE_READER_BUILD_MUSESCORE_SOURCE)
#include "mobile_all.h"
#else
#include "all.h"
#endif
#include <QApplication>
#include <QCoreApplication>
#include <QBuffer>
#include <QByteArray>
#include <QFile>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainter>
#include <QRectF>
#include <QString>
#include <QStringRef>

#include <algorithm>
#include <deque>
#include <map>
#include <memory>

#include "chord.h"
#include "element.h"
#include "event.h"
#include "measure.h"
#include "mscore.h"
#include "musescoreCore.h"
#include "note.h"
#include "page.h"
#include "repeatlist.h"
#include "score.h"
#include "synthesizerstate.h"
#include "system.h"
#include "tempo.h"
#include "preferences.h"

#ifndef MUSE_READER_RENDER_DPI
#define MUSE_READER_RENDER_DPI 180
#endif
#endif

#if defined(MUSE_READER_WITH_MUSESCORE) && \
    defined(MUSE_READER_BUILD_MUSESCORE_SOURCE)
static void initialize_muse_reader_resources() {
  Q_INIT_RESOURCE(muse_reader_resources);
}
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

bool verify_render_resources() {
  static const char* const required_resources[] = {
      ":/fonts/smufl/glyphnames.json",
      ":/fonts/leland/metadata.json",
      ":/fonts/bravura/metadata.json",
      ":/fonts/mscore/metadata.json",
      ":/fonts/gootville/metadata.json",
      ":/fonts/musejazz/metadata.json",
      ":/fonts/petaluma/metadata.json",
      ":/fonts/leland/Leland.otf",
      ":/fonts/bravura/Bravura.otf",
      ":/fonts/mscore/mscore.ttf",
      ":/fonts/gootville/Gootville.otf",
      ":/fonts/musejazz/MuseJazz.otf",
      ":/fonts/petaluma/Petaluma.otf",
      ":/fonts/fonts_tablature.xml",
      ":/fonts/fonts_figuredbass.xml",
  };
  for (const char* path : required_resources) {
    if (!QFile::exists(QString::fromLatin1(path))) {
      set_error(QStringLiteral("Missing MuseScore rendering resource: %1")
                    .arg(QString::fromLatin1(path)));
      return false;
    }
  }
#if defined(MUSE_READER_WITH_FLUIDSYNTH)
  if (!QFile::exists(QStringLiteral(":/sound/MS Basic.sf3"))) {
    set_error(QStringLiteral(
        "Missing MuseScore playback resource: MS Basic.sf3"));
    return false;
  }
#endif
  return true;
}

bool register_text_fonts() {
  static const char* const font_resources[] = {
      ":/fonts/leland/LelandText.otf",
      ":/fonts/bravura/BravuraText.otf",
      ":/fonts/mscore/MScoreText.ttf",
      ":/fonts/gootville/GootvilleText.otf",
      ":/fonts/musejazz/MuseJazzText.otf",
      ":/fonts/petaluma/PetalumaText.otf",
      ":/fonts/petaluma/PetalumaScript.otf",
      ":/fonts/campania/Campania.otf",
      ":/fonts/edwin/Edwin-Roman.otf",
      ":/fonts/edwin/Edwin-Bold.otf",
      ":/fonts/edwin/Edwin-Italic.otf",
      ":/fonts/edwin/Edwin-BdIta.otf",
      ":/fonts/FreeSans.ttf",
      ":/fonts/FreeSerif.ttf",
      ":/fonts/FreeSerifBold.ttf",
      ":/fonts/FreeSerifItalic.ttf",
      ":/fonts/FreeSerifBoldItalic.ttf",
      ":/fonts/mscoreTab.ttf",
      ":/fonts/mscore-BC.ttf",
  };
  for (const char* path : font_resources) {
    const QString resource = QString::fromLatin1(path);
    if (!QFile::exists(resource)) {
      set_error(QStringLiteral("Missing MuseScore text font: %1").arg(resource));
      return false;
    }
    if (QFontDatabase::addApplicationFont(resource) < 0) {
      set_error(QStringLiteral("Unable to register MuseScore text font: %1")
                    .arg(resource));
      return false;
    }
  }
  return true;
}

bool initialize_musescore() {
  static bool initialized = false;
  static std::unique_ptr<Ms::MuseScoreCore> core;
  static std::unique_ptr<QApplication> qt_application;
  if (initialized) return true;
#if defined(MUSE_READER_BUILD_MUSESCORE_SOURCE)
  initialize_muse_reader_resources();
#endif
  QCoreApplication* application = QCoreApplication::instance();
  if (!application) {
#if defined(Q_OS_ANDROID)
    qputenv("QT_QPA_PLATFORM",
            QByteArrayLiteral("minimal:enable_fonts:freetype"));
#else
    qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("minimal:enable_fonts"));
#endif
    QCoreApplication::setAttribute(Qt::AA_Use96Dpi);
    static int argc = 1;
    static char application_name[] = "MuseReader";
    static char* argv[] = {application_name, nullptr};
    qt_application = std::make_unique<QApplication>(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("MuseReader"));
    QCoreApplication::setOrganizationName(QStringLiteral("MuseReader"));
    application = qt_application.get();
  }
  if (!qobject_cast<QGuiApplication*>(application)) {
    set_error(
        QStringLiteral("MuseScore rendering requires the Qt GUI runtime to "
                       "be initialized on the platform main thread"));
    return false;
  }
  if (!verify_render_resources() || !register_text_fonts()) return false;
  Ms::MScore::noGui = true;
  Ms::MScore::pdfPrinting = false;
  Ms::MScore::svgPrinting = false;
  Ms::MScore::init();
  Ms::preferences.init(true);
  core = std::make_unique<Ms::MuseScoreCore>();
  initialized = true;
  return true;
}

struct RenderedPage {
  QString base64_png;
  int pixel_width = 0;
  int pixel_height = 0;
};

class RenderStateGuard {
 public:
  explicit RenderStateGuard(Ms::MasterScore* score)
      : score_(score),
        old_printing_(score->printing()),
        old_pdf_printing_(Ms::MScore::pdfPrinting),
        old_pixel_ratio_(Ms::MScore::pixelRatio) {}

  ~RenderStateGuard() {
    score_->setPrinting(old_printing_);
    Ms::MScore::pdfPrinting = old_pdf_printing_;
    Ms::MScore::pixelRatio = old_pixel_ratio_;
  }

 private:
  Ms::MasterScore* score_;
  bool old_printing_;
  bool old_pdf_printing_;
  double old_pixel_ratio_;
};

RenderedPage render_page(Ms::MasterScore* score, int page_index) {
  Ms::Page* page = score->pages().at(page_index);
  const QRectF box = page->abbox();
  constexpr double render_dpi = MUSE_READER_RENDER_DPI;
  const double magnification = render_dpi / Ms::DPI;
  const int width = qMax(1, qRound(box.width() * magnification));
  const int height = qMax(1, qRound(box.height() * magnification));
  QImage image(width, height, QImage::Format_ARGB32_Premultiplied);
  image.setDotsPerMeterX(qRound(render_dpi * 1000.0 / Ms::INCH));
  image.setDotsPerMeterY(qRound(render_dpi * 1000.0 / Ms::INCH));
  image.fill(Qt::white);

  RenderStateGuard state(score);
  score->setPrinting(true);
  Ms::MScore::pdfPrinting = false;
  Ms::MScore::pixelRatio = 1.0 / magnification;

  QPainter painter(&image);
  painter.setRenderHint(QPainter::Antialiasing, true);
  painter.setRenderHint(QPainter::TextAntialiasing, true);
  painter.setRenderHint(QPainter::SmoothPixmapTransform, true);
  painter.scale(magnification, magnification);
  painter.translate(-box.topLeft());

  // This mirrors MuseScore::savePng(): every visible element is painted in
  // z-order. Staff lines/stems/ledger lines remain QPainter geometry, while
  // clefs, key signatures, noteheads and other SMuFL symbols go through
  // ScoreFont and FreeType. Page::draw() is included and paints headers and
  // footers, so the result is the complete engraved page rather than a subset.
  QList<Ms::Element*> elements = page->elements();
  std::stable_sort(elements.begin(), elements.end(), Ms::elementLessThan);
  for (const Ms::Element* element : elements) {
    if (!element->visible()) continue;
    painter.save();
    painter.translate(element->pagePos());
    element->draw(&painter);
    painter.restore();
  }
  painter.end();

  QByteArray png;
  QBuffer buffer(&png);
  if (!buffer.open(QIODevice::WriteOnly) || !image.save(&buffer, "PNG")) {
    set_error(QStringLiteral("MuseScore failed to encode page %1 as PNG")
                  .arg(page_index + 1));
    return {};
  }
  return {QString::fromLatin1(png.toBase64()), width, height};
}

struct PendingNote {
  int tick;
  int channel;
  int program;
  int bank;
  int pitch;
  int velocity;
  int staff;
  int voice;
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
  result.insert("pitch", note.pitch);
  result.insert("velocity", note.velocity);
  result.insert("channel", note.channel);
  result.insert("program", note.program);
  result.insert("bank", note.bank);
  result.insert("staff", note.staff);
  result.insert("voice", note.voice);
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
  if (!initialize_musescore()) return {};

  Ms::MasterScore score(Ms::MScore::baseStyle());
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
  document.insert("renderer", QStringLiteral("MuseScore 3.6.2 engraving"));
  document.insert("renderDpi", MUSE_READER_RENDER_DPI);
  document.insert("symbolFont", score.styleSt(Ms::Sid::MusicalSymbolFont));

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
    const RenderedPage rendered = render_page(&score, index);
    if (rendered.base64_png.isEmpty()) return {};
    QJsonObject page_json;
    page_json.insert("index", index);
    page_json.insert("width", box.width());
    page_json.insert("height", box.height());
    page_json.insert("pixelWidth", rendered.pixel_width);
    page_json.insert("pixelHeight", rendered.pixel_height);
    page_json.insert("image", rendered.base64_png);
    pages.append(page_json);
  }
  document.insert("pages", pages);

  QJsonArray measures;
  for (Ms::Measure* measure = score.firstMeasure(); measure;
       measure = measure->nextMeasure()) {
    QJsonObject measure_json;
    measure_json.insert("number", measure->no() + 1);
    measure_json.insert("startTick", measure->tick().ticks());
    measure_json.insert("endTick", measure->endTick().ticks());
    measures.append(measure_json);
  }
  document.insert("measures", measures);

  // renderMidi(..., expandRepeats=true, ...) is the canonical unrolled event
  // stream. Its map key is a playback tick; utick2utime applies tempo changes,
  // pauses and repeat offsets exactly as the MuseScore sequencer does.
  Ms::EventMap midi_events;
  score.renderMidi(&midi_events, false, true, Ms::defaultState);
  using NoteKey = std::pair<int, int>;
  std::map<NoteKey, std::deque<PendingNote>> active;
  std::map<int, int> programs;
  std::map<int, int> banks;
  QJsonArray events;
  int end_tick = score.repeatList().ticks();
  if (end_tick <= 0 && score.lastMeasure()) {
    end_tick = score.lastMeasure()->endTick().ticks();
  }
  for (const auto& item : midi_events) {
    const int tick = item.first;
    const Ms::NPlayEvent& event = item.second;
    end_tick = qMax(end_tick, tick);
    if (event.type() == Ms::ME_CONTROLLER) {
      const int channel = event.channel();
      const int value = qBound(0, event.value(), 127);
      if (event.controller() == Ms::CTRL_HBANK) {
        banks[channel] = (banks[channel] & 0x7f) | (value << 7);
        continue;
      }
      if (event.controller() == Ms::CTRL_LBANK) {
        banks[channel] = (banks[channel] & 0x3f80) | value;
        continue;
      }
      if (event.controller() == Ms::CTRL_PROGRAM) {
        programs[channel] = value;
        continue;
      }
    }
    const int pitch = event.pitch();
    const NoteKey key(event.channel(), pitch);
    if (event.type() == Ms::ME_NOTEON && event.velo() > 0) {
      int staff = event.getOriginatingStaff();
      int measure_number = 1;
      int voice = 0;
      int page = 0;
      QRectF page_rect;
      if (event.note() && event.note()->chord() && event.note()->chord()->measure()) {
        Ms::Measure* measure = event.note()->chord()->measure();
        staff = qMax(0, event.note()->staffIdx());
        voice = event.note()->voice();
        measure_number = measure->no() + 1;
        if (measure->system() && measure->system()->page()) {
          Ms::Page* note_page = measure->system()->page();
          page = qMax(0, score.pageIdx(note_page));
          page_rect = event.note()
                          ->pageBoundingRect()
                          .translated(-note_page->abbox().topLeft())
                          .normalized();
        }
      }
      active[key].push_back(
          {tick,
           static_cast<int>(event.channel()),
           programs[event.channel()],
           banks[event.channel()],
           pitch,
           event.velo(),
           staff,
           voice,
           measure_number,
           page,
           page_rect});
    } else if (event.type() == Ms::ME_NOTEOFF ||
               (event.type() == Ms::ME_NOTEON && event.velo() == 0)) {
      auto open = active.find(key);
      if (open == active.end() || open->second.empty()) continue;
      PendingNote note = open->second.front();
      open->second.pop_front();
      events.append(note_json(&score, note, qMax(tick, note.tick + 1)));
    }
  }
  for (const auto& entry : active) {
    for (const PendingNote& note : entry.second) {
      events.append(
          note_json(&score, note, note.tick + Ms::MScore::division));
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
  try {
    const QJsonObject document = open_with_musescore(utf8_path);
    if (document.isEmpty()) return nullptr;
    const QByteArray json =
        QJsonDocument(document).toJson(QJsonDocument::Compact);
    return copy_string(json.toStdString());
  } catch (const std::exception& error) {
    g_last_error = std::string("MuseScore rendering failed: ") + error.what();
    return nullptr;
  } catch (...) {
    g_last_error = "MuseScore rendering failed with an unknown native error";
    return nullptr;
  }
#else
  (void)utf8_path;
  g_last_error =
      "MuseScore native core is disabled; configure MUSE_READER_WITH_MUSESCORE";
  return nullptr;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_initialize(void) {
  std::lock_guard<std::mutex> guard(g_engine_mutex);
  g_last_error.clear();
#if defined(MUSE_READER_WITH_MUSESCORE)
  return initialize_musescore() ? 1 : 0;
#else
  g_last_error =
      "MuseScore native core is disabled; configure MUSE_READER_WITH_MUSESCORE";
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT int muse_reader_is_available(void) {
#if defined(MUSE_READER_WITH_MUSESCORE)
  return 1;
#else
  return 0;
#endif
}

extern "C" MUSE_READER_EXPORT void muse_reader_free_json(const char* json) {
  std::free(const_cast<char*>(json));
}

extern "C" MUSE_READER_EXPORT const char* muse_reader_last_error(void) {
  std::lock_guard<std::mutex> guard(g_engine_mutex);
  return g_last_error.c_str();
}
