import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../../core/api.dart';
import '../converter/conversion.dart';
import 'account.dart';
import 'oprf.dart';

/// Numbers per evaluate request and keys per profiles request, the most the
/// API takes.
const evaluateChunk = 200;
const profilesChunk = 500;

/// The region that completes numbers without a country code: the device's,
/// Germany if it names none the number parser knows.
final defaultRegionProvider = Provider<IsoCode>((ref) {
  final locales = WidgetsBinding.instance.platformDispatcher.locales;
  final country = locales.firstOrNull?.countryCode?.toUpperCase();
  return IsoCode.values.asNameMap()[country] ?? IsoCode.DE;
});

/// The number in E.164, null if it is no valid phone number.
String? toE164(String raw, IsoCode region) {
  try {
    final number = PhoneNumber.parse(raw.trim(), callerCountry: region);
    return number.isValid() ? number.international : null;
  } on PhoneNumberException {
    return null;
  }
}

/// Country code and the first and last digits, the middle hidden:
/// +49 151 •••• 789
String maskNumber(String e164) {
  final number = PhoneNumber.parse(e164);
  final nsn = number.nsn;
  if (nsn.length < 7) {
    return '+${number.countryCode} •••• ${nsn.substring(nsn.length - 2)}';
  }
  return '+${number.countryCode} ${nsn.substring(0, 3)} •••• ${nsn.substring(nsn.length - 3)}';
}

class AddressBookEntry {
  final String name;
  final List<String> numbers;
  const AddressBookEntry(this.name, this.numbers);
}

/// Reads the address book. Behind a provider so tests need no phone.
abstract class ContactsSource {
  /// Null while the person does not allow access to the contacts.
  Future<List<AddressBookEntry>?> read();
}

final contactsSourceProvider = Provider<ContactsSource>(
  (ref) => const DeviceContacts(),
);

class DeviceContacts implements ContactsSource {
  const DeviceContacts();

  @override
  Future<List<AddressBookEntry>?> read() async {
    final status = await FlutterContacts.permissions.request(
      PermissionType.read,
    );
    if (status != PermissionStatus.granted &&
        status != PermissionStatus.limited) {
      return null;
    }
    final contacts = await FlutterContacts.getAll(
      properties: {ContactProperty.phone},
    );
    return [
      for (final contact in contacts)
        if (contact.displayName case final name? when name.isNotEmpty)
          AddressBookEntry(name, [
            for (final phone in contact.phones) phone.number,
          ]),
    ];
  }
}

/// A person from the address book who is on Songgate: their name there, the
/// service and profile from Songgate.
class Match {
  final String name;
  final String id;
  final String platform;
  const Match(this.name, this.id, this.platform);
}

class DiscoverResult {
  /// The address book was not readable
  final bool denied;
  final List<Match> matches;

  /// The API's text when the daily quota ended the search early
  final String? limit;
  const DiscoverResult({
    this.denied = false,
    this.matches = const [],
    this.limit,
  });
}

final discoveryProvider = Provider(Discovery.new);

/// Finds the people of the address book who are discoverable, without a
/// number leaving the phone: each is blinded (oprf.dart), the server applies
/// its key to the blinded value, the phone unblinds it into the key the
/// server holds for a confirmed number and compares with the list of all keys.
class Discovery {
  final Ref ref;
  Discovery(this.ref);

  Api get _api => ref.read(apiProvider);

  Future<DiscoverResult> run() async {
    final entries = await ref.read(contactsSourceProvider).read();
    if (entries == null) return const DiscoverResult(denied: true);
    final own = await ref.read(accountProvider.notifier).ownPhone();
    final ownId = ref.read(accountProvider).value?.id;
    final region = ref.read(defaultRegionProvider);

    // One entry per number, named after the first contact that has it
    final names = <String, String>{};
    for (final entry in entries) {
      for (final raw in entry.numbers) {
        final number = toE164(raw, region);
        if (number != null && number != own) {
          names.putIfAbsent(number, () => entry.name);
        }
      }
    }

    final client = OprfClient();
    final keyNames = <String, String>{};
    String? limit;
    final numbers = names.keys.toList();
    for (var start = 0; start < numbers.length; start += evaluateChunk) {
      final chunk = numbers.skip(start).take(evaluateChunk).toList();
      final blinded = <Blinded>[];
      for (final number in chunk) {
        blinded.add(client.blind(Uint8List.fromList(utf8.encode(number))));
        await _yield(blinded.length);
      }
      final Object? answer;
      try {
        answer = await _api.request(
          'POST',
          '/discover/evaluate',
          body: {
            'blinded': [for (final b in blinded) base64Encode(b.element)],
          },
          auth: true,
        );
      } on ApiException catch (error) {
        if (error.status != 429) rethrow;
        limit = error.message;
        break;
      }
      final evaluated = switch (answer) {
        {'evaluated': final List<Object?> list} => list,
        _ => throw ApiException(_api.locale.messages.invalidAnswer),
      };
      if (evaluated.length != chunk.length) {
        throw ApiException(_api.locale.messages.invalidAnswer);
      }
      for (var i = 0; i < chunk.length; i++) {
        final Object? item = evaluated[i];
        try {
          if (item is! String) throw const FormatException('Not a string');
          final key = toHex(client.finalize(blinded[i], base64Decode(item)));
          keyNames[key] = names[chunk[i]]!;
        } on FormatException {
          throw ApiException(_api.locale.messages.invalidAnswer);
        }
        await _yield(i + 1);
      }
    }

    final keys = await _keys();
    final found = keyNames.keys.where(keys.contains).toList();
    final matches = <Match>[];
    for (var start = 0; start < found.length; start += profilesChunk) {
      final answer = await _api.request(
        'POST',
        '/discover/profiles',
        body: {'keys': found.skip(start).take(profilesChunk).toList()},
        auth: true,
      );
      if (answer case {'profiles': final List<Object?> profiles}) {
        for (final profile in profiles) {
          if (profile
              case {
                'key': final String key,
                'id': final String id,
                'platform': final String platform,
              }
              when keyNames.containsKey(key) &&
                  id != ownId &&
                  platforms.containsKey(platform) &&
                  !matches.any((match) => match.id == id)) {
            matches.add(Match(keyNames[key]!, id, platform));
          }
        }
      }
    }
    matches.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return DiscoverResult(matches: matches, limit: limit);
  }

  Future<Set<String>> _keys() async {
    final answer = await _api.request('GET', '/discover/keys', auth: true);
    if (answer case {'keys': final List<Object?> keys}) {
      return keys.whereType<String>().toSet();
    }
    throw ApiException(_api.locale.messages.invalidAnswer);
  }

  // The curve arithmetic is slow in Dart: give the frames room now and then
  Future<void> _yield(int count) async {
    if (count % 4 == 0) await Future<void>.delayed(Duration.zero);
  }
}
