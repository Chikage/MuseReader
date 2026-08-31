import AVFoundation
import Flutter
import Foundation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private var pendingFileResult: FlutterResult?
  private var activePicker: UIDocumentPickerViewController?
  private let synth = SimpleScoreSynth()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()

    let fileChannel = FlutterMethodChannel(
      name: "com.musereader/files",
      binaryMessenger: messenger
    )
    fileChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "pickScoreFile":
        self.presentScorePicker(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let engineChannel = FlutterMethodChannel(
      name: "com.musereader/musescore_engine",
      binaryMessenger: messenger
    )
    engineChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "open":
        let arguments = call.arguments as? [String: Any] ?? [:]
        guard let path = arguments["path"] as? String, !path.isEmpty else {
          result(["available": false])
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let document = self.nativeDocument(path: path)
          DispatchQueue.main.async {
            if let document {
              result(["available": true, "document": document])
            } else {
              result(["available": false])
            }
          }
        }
      case "startAudio":
        let arguments = call.arguments as? [String: Any] ?? [:]
        let events = arguments["events"] as? [[String: Any]] ?? []
        let positionUs = (arguments["positionUs"] as? NSNumber)?.int64Value ?? 0
        let speed = (arguments["speed"] as? NSNumber)?.doubleValue ?? 1.0
        self.synth.start(events: events, positionUs: positionUs, speed: speed)
        result(nil)
      case "stopAudio":
        self.synth.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func presentScorePicker(result: @escaping FlutterResult) {
    guard pendingFileResult == nil else {
      result(FlutterError(code: "picker_busy", message: "A file picker is already open.", details: nil))
      return
    }
    guard let presenter = topViewController() else {
      result(FlutterError(code: "no_view", message: "The reader window is unavailable.", details: nil))
      return
    }
    pendingFileResult = result
    let picker = UIDocumentPickerViewController(
      documentTypes: ["public.data", "public.zip-archive", "public.xml"],
      in: .import
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    activePicker = picker
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finishPicker(controller: controller, url: urls.first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishPicker(controller: controller, url: nil)
  }

  private func finishPicker(controller: UIDocumentPickerViewController, url: URL?) {
    let result = pendingFileResult
    pendingFileResult = nil
    activePicker = nil
    guard let result else { return }
    guard let url else {
      result(nil)
      return
    }
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("muse_reader/imports", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let extensionName = url.pathExtension.isEmpty ? "mscx" : url.pathExtension
      let target = directory.appendingPathComponent(
        "\(Int(Date().timeIntervalSince1970 * 1000))_\(url.deletingPathExtension().lastPathComponent).\(extensionName)"
      )
      try FileManager.default.copyItem(at: url, to: target)
      result(target.path)
    } catch {
      result(FlutterError(code: "copy_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func nativeDocument(path: String) -> [String: Any]? {
    let jsonPointer = path.withCString { muse_reader_open_json($0) }
    guard let jsonPointer else { return nil }
    defer { muse_reader_free_json(jsonPointer) }
    let data = Data(bytes: jsonPointer, count: strlen(jsonPointer))
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    guard var controller = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      return nil
    }
    while let presented = controller.presentedViewController {
      controller = presented
    }
    return controller
  }

  deinit {
    synth.stop()
  }
}
