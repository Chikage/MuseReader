# MuseScore native backend

This directory contains the narrow C ABI used by the Flutter reader. The
default Flutter build does not link Qt or MuseScore; it uses the read-only Dart
compatibility parser and the platform tone fallback. Product builds that need
MuseScore 3.6.2 fidelity should enable `MUSE_READER_WITH_MUSESCORE` and link
the `libmscore` static library built from:

`/Volumes/Files/Github/MuseScore-3.6.2/`

The adapter deliberately calls the same operations used by the attached
source:

1. `MasterScore::loadMsc()` reads both MSCX and the MSCZ container.
2. `MasterScore::doLayout()` computes the page geometry.
3. `Score::print()` paints each page into a PNG without reimplementing music
   engraving in Flutter.
4. `Score::renderMidi(..., expandRepeats=true, ...)` creates the unrolled
   playback event stream.
5. `Score::utick2utime()` converts expanded ticks through the original
   `TempoMap` and `RepeatList`, including tempo changes and repeat offsets.

The JSON payload is consumed by
`lib/src/services/muse_score_bridge.dart`. Its page `image` values are base64
PNG data. Each note event contains tick and microsecond coordinates plus a
`rect` in the rendered page's coordinate system, taken from
`Note::pageBoundingRect()` after layout. This keeps visual rendering and
playback highlighting on the same source of truth. Android's
`NativeMuseScoreEngine` JNI wrapper and iOS's bridging-header call both use
this C ABI; an unavailable core returns `available: false`, so the Dart
repository can select its compatibility path deterministically.

## Building a product backend

Build a Qt kit for the target platform first, then configure this directory
with the MuseScore source and the complete set of static libraries produced by
its `libmscore` target. The exact library list is platform/toolchain-specific,
so it is passed as `MUSESCORE_LIBRARIES` rather than guessed here:

```sh
cmake -S native/musescore_engine -B build/muse_reader_engine \
  -DMUSE_READER_WITH_MUSESCORE=ON \
  -DMUSESCORE_SOURCE_DIR=/Volumes/Files/Github/MuseScore-3.6.2 \
  -DMUSESCORE_BUILD_DIR=/path/to/musescore/build \
  -DMUSESCORE_LIBRARIES="..."
cmake --build build/muse_reader_engine --config Release
```

For Android, pass the target-platform Qt and MuseScore include/library paths to
the NDK CMake target under `android/app/src/main/cpp`; it wraps the core in
`libmuse_reader_engine.so` and calls the C ABI from `MainActivity`. For iOS,
add the target-platform static libraries and Qt frameworks to the Runner
target; the checked-in C++ source is already part of that target and is called
from `AppDelegate.swift` through `Runner-Bridging-Header.h`. Do not compile
the desktop `mscore` GUI target into a mobile app.

The supplied desktop Qt5 build is useful for compiling and inspecting the
adapter, but it is not a mobile binary. A release build must use a matching
Qt/MuseScore toolchain for every shipped architecture and must include the
MuseScore data resources required by the selected fonts and instruments.

MuseScore 3.6.2 is GPLv2. Any distribution that links this adapter must ship
the corresponding license and source-offer notices. See `NOTICE-MUSESCORE.md`
at the project root.
