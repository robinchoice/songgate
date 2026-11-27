import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'package:pointycastle/export.dart';

import '../../core/api.dart';
import '../converter/conversion.dart';
import '../friends/social.dart';
import 'account.dart';
import 'oprf.dart';

/// Numbers per evaluate request, the most the API takes.
const evaluateChunk = 200;

/// The longest name a contact may have, see the sync schema.
const maxNameLength = 40;

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

/// The tag a directory entry carries for the OPRF output [output] of a number.
String discoverTag(List<int> output) => toHex(
  SHA256Digest()
      .process(
        Uint8List.fromList([
          ...utf8.encode('Songgate discover tag'),
          ...output,
        ]),
      )
      .sublist(0, 16),
);

/// The AES-256 key of the box that belongs to [output].
Uint8List discoverBoxKey(List<int> output) => SHA256Digest().process(
  Uint8List.fromList([...utf8.encode('Songgate discover box'), ...output]),
);

/// AES-GCM runs in the operating system (CryptoKit on iOS, javax.crypto on
/// Android), so the app ships no encryption of its own; App Store Connect
/// counts it as exempt (AGENTS.md, "Pitfalls").
const _crypto = MethodChannel('org.musiclink.prototype/crypto');

/// The profile `{id, name, platform}` in a directory box
/// (base64 of nonce(12) || ciphertext || tag(16), AES-256-GCM), null when
/// [output] does not open it or the content is no profile.
Future<Map<String, Object?>?> openDirectoryBox(
  List<int> output,
  String box,
) async {
  try {
    final bytes = base64Decode(box);
    if (bytes.length < 12 + 16) return null;
    final plain = await _crypto.invokeMethod<Uint8List>('openAesGcm', {
      'key': discoverBoxKey(output),
      'nonce': Uint8List.fromList(bytes.sublist(0, 12)),
      'sealed': Uint8List.fromList(bytes.sublist(12)),
    });
    if (plain == null) return null;
    final json = jsonDecode(utf8.decode(plain));
    return json is Map<String, dynamic> ? json : null;
  } on FormatException {
    return null;
  }
}

/// A person from the address book who is on Songgate: their name, the
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

  /// The daily quota ended the search: [checked] of [total] numbers are done
  final bool limited;
  final int checked;
  final int total;
  const DiscoverResult({
    this.denied = false,
    this.matches = const [],
    this.limited = false,
    this.checked = 0,
    this.total = 0,
  });
}

/// An address book name that is empty or mostly a number says nothing.
bool _nameless(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return true;
  final numeric = trimmed.runes
      .where((rune) => '0123456789+ ()-./'.contains(String.fromCharCode(rune)))
      .length;
  return numeric * 5 >= trimmed.runes.length * 4;
}

String _shorten(String name, int length) =>
    name.characters.take(length).toString().trim();

/// [name] if no other contact has it, else with " 2", " 3" … after it.
String freeName(String name, String id, Iterable<Friend> friends) {
  var candidate = _shorten(name, maxNameLength);
  for (var n = 2; friends.any((f) => f.name == candidate && f.id != id); n++) {
    candidate = '${_shorten(name, maxNameLength - ' $n'.length)} $n';
  }
  return candidate;
}

final discoveryProvider = Provider(Discovery.new);

/// Finds the people of the address book who are discoverable, without a
/// number leaving the phone: each is blinded (oprf.dart), the server applies
/// its key to the blinded value, the phone unblinds it into an output that
/// only this number gives. The directory of discoverable people lists tags
/// and boxes; the phone picks the entries whose tag fits one of its outputs
/// and opens them with it, so the server never learns who matched. Outputs
/// stay on the phone, so a later run checks only numbers not yet checked.
class Discovery {
  final Ref ref;
  Discovery(this.ref);

  Api get _api => ref.read(apiProvider);
  AccountController get _account => ref.read(accountProvider.notifier);

  Future<DiscoverResult> run() async {
    final entries = await ref.read(contactsSourceProvider).read();
    if (entries == null) return const DiscoverResult(denied: true);
    final own = await _account.ownPhone();
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

    final saved = await _account.readDiscoverCache();
    final outputs = {
      for (final number in names.keys)
        if (saved[number] case final String output) number: output,
    };
    final pending = [
      for (final number in names.keys)
        if (!outputs.containsKey(number)) number,
    ];
    final client = OprfClient();
    var limited = false;
    for (var start = 0; start < pending.length; start += evaluateChunk) {
      final chunk = pending.skip(start).take(evaluateChunk).toList();
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
        limited = true;
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
          outputs[chunk[i]] = toHex(
            client.finalize(blinded[i], base64Decode(item)),
          );
        } on FormatException {
          throw ApiException(_api.locale.messages.invalidAnswer);
        }
        await _yield(i + 1);
      }
      await _account.writeDiscoverCache(outputs);
    }
    await _account.writeDiscoverCache(outputs);

    final matches = <Match>[];
    if (outputs.isNotEmpty) {
      final boxes = await _directory();
      for (final MapEntry(key: number, value: hex) in outputs.entries) {
        final output = hexBytes(hex);
        final box = boxes[discoverTag(output)];
        if (box == null) continue;
        final profile = await openDirectoryBox(output, box);
        if (profile
            case {'id': final String id, 'platform': final String platform}
            when id != ownId &&
                platforms.containsKey(platform) &&
                !matches.any((match) => match.id == id)) {
          final book = names[number]!;
          final named = profile['name'];
          final name = _nameless(book) && named is String && named.isNotEmpty
              ? named
              : book;
          matches.add(Match(_shorten(name, maxNameLength), id, platform));
        }
      }
    }
    matches.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return DiscoverResult(
      matches: matches,
      limited: limited,
      checked: outputs.length,
      total: names.length,
    );
  }

  /// Box by tag of everyone discoverable except this account
  Future<Map<String, String>> _directory() async {
    final answer = await _api.request('GET', '/discover/directory', auth: true);
    if (answer case {'entries': final List<Object?> entries}) {
      return {
        for (final entry in entries)
          if (entry case {'tag': final String tag, 'box': final String box})
            tag: box,
      };
    }
    throw ApiException(_api.locale.messages.invalidAnswer);
  }

  // The curve arithmetic is slow in Dart: give the frames room now and then
  Future<void> _yield(int count) async {
    if (count % 4 == 0) await Future<void>.delayed(Duration.zero);
  }
}
