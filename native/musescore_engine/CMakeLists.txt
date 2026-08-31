cmake_minimum_required(VERSION 3.18)

project(muse_reader_engine LANGUAGES CXX)

option(
  MUSE_READER_WITH_MUSESCORE
  "Link the MuseScore 3.6.2 libmscore implementation"
  OFF
)

if(NOT DEFINED MUSE_READER_ENGINE_TARGET)
  set(MUSE_READER_ENGINE_TARGET muse_reader_engine)
endif()

add_library(${MUSE_READER_ENGINE_TARGET} STATIC muse_reader_engine.cpp)
target_compile_features(${MUSE_READER_ENGINE_TARGET} PUBLIC cxx_std_17)
target_include_directories(
  ${MUSE_READER_ENGINE_TARGET}
  PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}"
)

if(MUSE_READER_WITH_MUSESCORE)
  if(NOT MUSESCORE_SOURCE_DIR)
    message(FATAL_ERROR "Set MUSESCORE_SOURCE_DIR to the MuseScore-3.6.2 checkout")
  endif()
  if(NOT MUSESCORE_LIBRARIES)
    message(FATAL_ERROR "Set MUSESCORE_LIBRARIES to the built libmscore and its dependencies")
  endif()
  if(NOT MUSESCORE_BUILD_DIR)
    message(FATAL_ERROR "Set MUSESCORE_BUILD_DIR to the matching MuseScore build directory")
  endif()

  find_package(QT NAMES Qt5 Qt6 REQUIRED COMPONENTS Core Gui Xml Svg Widgets)
  if(QT_VERSION_MAJOR EQUAL 5)
    find_package(Qt5 REQUIRED COMPONENTS
      Core Gui Network Test Qml Quick QuickControls2 QuickTemplates2
      QuickWidgets Xml XmlPatterns Svg Sql PrintSupport Concurrent OpenGL
      Help Widgets
    )
  else()
    find_package(Qt6 REQUIRED COMPONENTS Core Gui Xml Svg Widgets)
  endif()
  if(QT_VERSION_MAJOR EQUAL 6)
    find_package(Qt6 REQUIRED COMPONENTS Core5Compat)
  endif()

  target_compile_definitions(${MUSE_READER_ENGINE_TARGET} PRIVATE MUSE_READER_WITH_MUSESCORE=1)
  target_compile_options(${MUSE_READER_ENGINE_TARGET} PRIVATE
    -Wno-inconsistent-missing-override
    -Wno-deprecated-register
  )
  target_include_directories(${MUSE_READER_ENGINE_TARGET} PRIVATE
    "${MUSESCORE_BUILD_DIR}"
    "${MUSESCORE_SOURCE_DIR}/libmscore"
    "${MUSESCORE_SOURCE_DIR}"
    "${MUSESCORE_SOURCE_DIR}/audio/midi"
    "${MUSESCORE_SOURCE_DIR}/audio"
    "${MUSESCORE_SOURCE_DIR}/mscore"
    "${MUSESCORE_SOURCE_DIR}/thirdparty"
    "${MUSESCORE_SOURCE_DIR}/thirdparty/freetype/include"
    "${MUSESCORE_SOURCE_DIR}/global"
  )
  target_link_libraries(${MUSE_READER_ENGINE_TARGET} PRIVATE
    ${MUSESCORE_LIBRARIES}
    Qt${QT_VERSION_MAJOR}::Core
    Qt${QT_VERSION_MAJOR}::Gui
    Qt${QT_VERSION_MAJOR}::Xml
    Qt${QT_VERSION_MAJOR}::Svg
    Qt${QT_VERSION_MAJOR}::Widgets
  )
  if(QT_VERSION_MAJOR EQUAL 5)
    target_link_libraries(${MUSE_READER_ENGINE_TARGET} PRIVATE
      Qt5::Network
      Qt5::Test
      Qt5::Qml
      Qt5::Quick
      Qt5::QuickControls2
      Qt5::QuickTemplates2
      Qt5::QuickWidgets
      Qt5::XmlPatterns
      Qt5::Sql
      Qt5::PrintSupport
      Qt5::Concurrent
      Qt5::OpenGL
      Qt5::Help
    )
  endif()
  if(QT_VERSION_MAJOR EQUAL 6)
    target_link_libraries(${MUSE_READER_ENGINE_TARGET} PRIVATE Qt6::Core5Compat)
  endif()
endif()
