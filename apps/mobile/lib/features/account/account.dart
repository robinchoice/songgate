import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:altcha_lib/altcha_lib.dart' as altcha;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api.dart';
import '../converter/conversion.dart';
import '../friends/social.dart';

final secureStorageProvider = Provider((ref) => const FlutterSecureStorage());
final accountProvider = AsyncNotifierProvider<AccountController, Profile?>(
  AccountController.new,
);

/// Proof of work against bots, what the ALTCHA widget does on the web.
/// Isolates keep the UI responsive meanwhile; widget tests stub the solver,
/// their fake clock doesn't wait for isolates.
final altchaSolverProvider =
    Provider<Future<altcha.Solution?> Function(altcha.Challenge)>(
      (ref) =>
          (challenge) => altcha.solveChallengeIsolates(
            challenge: challenge,
            deriveKey: altcha.deriveKey,
            concurrency: Platform.numberOfProcessors.clamp(1, 4),
          ),
    );

/// The account with the profile other people see. Name and service are null
/// until the first login has filled them in.
class Profile {
  final String id;
  final String email;
  final String? name;
  final String? platform;

  /// Others who have the confirmed phone number in their address book find
  /// this profile by it.
  final bool discoverable;
  const Profile({
    required this.id,
    required this.email,
    this.name,
    this.platform,
    this.discoverable = false,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    email: json['email'] as String,
    name: json['name'] as String?,
    platform: platforms.containsKey(json['platform'])
        ? json['platform'] as String
        : null,
    discoverable: json['discoverable'] == true,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'email': email,
    'name': name,
    'platform': platform,
    'discoverable': discoverable,
  };

  bool get complete => name != null && platform != null;

  /// How others save this person, what an invite carries.
  Friend? get asFriend => complete ? Friend(name!, platform!, id: id) : null;
}

/// The logged-in account, or null. Token, profile and sync state live in the
/// platform keychain / keystore, so the app starts logged in even offline.
class AccountController extends AsyncNotifier<Profile?> {
  static const _tokenKey = 'session_token';
  static const _profileKey = 'profile';
  static const _revisionKey = 'social_revision';
  static const _dirtyKey = 'social_dirty';

  // The confirmed number stays on this phone only, to skip it when searching
  static const _phoneKey = 'own_phone';

  /// Revision of the contacts document on the server this device last saw
  int revision = 0;

  /// Local contact changes the server doesn't have yet
  bool dirty = false;

  Api get _api => ref.read(apiProvider);
  FlutterSecureStorage get _storage => ref.read(secureStorageProvider);

