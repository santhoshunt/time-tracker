import 'package:flutter/services.dart';

/// The launcher icon aliases declared in AndroidManifest.xml, default
/// first. Frozen for the life of the app: a removed alias would strand its
/// launcher entry.
const iconAliasNames = [
  'IconMeltingClock',
  'IconTimeRiver',
  'IconSlidingDay',
  'IconNeedle',
  'IconWanderer',
  'IconEscape',
];

/// Switches the launcher icon. [ChannelIconSwitcher] talks to Android;
/// tests use fakes.
abstract class IconSwitcher {
  /// The enabled alias name, one of [iconAliasNames].
  Future<String> current();

  /// Enables [aliasName] and disables the rest. Launchers may take a moment
  /// to show the change.
  Future<void> set(String aliasName);
}

/// [IconSwitcher] over the `drift/icon` method channel (IconSwitcher.kt).
class ChannelIconSwitcher implements IconSwitcher {
  const ChannelIconSwitcher({
    this.channel = const MethodChannel('drift/icon'),
  });

  final MethodChannel channel;

  /// Falls back to the manifest default when Android can't say.
  @override
  Future<String> current() async {
    try {
      final name = await channel.invokeMethod<String>('current');
      return iconAliasNames.contains(name) ? name! : iconAliasNames.first;
    } on PlatformException {
      return iconAliasNames.first;
    } on MissingPluginException {
      return iconAliasNames.first;
    }
  }

  /// Throws [ArgumentError] for a name not in [iconAliasNames]. A native
  /// failure propagates as [PlatformException], so the picker can say the
  /// icon did not change.
  @override
  Future<void> set(String aliasName) async {
    if (!iconAliasNames.contains(aliasName)) {
      throw ArgumentError.value(aliasName, 'aliasName', 'Unknown launcher icon');
    }
    await channel.invokeMethod<void>('set', {'name': aliasName});
  }
}
