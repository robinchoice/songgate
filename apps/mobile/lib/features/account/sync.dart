import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/locale.dart';
import '../converter/conversion.dart';
import '../friends/social.dart';
import 'account.dart';

final syncProvider = Provider(SyncService.new);

/// How often the services of linked contacts are looked up at most
const _profileInterval = Duration(minutes: 5);

/// Keeps the contacts of the local `Social` and the account's document equal
/// and follows the services of linked contacts. Without a login it does
/// nothing. The server's revision decides: a document that moved on wins.
class SyncService {
  final Ref ref;
  SyncService(this.ref);

  /// Shows a message to the person, set by [SyncOnResume]
  void Function(String text)? onNotice;

  Future<void> _queue = Future.value();
  int _version = 0;
  DateTime? _profilesAt;

  Api get _api => ref.read(apiProvider);
  AccountController get _account => ref.read(accountProvider.notifier);
  bool get _loggedIn => ref.read(accountProvider).value != null;

  /// Contacts sync once the profile is complete: the first merge comes before.
  bool get _active => ref.read(accountProvider).value?.complete ?? false;

  /// Launch, resume and opening the contacts: the account first, then its
  /// contacts, then the linked profiles.
  Future<void> refresh({bool profiles = true}) async {
    await ref.read(socialProvider.notifier).loaded;
    await ref.read(accountProvider.future);
    if (_loggedIn) {
      await _account.refresh();
      await pull();
    }
    if (profiles) await refreshProfiles();
  }

  /// A change on this phone, pushed as soon as the account is known and the
  /// network is there. Without a login the contacts stay local.
  void localChange() {
    if (!_active) return;
    _version++;
    unawaited(_account.setSync(dirty: true));
    _queue = _queue.then((_) => _push());
  }

  Future<void> _push() async {
    if (!_active || !_account.dirty) return;
    final sent = _version;
    try {
      final json = await _api.request(
        'PUT',
        '/me/social',
        body: {
          'social': ref.read(socialProvider).syncJson(),
          'revision': _account.revision,
        },
        auth: true,
      ) as Map<String, dynamic>;
      await _account.setSync(
        revision: json['revision'] as int,
        dirty: sent != _version,
      );
    } on ApiException catch (error) {
      if (error.status == 409) await _union(error.body);
      // Otherwise it stays dirty and goes out with the next chance
    }
  }

  /// Newer on the server and nothing waiting here: take it over. A change
  /// made on this phone meanwhile is pushed instead and meets the newer
  /// version as a conflict, see [_union].
  Future<void> pull() async {
    if (!_active) return;
    if (_account.dirty) {
      await _queue;
      _queue = _queue.then((_) => _push());
      await _queue;
      if (_account.dirty) return;
    }
    final before = _version;
    try {
      final json = await _api.request('GET', '/me/social', auth: true);
      if (json case {'revision': final int revision}
          when revision > _account.revision &&
              before == _version &&
              !_account.dirty) {
        await _adopt(json);
      }
    } on ApiException {
      // Offline or logged out, the local contacts stay
    }
  }

  /// First login of this phone: the local contacts go to the account. Login
  /// leaves them marked as not pushed at revision 0, so an account that has
  /// contacts already answers with a conflict and [_union] joins both. Until
  /// then, also after a restart or offline, nothing overwrites them.
  Future<void> merge() async {
    if (!_active) return;
    _version++;
    await _account.setSync(dirty: true);
    _queue = _queue.then((_) => _push());
    await _queue;
  }

  Social _parse(Object? json) =>
      json is Map<String, dynamic> ? Social.fromJson(json) : const Social();

  /// Another device saved first: its contacts plus the ones only on this
  /// phone, the server's entry winning on equal names. Losing nothing beats
  /// exactness, so a contact deleted on one side may come back.
  Future<void> _union(Object? body) async {
    if (body case {
      'social': final Object? social,
      'revision': final int revision,
    }) {
      final server = _parse(social);
      final local = ref.read(socialProvider);
      final friends = [
        ...server.friends,
        ...local.friends.where(
          (mine) => !server.friends.any((other) => other.name == mine.name),
        ),
      ];
      final groups = [
        ...server.groups,
        ...local.groups.where(
          (mine) => !server.groups.any((other) => other.name == mine.name),
        ),
      ];
      final added =
          friends.length != server.friends.length ||
          groups.length != server.groups.length;
      await ref.read(socialProvider.notifier).replace(friends, groups);
      await _account.setSync(revision: revision, dirty: added);
      if (added) {
        _version++;
        _queue = _queue.then((_) => _push());
      }
    }
  }

  Future<void> _adopt(Object? body) async {
    if (body case {
      'social': final Object? social,
      'revision': final int revision,
    }) {
      final next = _parse(social);
      await ref
          .read(socialProvider.notifier)
          .replace(next.friends, next.groups);
      await _account.setSync(revision: revision, dirty: false);
    }
  }

  /// Contacts linked to an account follow its service. Works without a login.
  /// A deleted account loses the link, the contact stays.
  Future<void> refreshProfiles({bool force = false}) async {
    final now = DateTime.now();
    final last = _profilesAt;
    if (!force && last != null && now.difference(last) < _profileInterval) {
      return;
    }
    final linked = [
      for (final friend in ref.read(socialProvider).friends)
        if (friend.id != null) friend,
    ];
    if (linked.isEmpty) return;
    _profilesAt = now;
    final answers = await Future.wait([
      for (final friend in linked) _profile(friend.id!),
    ]);
    final notifier = ref.read(socialProvider.notifier);
    final t = ref.read(messagesProvider);
    for (var i = 0; i < linked.length; i++) {
      final friend = linked[i];
      final answer = answers[i];
      if (answer == null) continue;
      final current = ref
          .read(socialProvider)
          .friends
          .where((other) => other.name == friend.name && other.id == friend.id)
          .firstOrNull;
      if (current == null) continue;
      if (answer == '') {
        await notifier.updateFriend(Friend(current.name, current.platform));
      } else if (answer != current.platform) {
        await notifier.updateFriend(
          Friend(current.name, answer, id: current.id),
        );
        onNotice?.call(t.friendSwitched(current.name, platforms[answer]!));
      }
    }
  }

  /// The profile's service, '' when the account is gone, null when unknown
  Future<String?> _profile(String id) async {
    try {
      final json = await _api.request('GET', '/profiles/$id');
      if (json case {'platform': final String platform}
          when platforms.containsKey(platform)) {
        return platform;
      }
      return null;
    } on ApiException catch (error) {
      return error.status == 404 ? '' : null;
    }
  }
}

/// Starts the sync at launch and whenever the app comes back, and shows what
/// it found.
class SyncOnResume extends ConsumerStatefulWidget {
  final Widget child;
  const SyncOnResume({super.key, required this.child});

  @override
  ConsumerState<SyncOnResume> createState() => _SyncOnResumeState();
}

class _SyncOnResumeState extends ConsumerState<SyncOnResume>
    with WidgetsBindingObserver {
  late final SyncService _sync = ref.read(syncProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync.onNotice = (text) =>
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(text)));
    unawaited(_sync.refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_sync.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sync.onNotice = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