  // An unreadable keychain or keystore means logged out, never a crash
  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } on Exception {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on Exception {
      // The session lasts until the app closes
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on Exception {
      // Nothing to remove
    }
  }

  @override
  Future<Profile?> build() async {
    _api.onUnauthorized = () => unawaited(_clear());
    final token = await _read(_tokenKey);
    final saved = await _read(_profileKey);
    if (token == null || saved == null) return null;
    _api.token = token;
    revision = int.tryParse(await _read(_revisionKey) ?? '') ?? 0;
    dirty = await _read(_dirtyKey) == 'true';
    return Profile.fromJson(jsonDecode(saved) as Map<String, dynamic>);
  }

  /// Offline keeps the saved profile, an expired session logs out.
  Future<void> refresh() async {
    if (state.value == null) return;
    try {
      final json = await _api.request('GET', '/me', auth: true);
      if (json case {'user': final Map<String, dynamic> user}) {
        await _save(Profile.fromJson(user));
      }
    } on ApiException {
      // Offline keeps the saved profile, 401 logged out already
    }
  }

  /// Mails a 6-digit code after the proof of work.
  Future<void> requestCode(String email) async {
    final altcha = await _altcha();
    await _api.request(
      'POST',
      '/auth/code',
      body: {'email': email, 'altcha': altcha},
    );
  }

  /// The challenge goes back as the API sent it, its signature covers it.
  Future<String> _altcha() async {
    final challenge = await _api.request('GET', '/altcha');
    if (challenge is! Map<String, dynamic>) {
      throw ApiException(_api.locale.messages.invalidAnswer);
    }
    final solution = await ref.read(altchaSolverProvider)(
      altcha.Challenge.fromJson(challenge),
    );
    if (solution == null) {
      throw ApiException(_api.locale.messages.serviceUnavailable);
    }
    return base64Encode(
      utf8.encode(
        jsonEncode({'challenge': challenge, 'solution': solution.toJson()}),
      ),
    );
  }

  Future<Profile> verifyCode(String email, String code) async {
    final json = await _api.request(
      'POST',
      '/auth/code/verify',
      body: {'email': email, 'code': code},
    ) as Map<String, dynamic>;
    final token = json['token'] as String;
    await _write(_tokenKey, token);
    _api.token = token;
    // This phone's contacts count as not pushed yet, so nothing from the
    // account overwrites them before the first merge, see SyncService.merge
    await setSync(revision: 0, dirty: true);
    final profile = Profile.fromJson(json['user'] as Map<String, dynamic>);
    await _save(profile);
    return profile;
  }

  Future<Profile> updateProfile(String name, String platform) async {
    final json = await _api.request(
      'PATCH',
      '/me',
      body: {'name': name, 'platform': platform},
      auth: true,
    ) as Map<String, dynamic>;
    final profile = Profile.fromJson(json['user'] as Map<String, dynamic>);
    await _save(profile);
    return profile;
  }

  /// Texts a 6-digit code to [phone] (E.164).
  Future<void> requestPhoneCode(String phone) async {
    await _api.request('POST', '/me/phone', body: {'phone': phone}, auth: true);
  }

  /// Confirms [phone] with the code. From then on the account is discoverable.
  Future<Profile> verifyPhone(String phone, String code) async {
    final json = await _api.request(
      'POST',
      '/me/phone/verify',
      body: {'code': code},
      auth: true,
    ) as Map<String, dynamic>;
    await _write(_phoneKey, phone);
    final profile = Profile.fromJson(json['user'] as Map<String, dynamic>);
    await _save(profile);
    return profile;
  }

  /// The server deletes the key value of the number right away.
  Future<Profile> removePhone() async {
    final json = await _api.request(
      'DELETE',
      '/me/phone',
      auth: true,
    ) as Map<String, dynamic>;
    await _delete(_phoneKey);
    final profile = Profile.fromJson(json['user'] as Map<String, dynamic>);
    await _save(profile);
    return profile;
  }

  /// The number confirmed on this phone, E.164, null if unknown.
  Future<String?> ownPhone() => _read(_phoneKey);

  Future<void> logout() async {
    try {
      await _api.request('POST', '/auth/logout', auth: true);
    } on ApiException {
      // Logging out locally must work offline too
    }
    await _clear();
  }

  /// The server removes account, profile and contacts, this phone keeps its own.
  Future<void> delete() async {
    await _api.request('DELETE', '/me', auth: true);
    await _clear();
  }

  Future<void> setSync({int? revision, bool? dirty}) async {
    this.revision = revision ?? this.revision;
    this.dirty = dirty ?? this.dirty;
    await _write(_revisionKey, '${this.revision}');
    await _write(_dirtyKey, '${this.dirty}');
  }

  Future<void> _save(Profile profile) async {
    await _write(_profileKey, jsonEncode(profile.toJson()));
    state = AsyncData(profile);
    final me = profile.asFriend;
    if (me != null) await ref.read(socialProvider.notifier).setMe(me);
  }

  // Logs out right away, the keychain catches up. The own invite stays but
  // loses the link to the account.
  Future<void> _clear() async {
    _api.token = null;
    revision = 0;
    dirty = false;
    final me = ref.read(socialProvider).me;
    state = const AsyncData(null);
    if (me?.id != null) {
      await ref
          .read(socialProvider.notifier)
          .setMe(Friend(me!.name, me.platform));
    }
    for (final key in [
      _tokenKey,
      _profileKey,
      _revisionKey,
      _dirtyKey,
      _phoneKey,
    ]) {
      await _delete(key);
    }
  }
}
