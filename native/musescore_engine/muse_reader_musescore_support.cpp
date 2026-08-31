#include <QLoggingCategory>
#include <QSettings>
#include <QString>

#include "mscore/preferences.h"

Q_LOGGING_CATEGORY(undoRedo, "undoRedo", QtCriticalMsg)

namespace Ms {

QString mscoreGlobalShare = QStringLiteral(":");
QString revision = QStringLiteral("MuseReader-3.6.2");
Preferences preferences;

Preferences::Preferences() : _settings(nullptr) {}

Preferences::~Preferences() {
  delete _settings;
}

void Preferences::init(bool storeInMemoryOnly) {
  _storeInMemoryOnly = storeInMemoryOnly;
  _initialized = true;
}

QString Preferences::getString(const QString key) const {
  if (key == QStringLiteral(PREF_APP_BACKUP_SUBFOLDER)) {
    return QStringLiteral(".mscbackup");
  }
  return QString();
}

QString resourcePath() {
  return QStringLiteral(":");
}

QString sharePath() {
  return QStringLiteral(":/");
}

}  // namespace Ms
