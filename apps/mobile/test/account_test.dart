import 'dart:convert';

import 'package:altcha_lib/altcha_lib.dart' as altcha;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:musiclink/app.dart';
import 'package:musiclink/core/api.dart';
import 'package:musiclink/core/router.dart';
import 'package:musiclink/features/account/account.dart';
import 'package:musiclink/features/account/sync.dart';
import 'package:musiclink/features/friends/friends_screen.dart';
import 'package:musiclink/features/friends/social.dart';

const myId = '11111111-1111-4111-8111-111111111111';
const lisaId = '22222222-2222-4222-8222-222222222222';

/// Stands in for the account routes of the API. The code is always 123456.
class FakeServer {
  final requests = <http.Request>[];
  bool online = true;
  String? token;
  Map<String, Object?> user = {
    'id': myId,
    'email': 'robin@example.com',
    'name': 'Robin',
    'platform': 'deezer',
  };
  Map<String, Object?> social = {'friends': [], 'groups': []};
  int revision = 0;
  final profiles = <String, Map<String, Object?>>{};

  late final client = MockClient((request) async {
    if (!online) throw http.ClientException('offline');
    requests.add(request);
    final loggedIn =
        token != null && request.headers['authorization'] == 'Bearer $token';
    // Every call that changes something names its JSON type, the web proxy insists
    if (request.method != 'GET') {
      expect(request.headers['content-type'], startsWith('application/json'));
    }
    final path = request.url.path.replaceFirst('/api/v1', '');
    Map<String, dynamic> body() => request.body.isEmpty
        ? {}
        : jsonDecode(request.body) as Map<String, dynamic>;
    switch ((request.method, path)) {
      case ('GET', '/altcha'):
        return _json({
          'parameters': {
            'algorithm': 'PBKDF2/SHA-256',
            'nonce': 'bm9uY2U=',
            'salt': 'c2FsdA==',
            'cost': 1,
            'keyLength': 32,
            'keyPrefix': '00',
          },
          'signature': 'sig',
        });
      case ('POST', '/auth/code'):
        return _json({'ok': true});
      case ('POST', '/auth/code/verify'):
        if (body()['code'] != '123456') {
          return _json({'error': 'Der Code stimmt nicht.'}, 400);
        }
        token = 'token-1';
        return _json({'token': token, 'user': user});
      case ('POST', '/auth/logout'):
        token = null;
        return _json({'ok': true});
      case ('GET', '/me'):
        return loggedIn ? _json({'user': user}) : _json({'error': 'no'}, 401);
      case ('PATCH', '/me'):
        if (!loggedIn) return _json({'error': 'no'}, 401);
        user = {...user, ...body()};
        return _json({'user': user});
      case ('DELETE', '/me'):
        if (!loggedIn) return _json({'error': 'no'}, 401);
        token = null;
        return _json({'ok': true});
      case ('GET', '/me/social'):
        if (!loggedIn) return _json({'error': 'no'}, 401);
        return _json({'social': social, 'revision': revision});
      case ('PUT', '/me/social'):
        if (!loggedIn) return _json({'error': 'no'}, 401);
        if (body()['revision'] != revision) {
          return _json({
            'error': 'Veraltet',
            'social': social,
            'revision': revision,
          }, 409);
        }
        social = body()['social'] as Map<String, Object?>;
        return _json({'revision': ++revision});
    }
    if (path.startsWith('/profiles/')) {
      final profile = profiles[path.substring('/profiles/'.length)];
      return profile == null ? _json({'error': 'weg'}, 404) : _json(profile);
    }
    return _json({'error': 'Nicht gefunden'}, 404);
  });

  List<String> calls(String method) => [
    for (final request in requests)
      if (request.method == method)
        request.url.path.replaceFirst('/api/v1', ''),
  ];

  late final overrides = [
    httpClientProvider.overrideWithValue(client),
    altchaSolverProvider.overrideWithValue(
      (challenge) async => altcha.Solution(counter: 1, derivedKey: 'key'),
    ),
  ];
}

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

