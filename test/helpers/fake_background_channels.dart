import 'package:drift_time/platform/background_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for DriftBackground.kt, NotifyBridge.kt and WidgetsChannel.kt
/// by answering the three channels on the test messenger, and records
/// every call. [postResult] is what postSummary answers: false acts like a
/// phone without the notification permission.
class FakeBackgroundChannels {
  FakeBackgroundChannels({this.postResult = true, this.launchPayload}) {
    for (final channel in [bridge.background, bridge.notify, bridge.widgets]) {
      _messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add((channel.name, call));
        if (failing.contains(call.method)) {
          throw PlatformException(code: 'FAILED', message: 'fake failure');
        }
        return switch (call.method) {
          'postSummary' => postResult,
          'takeLaunchPayload' => launchPayload,
          _ => null,
        };
      });
    }
  }

  final bridge = BackgroundBridge();
  bool postResult;
  String? launchPayload;

  /// Methods that answer with a PlatformException.
  final failing = <String>{};

  final calls = <(String, MethodCall)>[];

  static TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// The calls of [method], oldest first.
  List<MethodCall> of(String method) => [
    for (final (_, c) in calls)
      if (c.method == method) c,
  ];

  /// What a native `invokeMethod` on [channel] gets back from Dart.
  Future<Object?> invokeFromNative(
    MethodChannel channel,
    String method, [
    Object? args,
  ]) async {
    const codec = StandardMethodCodec();
    final reply = await _messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, args)),
      null,
    );
    if (reply == null) return const _NotImplemented();
    return codec.decodeEnvelope(reply);
  }

  void dispose() {
    for (final channel in [bridge.background, bridge.notify, bridge.widgets]) {
      _messenger.setMockMethodCallHandler(channel, null);
      channel.setMethodCallHandler(null);
    }
  }
}

/// No Dart handler answered: what Kotlin sees as notImplemented.
class _NotImplemented {
  const _NotImplemented();
}

/// True when [reply] from [FakeBackgroundChannels.invokeFromNative] means
/// no handler answered.
bool isNotImplemented(Object? reply) => reply is _NotImplemented;
