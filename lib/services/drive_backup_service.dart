import 'dart:async';
import 'dart:io' show HandshakeException, SocketException;
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_services.dart';
import '../providers/settings_provider.dart';
import 'backup_codec.dart';

/// A downloaded Drive backup: the parsed payload plus when it was uploaded,
/// so the confirmation can say which backup is about to replace the data.
class CloudBackup {
  const CloudBackup({
    required this.data,
    required this.createdAt,
    required this.name,
  });

  final Map<String, dynamic> data;
  final DateTime createdAt;
  final String name;
}

/// Shown when Drive access has to be granted again. The Backup group
/// offers Reconnect for it.
const kDriveReconnectMessage =
    'Reconnect Google Drive in Settings to keep backing up.';

/// Why Drive access could not be had. [message] is shown as is.
class DriveAuthException implements Exception {
  const DriveAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Drive could not be reached: no network, or it timed out. Never
/// recorded as [DriveBackupService.lastError], since the next start or
/// resume simply tries again.
class DriveOfflineException implements Exception {
  const DriveOfflineException();

  String get message =>
      "Couldn't reach Google Drive. Check the connection and try again.";

  @override
  String toString() => message;
}

bool _isOffline(Object e) =>
    e is SocketException ||
    e is TimeoutException ||
    e is HandshakeException ||
    e is http.ClientException;

/// [op], with network failures turned into [DriveOfflineException].
Future<T> _offlineAware<T>(Future<T> Function() op) async {
  try {
    return await op();
  } catch (e) {
    if (_isOffline(e)) {
      debugPrint('Drive unreachable: $e');
      throw const DriveOfflineException();
    }
    rethrow;
  }
}

/// Drive access tokens, behind a seam so tests can fake Google.
abstract class DriveAuth {
  /// A token for [scopes] without any UI, or null when the user has to
  /// grant access first. [email] pins the account; without it Google Play
  /// services picks one.
  Future<String?> silentToken(List<String> scopes, {String? email});

  /// Asks the user (account picker, then consent; with [email], that
  /// account's consent only). Throws [DriveAuthException] when cancelled
  /// or refused. Only from a tap.
  Future<String> interactiveToken(List<String> scopes, {String? email});

  /// Drops a token Google rejected, so the next request gets a fresh one.
  Future<void> forget(String accessToken);

  Future<void> signOut();
}

/// [DriveAuth] over google_sign_in 7's authorization client. Authorization
/// only, no sign-in: that needs just the Android OAuth client (package and
/// signing SHA-1), not the Web client ID a Credential Manager sign-in does.
class GoogleDriveAuth implements DriveAuth {
  Future<void>? _init;

  Future<void> _ready() =>
      _init ??= GoogleSignIn.instance.initialize().catchError((Object e) {
        _init = null; // retry next time rather than cache the failure
        throw e;
      });

  static const _cancelled = DriveAuthException(
    'Google Drive access was cancelled.',
  );
  static const _notSetUp = DriveAuthException(
    "Google Drive access isn't set up for this build of the app.",
  );

  /// Android's authorize path reports most failures as unknownError with
  /// the Play services status code in the text ("SDK reported an
  /// exception: 16: ..."): 16 is CANCELED, 10 DEVELOPER_ERROR (the OAuth
  /// client's package or signing SHA-1 doesn't match this build).
  @visibleForTesting
  static DriveAuthException mapped(GoogleSignInException e) {
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
      case GoogleSignInExceptionCode.interrupted:
        return _cancelled;
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.providerConfigurationError:
        return _notSetUp;
      default:
        final status = RegExp(
          r'exception: (\d+)',
        ).firstMatch(e.description ?? '')?.group(1);
        if (status == '16') return _cancelled;
        if (status == '10') return _notSetUp;
        debugPrint('Google Drive authorization failed: ${e.description}');
        return const DriveAuthException(
          "Google Drive access didn't go through. Try again.",
        );
    }
  }