/// The session as the app keeps it in the keychain after a login.
Map<String, String> loggedInStorage({
  String? name = 'Robin',
  String? platform = 'deezer',
  int revision = 0,
}) => {
  'session_token': 'token-1',
  'profile': jsonEncode({
    'id': myId,
    'email': 'robin@example.com',
    'name': name,
    'platform': platform,
  }),
  'social_revision': '$revision',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const preferences = MethodChannel('org.musiclink.prototype/preferences');
  late String? stored;
  late FakeServer server;

  Map<String, dynamic> localSocial() =>
      jsonDecode(stored!) as Map<String, dynamic>;

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.localesTestValue =
        const [Locale('de', 'DE')];
    addTearDown(
      TestWidgetsFlutterBinding
          .instance
          .platformDispatcher
          .clearLocalesTestValue,
    );
    server = FakeServer();
    FlutterSecureStorage.setMockInitialValues({});
    stored = jsonEncode({
      'friends': [
        {'name': 'Lisa', 'platform': 'spotify'},
        {'name': 'Jonas', 'platform': 'appleMusic'},
      ],
      'groups': [
        {
          'name': 'Band',
          'members': ['Lisa', 'Jonas'],
        },
      ],
      'me': {'name': 'Robin', 'platform': 'deezer'},
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(preferences, (call) async {
          if (call.method == 'getSocial') return stored;
          if (call.method == 'setSocial') stored = call.arguments as String;
          if (call.method == 'getPreferences') {
            return {'target': 'appleMusic', 'shareSetupSeen': 'true'};
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(preferences, null),
  );

  /// A container whose contacts are loaded from the stored JSON, logged in or not.
  Future<ProviderContainer> container() async {
    final container = ProviderContainer(overrides: server.overrides);
    addTearDown(container.dispose);
    await container.read(socialProvider.notifier).loaded;
    await container.read(accountProvider.future);
    return container;
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: server.overrides,
        child: const MaterialApp(home: FriendsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('logged out', () {
    testWidgets('contacts look like before plus a card, and nothing is sent', (
      tester,
    ) async {
      await pumpScreen(tester);
      expect(find.text('Kontakte auf allen Geräten'), findsOneWidget);
      expect(find.text('Mit Mail anmelden'), findsOneWidget);
      expect(
        find.text(
          'Damit Songgate weiß, wohin deine Songs sollen. Alles bleibt auf diesem Handy.',
        ),
        findsOneWidget,
      );
      expect(find.text('Lisa'), findsOneWidget);
      await tester.tap(find.byTooltip('Jonas entfernen'));
      await tester.pumpAndSettle();
      expect(localSocial()['friends'], [
        {'name': 'Lisa', 'platform': 'spotify'},
      ]);
      expect(server.requests, isEmpty);
    });

    test('an unreadable keychain means logged out', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final c = await container();
      expect(c.read(accountProvider).value, isNull);
    });
  });

  group('login', () {
    testWidgets('code, profile from the local invite, merge, account line', (
      tester,
    ) async {
      server.social = {
        'friends': [
          {'name': 'Max', 'platform': 'tidal'},
          {'name': 'Lisa', 'platform': 'deezer'},
        ],
        'groups': [],
      };
      server
        ..revision = 3
        // A first login: the profile is still empty
        ..user = {
          'id': myId,
          'email': 'robin@example.com',
          'name': null,
          'platform': null,
        };
      await pumpScreen(tester);
      await tester.tap(find.text('Mit Mail anmelden'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Gespeichert werden nur deine Mail, dein Name, dein Dienst und deine Kontakte. Kein Tracking, keine Werbung.',
        ),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'robin@example.com');
      await tester.pump();
      await tester.tap(find.text('Code schicken'));
      await tester.pumpAndSettle();
      // The ALTCHA payload carries the challenge as sent and the solution
      final sent = server.requests.firstWhere(
        (request) => request.url.path.endsWith('/auth/code'),
      );
      final payload = jsonDecode(
        utf8.decode(base64Decode(jsonDecode(sent.body)['altcha'] as String)),
      );
      expect(payload['challenge']['signature'], 'sig');
      expect(payload['solution']['counter'], 1);
      expect(jsonDecode(sent.body)['email'], 'robin@example.com');

      await tester.enterText(find.byType(TextField).last, '000000');
      await tester.pump();
      await tester.tap(find.text('Anmelden'));
      await tester.pumpAndSettle();
      expect(find.text('Der Code stimmt nicht.'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '123456');
      await tester.pump();
      await tester.tap(find.text('Anmelden'));
      await tester.pumpAndSettle();
      // The profile starts from the local invite identity
      expect(find.text('Dein Profil'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Robin'), findsOneWidget);
      expect(find.text('Deezer'), findsWidgets);
      expect(
        find.text(
          'Von diesem Handy kommen in dein Konto: 2 Kontakte und 1 Gruppe.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Fertig'));
      await tester.pumpAndSettle();

      expect(server.user['name'], 'Robin');
      expect(server.user['platform'], 'deezer');
      // The server's Lisa wins, Jonas and the group come along
      final friends = localSocial()['friends'] as List;
      expect(friends, [
        {'name': 'Max', 'platform': 'tidal'},
        {'name': 'Lisa', 'platform': 'deezer'},
        {'name': 'Jonas', 'platform': 'appleMusic'},
      ]);
      expect(server.social['friends'], friends);
      expect(server.revision, 4);
      expect(find.byKey(const ValueKey('account-tile')), findsOneWidget);
      expect(find.text('Deezer · robin@example.com'), findsOneWidget);
      expect(
        find.text(
          'Deine Kontakte sind in deinem Konto und auf allen Geräten, auf denen du angemeldet bist.',
        ),
        findsOneWidget,
      );
      expect(find.text('Mit Mail anmelden'), findsNothing);
    });

    test('an empty account takes this phone\'s contacts as they are', () async {
      FlutterSecureStorage.setMockInitialValues(loggedInStorage());
      server.token = 'token-1';
      final c = await container();
      await c.read(syncProvider).merge();
      expect(server.revision, 1);
      expect((server.social['friends'] as List).length, 2);
      expect((server.social['groups'] as List).length, 1);
      expect(c.read(accountProvider.notifier).revision, 1);
      expect(c.read(accountProvider.notifier).dirty, isFalse);
    });

    test('the session survives a restart', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final first = await container();
      await first
          .read(accountProvider.notifier)
          .verifyCode('robin@example.com', '123456');
      final second = await container();
      expect(second.read(accountProvider).value?.email, 'robin@example.com');
    });
  });

  group('sync', () {
    test(
      'a local change goes to the server with the last seen revision',
      () async {
        FlutterSecureStorage.setMockInitialValues(loggedInStorage(revision: 2));
        server
          ..token = 'token-1'
          ..revision = 2;
        final c = await container();
        await c
            .read(socialProvider.notifier)
            .addFriend(const Friend('Ben', 'tidal'));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(server.revision, 3);
        expect(
          (server.social['friends'] as List).map(
            (friend) => (friend as Map)['name'],
          ),
          contains('Ben'),
        );
        // The own identity is not part of the document
        expect(server.social.containsKey('me'), isFalse);
        expect(c.read(accountProvider.notifier).dirty, isFalse);
      },
    );

    test('regression: a 409 keeps this phone\'s contacts and joins them with the server\'s', () async {
      FlutterSecureStorage.setMockInitialValues(loggedInStorage(revision: 2));
      server
        ..token = 'token-1'
        ..revision = 5
        ..social = {
          'friends': [
            {'name': 'Max', 'platform': 'tidal', 'id': lisaId},
            {'name': 'Lisa', 'platform': 'deezer'},
          ],
          'groups': [],
        };
      final c = await container();
      await c
          .read(socialProvider.notifier)
          .addFriend(const Friend('Ben', 'tidal'));
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final names = c.read(socialProvider).friends.map((f) => f.name);
      expect(names, ['Max', 'Lisa', 'Jonas', 'Ben']);
      // The server's entry wins on equal names
      expect(
        c
            .read(socialProvider)
            .friends
            .firstWhere((f) => f.name == 'Lisa')
            .platform,
        'deezer',
      );
      expect(c.read(accountProvider.notifier).revision, 6);
      expect(c.read(accountProvider.notifier).dirty, isFalse);
      expect(
        (server.social['friends'] as List).map((f) => (f as Map)['name']),
        ['Max', 'Lisa', 'Jonas', 'Ben'],
      );
      // The own invite stays
      expect(c.read(socialProvider).me?.name, 'Robin');
    });

    test('regression: a login whose first merge never ran keeps this phone\'s contacts after a restart', () async {
      FlutterSecureStorage.setMockInitialValues({
        ...loggedInStorage(),
        'social_dirty': 'true',
      });
      server
        ..token = 'token-1'
        ..revision = 3
        ..social = {
          'friends': [
            {'name': 'Max', 'platform': 'tidal'},
          ],
          'groups': [],
        };
      final c = await container();
      await c.read(syncProvider).refresh(profiles: false);
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(c.read(socialProvider).friends.map((f) => f.name), [
        'Max',
        'Lisa',
        'Jonas',
      ]);
      expect(c.read(accountProvider.notifier).revision, 4);
      expect(c.read(accountProvider.notifier).dirty, isFalse);
    });

    test('a newer revision on the server is adopted at launch', () async {
      FlutterSecureStorage.setMockInitialValues(loggedInStorage(revision: 1));
      server
        ..token = 'token-1'
        ..revision = 2
        ..social = {
          'friends': [
            {'name': 'Max', 'platform': 'tidal'},
          ],
          'groups': [],
        };
      final c = await container();
      await c.read(syncProvider).refresh();
      expect(c.read(socialProvider).friends.single.name, 'Max');
      expect(c.read(accountProvider.notifier).revision, 2);
    });

    test('offline changes are pushed on the next chance', () async {
      FlutterSecureStorage.setMockInitialValues(loggedInStorage());
      server.token = 'token-1';
      final c = await container();
      server.online = false;
      await c
          .read(socialProvider.notifier)
          .addFriend(const Friend('Ben', 'tidal'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(accountProvider.notifier).dirty, isTrue);
      expect(
        c.read(socialProvider).friends.map((friend) => friend.name),
        contains('Ben'),
      );
      server.online = true;
      await c.read(syncProvider).refresh();
      expect(server.revision, 1);
      expect(c.read(accountProvider.notifier).dirty, isFalse);
    });

    test('an expired session logs out and keeps the contacts', () async {
      FlutterSecureStorage.setMockInitialValues(loggedInStorage());
      final c = await container();
      await c.read(syncProvider).refresh();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(accountProvider).value, isNull);
      expect(c.read(socialProvider).friends, hasLength(2));
      expect(c.read(socialProvider).me?.id, isNull);
    });
  });

  group('linked contacts', () {
    const linked = [
      {'name': 'Lisa', 'platform': 'spotify', 'id': lisaId},
      {'name': 'Jonas', 'platform': 'appleMusic'},
    ];

    testWidgets('a changed service updates the contact and says so', (
      tester,
    ) async {
      stored = jsonEncode({'friends': linked, 'groups': []});
      server.profiles[lisaId] = {
        'id': lisaId,
        'name': 'Lisa Müller',
        'platform': 'deezer',
      };
      tester.view.physicalSize = const Size(1170, 3000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(overrides: server.overrides, child: const App()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lisa hört jetzt auf Deezer.'), findsOneWidget);
      // The local name stays, groups refer to it
      expect(localSocial()['friends'], [
        {'name': 'Lisa', 'platform': 'deezer', 'id': lisaId},
        {'name': 'Jonas', 'platform': 'appleMusic'},
      ]);
      // Without a login, no authorization is sent
      expect(server.requests.single.headers['authorization'], isNull);
    });

    test(
      'regression: a deleted account loses the link, not the contact',
      () async {
        stored = jsonEncode({'friends': linked, 'groups': []});
        final c = await container();
        await c.read(syncProvider).refreshProfiles();
        expect(c.read(socialProvider).friends.map((friend) => friend.id), [
          null,
          null,
        ]);
        expect(localSocial()['friends'][0], {
          'name': 'Lisa',
          'platform': 'spotify',
        });
      },
    );

    test('a failing lookup changes nothing', () async {
      stored = jsonEncode({'friends': linked, 'groups': []});
      server.online = false;
      final c = await container();
      await c.read(syncProvider).refreshProfiles();
      expect(c.read(socialProvider).friends.first.id, lisaId);
    });

    test('lookups wait a few minutes', () async {
      stored = jsonEncode({'friends': linked, 'groups': []});
      server.profiles[lisaId] = {
        'id': lisaId,
        'name': 'Lisa',
        'platform': 'spotify',
      };
      final c = await container();
      await c.read(syncProvider).refreshProfiles();
      await c.read(syncProvider).refreshProfiles();
      expect(server.requests, hasLength(1));
      await c.read(syncProvider).refreshProfiles(force: true);
      expect(server.requests, hasLength(2));
    });

    testWidgets('linked contacts carry a badge in the list', (tester) async {
      final semantics = tester.ensureSemantics();
      stored = jsonEncode({'friends': linked, 'groups': []});
      server.profiles[lisaId] = {
        'id': lisaId,
        'name': 'Lisa',
        'platform': 'spotify',
      };
      await pumpScreen(tester);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.label == 'verbunden',
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.sync_alt), findsOneWidget);
      semantics.dispose();
    });

    test('ids that are no UUIDs are dropped', () {
      expect(
        Friend.fromJson({'name': 'A', 'platform': 'spotify', 'id': 'x'})?.id,
        isNull,
      );
      expect(
        Friend.fromJson({'name': 'A', 'platform': 'spotify', 'id': lisaId})?.id,
        lisaId,
      );
    });
  });

  group('invites', () {
    test('the own invite carries the profile id', () {
      expect(
        inviteUrl(const Friend('Robin', 'deezer', id: myId)),
        'http://localhost:3000/f/deezer?name=Robin&u=$myId',
      );
      expect(
        inviteUrl(const Friend('Robin', 'deezer')),
        'http://localhost:3000/f/deezer?name=Robin',
      );
    });

    testWidgets('an invite with u saves the contact linked', (tester) async {
      stored = null;
      late ProviderContainer c;
      await tester.pumpWidget(
        ProviderScope(
          overrides: server.overrides,
          child: Consumer(
            builder: (context, ref, _) {
              c = ProviderScope.containerOf(context);
              return const App();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      c.read(routerProvider).go('/f/spotify?name=Ana&u=$lisaId');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ana speichern'));
      await tester.pumpAndSettle();
      expect(localSocial()['friends'], [
        {'name': 'Ana', 'platform': 'spotify', 'id': lisaId},
      ]);
    });

    testWidgets('the app link takes u too, a broken one is ignored', (
      tester,
    ) async {
      stored = null;
      late ProviderContainer c;
      await tester.pumpWidget(
        ProviderScope(
          overrides: server.overrides,
          child: Consumer(
            builder: (context, ref, _) {
              c = ProviderScope.containerOf(context);
              return const App();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      c.read(routerProvider).go('/friend?name=Ben&service=tidal&u=nope');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ben speichern'));
      await tester.pumpAndSettle();
      expect(localSocial()['friends'], [
        {'name': 'Ben', 'platform': 'tidal'},
      ]);
    });
  });

  group('account', () {
    testWidgets('changing the service updates the profile and the own invite', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues(loggedInStorage());
      server
        ..token = 'token-1'
        ..user = {
          'id': myId,
          'email': 'robin@example.com',
          'name': 'Robin',
          'platform': 'deezer',
        };
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('account-tile')));
      await tester.pumpAndSettle();
      expect(find.text('Konto'), findsOneWidget);
      expect(
        find.text(
          'Wechselst du hier den Dienst, sehen es alle, die dich gespeichert haben.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spotify').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(server.user['platform'], 'spotify');
      expect(localSocial()['me'], {
        'name': 'Robin',
        'platform': 'spotify',
        'id': myId,
      });
    });

    testWidgets('logging out keeps the contacts', (tester) async {
      FlutterSecureStorage.setMockInitialValues(loggedInStorage());
      server.token = 'token-1';
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('account-tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abmelden'));
      await tester.pumpAndSettle();
      expect(server.calls('POST'), ['/auth/logout']);
      expect(find.text('Mit Mail anmelden'), findsOneWidget);
      expect(find.text('Lisa'), findsOneWidget);
      expect(localSocial()['me'], {'name': 'Robin', 'platform': 'deezer'});
    });

    testWidgets('deleting the account keeps this phone\'s contacts', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues(loggedInStorage());
      server.token = 'token-1';
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('account-tile')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Löschen entfernt Konto, Profil und Kontakte auf dem Server sofort. Auf diesem Handy bleiben deine Kontakte.',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Konto löschen'));
      await tester.tap(find.text('Konto löschen'));
      await tester.pumpAndSettle();
      expect(server.calls('DELETE'), isEmpty);
      await tester.tap(find.text('Konto löschen').last);
      await tester.pumpAndSettle();
      expect(server.calls('DELETE'), ['/me']);
      expect(server.token, isNull);
      expect(find.text('Mit Mail anmelden'), findsOneWidget);
      expect(find.text('Lisa'), findsOneWidget);
      expect(find.text('Jonas'), findsOneWidget);
      expect(localSocial()['friends'], hasLength(2));
    });
  });
}
