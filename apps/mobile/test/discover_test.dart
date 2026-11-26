import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musiclink/features/account/account.dart';
import 'package:musiclink/features/account/account_screens.dart';
import 'package:musiclink/features/account/discover.dart';
import 'package:musiclink/features/friends/discover_screen.dart';
import 'package:musiclink/features/friends/friends_screen.dart';
import 'package:musiclink/features/friends/social.dart';

import 'account_test.dart' hide main;

const benId = '33333333-3333-4333-8333-333333333333';

class FakeContacts implements ContactsSource {
  List<AddressBookEntry>? entries;
  var reads = 0;
  FakeContacts(this.entries);

  @override
  Future<List<AddressBookEntry>?> read() async {
    reads++;
    return entries;
  }
}

/// German mobile numbers, 0151 1000000x in the national form
String national(int i) => '0151 ${10000000 + i}';
String e164(int i) => '+49151${10000000 + i}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const preferences = MethodChannel('org.musiclink.prototype/preferences');
  late String? stored;
  late FakeServer server;
  late FakeContacts contacts;

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
    contacts = FakeContacts([]);
    stored = jsonEncode({
      'friends': [
        {'name': 'Ben', 'platform': 'youtubeMusic', 'id': benId},
      ],
      'groups': [],
      'me': {'name': 'Robin', 'platform': 'deezer'},
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(preferences, (call) async {
          if (call.method == 'getSocial') return stored;
          if (call.method == 'setSocial') stored = call.arguments as String;
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(preferences, null),
  );

  /// Logged in, with the own number confirmed or not
  void logIn({bool discoverable = true, String? ownPhone}) {
    FlutterSecureStorage.setMockInitialValues({
      ...loggedInStorage(),
      'profile': jsonEncode({
        'id': myId,
        'email': 'robin@example.com',
        'name': 'Robin',
        'platform': 'deezer',
        'discoverable': discoverable,
      }),
      'own_phone': ?ownPhone,
    });
    server
      ..token = 'token-1'
      ..user = {...server.user, 'discoverable': discoverable};
  }

  List<Override> overrides() => [
    ...server.overrides,
    contactsSourceProvider.overrideWithValue(contacts),
  ];

  Future<ProviderContainer> container() async {
    final container = ProviderContainer(overrides: overrides());
    addTearDown(container.dispose);
    await container.read(socialProvider.notifier).loaded;
    await container.read(accountProvider.future);
    return container;
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(1170, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  void discoverable(int i, String id, String platform) {
    server.discoverable[server.keyOf(e164(i))] = {
      'id': id,
      'name': 'Profilname $i',
      'platform': platform,
    };
  }

  group('own number', () {
    testWidgets('number, SMS code, discoverable, and off again', (
      tester,
    ) async {
      logIn(discoverable: false);
      await pump(tester, const AccountScreen());
      expect(find.text('Über meine Handynummer auffindbar'), findsOneWidget);
      expect(
        find.text(
          'Wer deine Nummer im Adressbuch hat und Songgate nutzt, findet dich und deinen Dienst. Deine Nummer selbst sieht niemand, auch wir speichern sie nicht.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Nummer hinzufügen'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Wir schicken dir einmal einen Code per SMS, damit niemand eine fremde Nummer eintragen kann.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Gespeichert wird nur ein Schlüsselwert, aus dem sich die Nummer nicht ablesen lässt.',
        ),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      await tester.tap(find.text('Code per SMS schicken'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Diese Nummer ist ungültig'), findsOneWidget);
      expect(server.calls('POST'), isNot(contains('/me/phone')));

      // National form, completed with the device's country
      await tester.enterText(find.byType(TextField), '0151 23456789');
      await tester.pump();
      await tester.tap(find.text('Code per SMS schicken'));
      await tester.pumpAndSettle();
      expect(server.pendingPhone, '+4915123456789');
      expect(find.text('Code an +49 151 •••• 789 geschickt.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '000000');
      await tester.pump();
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(find.text('Der Code stimmt nicht.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(find.text('✓ Über deine Nummer auffindbar'), findsOneWidget);
      expect(server.user['discoverable'], isTrue);
      await tester.tap(find.text('Fertig'));
      await tester.pumpAndSettle();

      expect(find.text('✓ Über deine Nummer auffindbar'), findsOneWidget);
      expect(find.text('Nummer hinzufügen'), findsNothing);
      await tester.tap(find.text('Nicht mehr auffindbar'));
      await tester.pumpAndSettle();
      expect(server.calls('DELETE'), contains('/me/phone'));
      expect(server.user['discoverable'], isFalse);
      expect(find.text('Nummer hinzufügen'), findsOneWidget);
    });

    test(
      'the confirmed number stays on this phone only until it is removed',
      () async {
        logIn(discoverable: false);
        final c = await container();
        final account = c.read(accountProvider.notifier);
        await account.requestPhoneCode('+4915123456789');
        await account.verifyPhone('+4915123456789', '123456');
        expect(c.read(accountProvider).value?.discoverable, isTrue);
        expect(await account.ownPhone(), '+4915123456789');
        await account.removePhone();
        expect(c.read(accountProvider).value?.discoverable, isFalse);
        expect(await account.ownPhone(), isNull);
      },
    );
  });

  group('contacts card', () {
    testWidgets('logged out: no card', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await pump(tester, const FriendsScreen());
      expect(find.text('Kontakte finden'), findsNothing);
      expect(
        find.text('Wer aus deinem Adressbuch ist bei Songgate?'),
        findsNothing,
      );
      expect(find.text('Mit Mail anmelden'), findsOneWidget);
    });

    testWidgets('not discoverable: asks for the own number first', (
      tester,
    ) async {
      logIn(discoverable: false);
      await pump(tester, const FriendsScreen());
      expect(
        find.text('Wer aus deinem Adressbuch ist bei Songgate?'),
        findsOneWidget,
      );
      expect(find.text('Kontakte finden'), findsNothing);
      expect(contacts.reads, 0);
      await tester.tap(find.text('Nummer hinzufügen'));
      await tester.pumpAndSettle();
      expect(find.text('Code per SMS schicken'), findsOneWidget);
    });

    testWidgets(
      'discoverable: the contacts are not touched before the button',
      (tester) async {
        logIn();
        await pump(tester, const FriendsScreen());
        expect(
          find.text(
            'Songgate prüft die Nummern auf deinem Handy, ohne sie uns zu zeigen. Nur wer selbst auffindbar ist, taucht auf.',
          ),
          findsOneWidget,
        );
        expect(find.text('Kontakte finden'), findsOneWidget);
        expect(contacts.reads, 0);
      },
    );
  });

  group('finding contacts', () {
    testWidgets(
      'matches show the address book name and save as linked contacts',
      (tester) async {
        logIn(ownPhone: e164(9));
        discoverable(1, lisaId, 'appleMusic');
        discoverable(2, benId, 'youtubeMusic');
        discoverable(9, myId, 'deezer');
        // Keys of people unknown to this address book
        server.discoverable['f' * 64] = {
          'id': '44444444-4444-4444-8444-444444444444',
          'name': 'Fremd',
          'platform': 'spotify',
        };
        contacts.entries = [
          AddressBookEntry('Lea Meyer', [national(1), 'abc']),
          // The same number twice and in two forms counts once
          AddressBookEntry('Lea privat', [e164(1)]),
          AddressBookEntry('Ben Kramer', [e164(2), '12']),
          AddressBookEntry('Ich selbst', [e164(9)]),
          AddressBookEntry('Ohne Songgate', [e164(3)]),
          const AddressBookEntry('Ohne Nummer', []),
        ];
        await pump(tester, const FriendsScreen());
        await tester.tap(find.text('Kontakte finden'));
        await tester.pumpAndSettle();

        // Three distinct valid numbers, the own one left out
        expect(server.evaluateSizes, [3]);
        // Only matched keys go back, and no number is sent in clear
        final profileRequest = server.requests.singleWhere(
          (request) => request.url.path.endsWith('/discover/profiles'),
        );
        expect((jsonDecode(profileRequest.body)['keys'] as List).toSet(), {
          server.keyOf(e164(1)),
          server.keyOf(e164(2)),
        });
        for (final request in server.requests) {
          expect(request.body, isNot(contains('+4915110000')));
          expect(request.body, isNot(contains('0151')));
        }

        expect(find.text('Gefunden'), findsOneWidget);
        expect(
          find.text('2 Personen aus deinem Adressbuch sind bei Songgate.'),
          findsOneWidget,
        );
        expect(
          find.text(
            'Angezeigt wird der Name aus deinem Adressbuch, dazu der Dienst aus dem Profil.',
          ),
          findsOneWidget,
        );
        expect(find.text('Lea Meyer'), findsOneWidget);
        expect(find.text('Profilname 1'), findsNothing);
        expect(find.text('Apple Music'), findsOneWidget);
        expect(find.text('YouTube Music · schon gespeichert'), findsOneWidget);
        expect(find.text('Ich selbst'), findsNothing);
        expect(find.text('Speichern'), findsOneWidget);

        await tester.tap(find.text('Speichern'));
        await tester.pumpAndSettle();
        expect(localSocial()['friends'], [
          {'name': 'Ben', 'platform': 'youtubeMusic', 'id': benId},
          {'name': 'Lea Meyer', 'platform': 'appleMusic', 'id': lisaId},
        ]);
        expect(find.text('Apple Music · schon gespeichert'), findsOneWidget);
        expect(find.text('Speichern'), findsNothing);
      },
    );

    test(
      'numbers go out in chunks and only what matches is looked up',
      () async {
        logIn();
        server.evaluateQuota = null;
        discoverable(250, lisaId, 'appleMusic');
        discoverable(400, benId, 'tidal');
        contacts.entries = [
          for (var i = 1; i <= 401; i++)
            AddressBookEntry('Kontakt $i', [e164(i)]),
        ];
        final c = await container();
        final result = await c.read(discoveryProvider).run();
        expect(server.evaluateSizes, [200, 200, 1]);
        expect(result.limit, isNull);
        expect(
          [for (final m in result.matches) (m.name, m.id, m.platform)],
          [
            ('Kontakt 250', lisaId, 'appleMusic'),
            ('Kontakt 400', benId, 'tidal'),
          ],
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    testWidgets('429 shows the API text and what matched until then', (
      tester,
    ) async {
      logIn();
      server.evaluateQuota = 200;
      discoverable(5, lisaId, 'appleMusic');
      discoverable(250, benId, 'tidal');
      contacts.entries = [
        for (var i = 1; i <= 300; i++)
          AddressBookEntry('Kontakt $i', [e164(i)]),
      ];
      await pump(tester, const DiscoverScreen());
      expect(server.evaluateSizes, [200, 100]);
      expect(find.text('Tageslimit erreicht.'), findsOneWidget);
      expect(
        find.text('1 Person aus deinem Adressbuch ist bei Songgate.'),
        findsOneWidget,
      );
      expect(find.text('Kontakt 5'), findsOneWidget);
      expect(find.text('Kontakt 250'), findsNothing);
    });

    testWidgets('nobody found: says so and offers the invite', (tester) async {
      logIn();
      contacts.entries = [
        AddressBookEntry('Lea', [e164(1)]),
      ];
      await pump(tester, const DiscoverScreen());
      expect(
        find.text(
          'Noch niemand aus deinem Adressbuch ist auffindbar. Schick deine Einladung!',
        ),
        findsOneWidget,
      );
      expect(find.text('Meine Einladung teilen'), findsOneWidget);
      expect(
        server.requests.where((r) => r.url.path.endsWith('/discover/profiles')),
        isEmpty,
      );
    });

    testWidgets('permission denied: friendly text and nothing sent', (
      tester,
    ) async {
      logIn();
      contacts.entries = null;
      await pump(tester, const DiscoverScreen());
      expect(
        find.textContaining('Ohne Zugriff auf deine Kontakte'),
        findsOneWidget,
      );
      expect(server.requests, isEmpty);
    });

    testWidgets(
      'regression: an answer that is not a point on the curve is refused',
      (tester) async {
        logIn();
        discoverable(1, lisaId, 'appleMusic');
        contacts.entries = [
          AddressBookEntry('Lea', [e164(1)]),
        ];
        server.corruptEvaluation = true;
        await pump(tester, const DiscoverScreen());
        expect(
          find.text('Der Dienst hat eine ungültige Antwort gesendet.'),
          findsOneWidget,
        );
        expect(find.text('Lea'), findsNothing);
      },
    );
  });
}