  /// Through the platform interface rather than
  /// `GoogleSignIn.instance.authorizationClient`, whose requests never name
  /// an account: without one, Play services picks the app's default
  /// account, which only a (never used) Credential Manager sign-in sets.
  Future<String?> _authorize(
    List<String> scopes, {
    required String? email,
    required bool prompt,
  }) async {
    await _ready();
    try {
      final data = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
            ClientAuthorizationTokensForScopesParameters(
              request: AuthorizationRequestDetails(
                scopes: scopes,
                userId: null,
                email: email,
                promptIfUnauthorized: prompt,
              ),
            ),
          );
      return data?.accessToken;
    } on GoogleSignInException catch (e) {
      throw mapped(e);
    }
  }

  @override
  Future<String?> silentToken(List<String> scopes, {String? email}) =>
      _authorize(scopes, email: email, prompt: false);

  @override
  Future<String> interactiveToken(List<String> scopes, {String? email}) async {
    final token = await _authorize(scopes, email: email, prompt: true);
    if (token == null) throw _cancelled;
    return token;
  }

  @override
  Future<void> forget(String accessToken) async {
    try {
      await _ready();
      await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(
        accessToken: accessToken,
      );
    } catch (_) {
      // Best effort: an unusable token simply fails again.
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _ready();
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Nothing signed in, or no plugin (tests).
    }
  }
}

/// Google Drive backup, ported from the expense tracker: a daily or weekly
/// upload of the gzipped JSON backup into a visible "Drift Backups" folder
/// in My Drive, and restore of the newest one.
///
/// One-time setup in Google Cloud Console: a project with the Drive API
/// on and an OAuth consent screen listing the account, plus an Android
/// OAuth client for `io.github.santhoshunt.drift` with the release
/// signing SHA-1. No google-services.json and no Web client ID. A missing
/// or mismatched client shows as "isn't set up for this build".
///
/// The scope is `drive.file`: the app sees only files it created, and
/// that access survives reinstalls.
///
/// google_sign_in 7 keeps no signed-in user, so "connected" is the email
/// stored at connect time. Drift never shipped google_sign_in 6, so the
/// expense tracker's adoption of a 6.x connection is not ported.
class DriveBackupService {
  DriveBackupService({DriveAuth? auth, http.Client Function()? httpClient})
    : _auth = auth ?? GoogleDriveAuth(),
      _httpClient = httpClient ?? http.Client.new;

  static const freqKey = 'drive_backup_frequency_v1';
  static const lastKey = 'drive_last_backup_at_v1';
  static const folderIdKey = 'drive_backup_folder_id_v1';
  static const lastErrorKey = 'drive_last_error_v1';
  static const emailKey = 'drive_connected_email_v1';
  static const connectedAtKey = 'drive_connected_at_v1';

  static const folderName = 'Drift Backups';
  static const filePrefix = 'drift_backup_';

  /// How many backups stay in Drive; older ones are pruned after each upload.
  static const keepBackups = 7;

  static const frequencies = ['daily', 'weekly', 'off'];

  static const _scopes = [drive.DriveApi.driveFileScope];

  final DriveAuth _auth;
  final http.Client Function() _httpClient;

  /// The token of the last Drive request, for [disconnect] to drop.
  String? _lastToken;

  // Connection

  /// The connected Google account's email, or null when Drive backup is
  /// off. Never shows UI.
  Future<String?> connectedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(emailKey);
  }

  /// Asks for Drive access (account picker, consent) and remembers the
  /// account. Only from an explicit tap. Throws [DriveAuthException] when
  /// it doesn't happen.
  ///
  /// The connect time is the schedule's starting point, so the first
  /// automatic backup waits one period. On a new phone that leaves time to
  /// restore before this phone's few days of history become the newest
  /// backup. "Back up now" still uploads at once.
  Future<String> connect() async {
    try {
      final token = await _auth.interactiveToken(_scopes);
      final email = await _emailFor(token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(emailKey, email);
      await prefs.setString(connectedAtKey, DateTime.now().toIso8601String());
      await prefs.remove(lastErrorKey);
      return email;
    } on DriveAuthException {
      rethrow;
    } catch (e) {
      debugPrint('Drive connect failed: $e');
      throw const DriveAuthException(
        "Couldn't connect Google Drive. Check the connection and try again.",
      );
    }
  }

  Future<void> disconnect() async {
    final token = _lastToken;
    _lastToken = null;
    if (token != null) await _auth.forget(token);
    await _auth.signOut();
    final prefs = await SharedPreferences.getInstance();
    // Account-scoped state must not survive a disconnect: a stale error
    // banner would contradict "Off until connected", and a stale last
    // backup time would show for an account never backed up.
    for (final key in [emailKey, folderIdKey, lastKey, lastErrorKey, connectedAtKey]) {
      await prefs.remove(key);
    }
  }

  /// The account behind [token], from Drive's own about.get (allowed under
  /// `drive.file`), so no Google sign-in is needed to name it.
  Future<String> _emailFor(String token) async {
    final about = await _withDrive(
      (api) => api.about.get($fields: 'user(emailAddress)'),
      firstToken: token,
    );
    final email = about.user?.emailAddress;
    if (email == null || email.isEmpty) {
      throw const DriveAuthException(
        "Couldn't read which Google account was connected.",
      );
    }
    return email;
  }

  /// A fresh token for each operation, for the stored account. Null from
  /// the silent path means access has to be granted again: a tap
  /// ([interactive]) asks for it there and then; a scheduled run records
  /// the reconnect message.
  Future<String> _token({bool interactive = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString(emailKey);
    var token = await _auth.silentToken(_scopes, email: email);
    if (token == null && interactive) {
      token = await _auth.interactiveToken(_scopes, email: email);
    }
    if (token == null) throw const DriveAuthException(kDriveReconnectMessage);
    _lastToken = token;
    return token;
  }

  Future<T> _run<T>(
    String token,
    Future<T> Function(drive.DriveApi api) op,
  ) async {
    final base = _httpClient();
    final client = authenticatedClient(
      base,
      AccessCredentials(
        AccessToken(
          'Bearer',
          token,
          DateTime.now().toUtc().add(const Duration(minutes: 55)),
        ),
        null,
        _scopes,
      ),
    );
    try {
      return await op(drive.DriveApi(client));
    } finally {
      client.close();
      base.close();
    }
  }

  /// Runs [op] against Drive. A token Google rejects is dropped and the
  /// operation retried once with a fresh one. Google answers a bad token
  /// with 401 plus `WWW-Authenticate`, which googleapis_auth turns into
  /// [AccessDeniedException]; a bare 401 arrives as
  /// [drive.DetailedApiRequestError].
  Future<T> _withDrive<T>(
    Future<T> Function(drive.DriveApi api) op, {
    String? firstToken,
    bool interactive = false,
  }) async {
    final token = firstToken ?? await _token(interactive: interactive);
    _lastToken = token;
    try {
      return await _run(token, op);
    } on Exception catch (e) {
      final rejected =
          e is AccessDeniedException ||
          (e is drive.DetailedApiRequestError && e.status == 401);
      if (!rejected) rethrow;
      await _auth.forget(token);
      return _run(await _token(interactive: interactive), op);
    }
  }

  // Preferences

  /// `daily`, `weekly` or `off`; daily until changed.
  Future<String> getFrequency() async {
    final prefs = await SharedPreferences.getInstance();
    final f = prefs.getString(freqKey);
    return frequencies.contains(f) ? f! : 'daily';
  }

  Future<void> setFrequency(String freq) async {
    assert(frequencies.contains(freq));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(freqKey, freq);
  }

  Future<DateTime?> lastBackupAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(lastKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Why the most recent backup attempt failed, or null when it succeeded.
  /// Scheduled runs swallow errors so startup never fails, so Settings
  /// shows this instead.
  Future<String?> lastError() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(lastErrorKey);
  }

  // Folder

  /// Finds or creates the visible backups folder in My Drive. The id is
  /// cached in prefs; a folder the user deleted is created again.
  Future<String> _folderId(drive.DriveApi api) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(folderIdKey);
    if (cached != null) {
      try {
        final f =
            await api.files.get(cached, $fields: 'id, trashed') as drive.File;
        if (f.trashed != true) return cached;
      } catch (_) {
        // 404: look it up or create it below.
      }
    }
    final existing = await api.files.list(
      q:
          "name = '$folderName' and "
          "mimeType = 'application/vnd.google-apps.folder' and trashed = false",
      $fields: 'files(id)',
      pageSize: 1,
    );
    String? id = existing.files?.firstOrNull?.id;
    id ??= (await api.files.create(
      drive.File()
        ..name = folderName
        ..mimeType = 'application/vnd.google-apps.folder',
    )).id;
    if (id == null) throw Exception('Could not create the Drive folder');
    await prefs.setString(folderIdKey, id);
    return id;
  }

  // Backup

  @visibleForTesting
  static String backupFileName(DateTime now) =>
      '$filePrefix${now.toIso8601String().split('.').first.replaceAll(':', '-')}'
      '.json.gz';

  /// A second uploadNow while one is in flight joins it instead of running
  /// a duplicate (a scheduled upload racing a "Back up now" tap).
  Future<String>? _inFlightUpload;

  /// Uploads a fresh backup and prunes old ones down to [keepBackups].
  /// Returns the uploaded file name. [interactive] (a tap) may ask for
  /// Drive access again when it was lost; the scheduled run never does.
  Future<String> uploadNow(
    AppServices services,
    SettingsProvider settings, {
    bool interactive = false,
  }) {
    return _inFlightUpload ??= () async {
      try {
        return await _offlineAware(
          () => _uploadNow(services, settings, interactive: interactive),
        );
      } catch (e) {
        // Recorded so Settings shows it after the toast is gone. Being
        // offline is not a failure worth a banner.
        if (e is DriveOfflineException) rethrow;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(lastErrorKey, '$e');
        } catch (_) {
          // Recording failed too; the rethrow still surfaces it.
        }
        rethrow;
      } finally {
        _inFlightUpload = null;
      }
    }();
  }

  Future<String> _uploadNow(
    AppServices services,
    SettingsProvider settings, {
    required bool interactive,
  }) async {
    // The snapshot comes before any network await: authorization and the
    // folder lookup take seconds, and a restore landing in that window
    // must not be what gets uploaded half-done.
    final payload = await exportAll(services, settings);
    final bytes = await encodeBackupGzAsync(payload);
    final now = DateTime.now();
    final name = backupFileName(now);

    return _withDrive(interactive: interactive, (api) async {
      final folderId = await _folderId(api);
      // A fresh Media per attempt: its stream is single-subscription, so it
      // must never be reused across retries (the 401 retry included).
      await api.files.create(
        drive.File()
          ..name = name
          ..mimeType = 'application/gzip'
          ..parents = [folderId],
        uploadMedia: drive.Media(
          Stream.fromIterable([bytes]),
          bytes.length,
          contentType: 'application/gzip',
        ),
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(lastKey, now.toIso8601String());
      await prefs.remove(lastErrorKey);
      await _prune(api, folderId);
      return name;
    });
  }

  /// Keeps the newest [keepBackups]. Best effort: a prune hiccup must not
  /// fail the upload that just succeeded.
  Future<void> _prune(drive.DriveApi api, String folderId) async {
    try {
      final all = <drive.File>[];
      String? pageToken;
      do {
        final listed = await api.files.list(
          q:
              "'$folderId' in parents and name contains '$filePrefix' "
              'and trashed = false',
          orderBy: 'createdTime desc',
          $fields: 'nextPageToken, files(id, name, createdTime)',
          pageSize: 100,
          pageToken: pageToken,
        );
        all.addAll(listed.files ?? const <drive.File>[]);
        pageToken = listed.nextPageToken;
      } while (pageToken != null);
      for (final f in all.skip(keepBackups)) {
        final id = f.id;
        if (id != null) await api.files.delete(id);
      }
    } catch (e) {
      debugPrint('Drive prune failed (upload succeeded): $e');
    }
  }

  /// Downloads the newest backup, parsed and ready for [restore]. Throws
  /// [FormatException] when there is none.
  ///
  /// Falls back to the next-newest files when the newest is corrupt (an
  /// upload cut off mid-way), so one bad file doesn't hide every good one.
  Future<CloudBackup> downloadLatest({bool interactive = false}) =>
      _offlineAware(
        () => _withDrive(_downloadLatest, interactive: interactive),
      );

  Future<CloudBackup> _downloadLatest(drive.DriveApi api) async {
    final folderId = await _folderId(api);
    final listed = await api.files.list(
      q:
          "'$folderId' in parents and name contains '$filePrefix' "
          'and trashed = false',
      orderBy: 'createdTime desc',
      $fields: 'files(id, name, createdTime)',
      pageSize: 5,
    );
    final candidates = listed.files ?? const <drive.File>[];
    if (candidates.isEmpty) {
      throw const FormatException(
        'No backup found in "$folderName" for this Google account.',
      );
    }
    Object? lastError;
    for (final f in candidates) {
      final id = f.id;
      if (id == null) continue;
      try {
        final media =
            await api.files.get(
                  id,
                  downloadOptions: drive.DownloadOptions.fullMedia,
                )
                as drive.Media;
        final builder = BytesBuilder(copy: false);
        await for (final chunk in media.stream) {
          builder.add(chunk);
        }
        final data = await decodeBackupGzAsync(builder.takeBytes());
        return CloudBackup(
          data: data,
          createdAt: (f.createdTime ?? DateTime.now()).toLocal(),
          name: f.name ?? '',
        );
      } on FormatException catch (e) {
        debugPrint('Skipping corrupt Drive backup ${f.name}: $e');
        lastError = e;
      }
    }
    if (lastError is FormatException) throw lastError;
    throw const FormatException('Every Drive backup failed to decode.');
  }

  /// Replaces everything on this phone with [backup]. A backup from
  /// another app or a newer Drift throws [BackupFormatException] before
  /// anything changes.
  Future<void> restore(
    CloudBackup backup,
    AppServices services,
    SettingsProvider settings,
  ) => importAll(services, settings, backup.data);

  // Scheduled check, on app start and resume

  /// Uploads silently when the frequency says one is due. Never throws;
  /// failures land in [lastError] for Settings to show, except being
  /// offline, which leaves it alone.
  Future<void> checkAndRunScheduled(
    AppServices services,
    SettingsProvider settings,
  ) async {
    try {
      final email = await connectedEmail();
      if (email == null) return; // opt-in: not connected
      final freq = await getFrequency();
      if (freq == 'off') return;
      // An empty database must never become the newest backup: it would
      // push the real ones toward the retention limit.
      if (!await _hasData(services)) return;
      final prefs = await SharedPreferences.getInstance();
      final last =
          await lastBackupAt() ??
          DateTime.tryParse(prefs.getString(connectedAtKey) ?? '');
      if (!isDue(last, freq, DateTime.now())) return;
      await uploadNow(services, settings);
    } catch (e) {
      // Offline on start or resume is common; the next one tries again.
      if (e is DriveOfflineException || _isOffline(e)) return;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(lastErrorKey, '$e');
      } catch (_) {
        // Even recording the failure failed; nothing more to do silently.
      }
    }
  }

  static Future<bool> _hasData(AppServices s) async {
    final rows = await s.db.rawQuery(
      'SELECT (SELECT COUNT(*) FROM blocks) + (SELECT COUNT(*) FROM sessions) '
      'AS n',
    );
    return ((rows.first['n'] as int?) ?? 0) > 0;
  }

  /// Daily waits at least 23 hours, weekly 6 days; off is never due.
  @visibleForTesting
  static bool isDue(DateTime? last, String freq, DateTime now) {
    if (freq == 'off') return false;
    if (last == null) return true;
    // Clock moved backwards: a "future" last backup would otherwise stall
    // the schedule.
    if (last.isAfter(now)) return true;
    final diff = now.difference(last);
    return switch (freq) {
      'weekly' => diff.inDays >= 6,
      _ => diff.inHours >= 23,
    };
  }

  // Display helpers

  static String freqLabel(String freq) => switch (freq) {
    'weekly' => 'Weekly',
    'off' => 'Off',
    _ => 'Daily',
  };

  /// "Never", "Just now", "12 min ago", "3 h ago", then the date.
  static String formatLastBackup(DateTime? dt, {DateTime? now}) {
    if (dt == null) return 'Never';
    final diff = (now ?? DateTime.now()).difference(dt);
    if (diff.inMinutes < 2) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    return DateFormat('d MMM y').format(dt);
  }

  /// The date and time a restore confirmation names, such as
  /// "19 Oct 2026, 08:00".
  static String formatBackupDate(DateTime dt) =>
      DateFormat('d MMM y, HH:mm').format(dt);
}
