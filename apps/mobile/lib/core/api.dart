import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../features/converter/conversion.dart';
import 'messages.dart';

final httpClientProvider = Provider((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

// Kept for the app's lifetime, so the language set by localeProvider stays
final apiProvider = Provider(
  (ref) => Api(ref.watch(httpClientProvider), apiUrl),
);

/// The last failed lookups, newest first. Feedback sends them along.
final recentErrors = <String>[];

void _noteError(Object status) {
  recentErrors.insert(0, 'GET /api/v1/song → $status');
  if (recentErrors.length > 5) recentErrors.removeLast();
}

class ApiException implements Exception {
  final String message;

  /// HTTP status, 0 when the server wasn't reached
  final int status;

  /// The decoded JSON of an error answer, e.g. the server's state on a 409
  final Object? body;
  const ApiException(this.message, {this.status = 0, this.body});
  @override
  String toString() => message;
}

/// Below the minimum build of its platform the API answers 426, see apps/api/src/app.ts.
final updateRequiredProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(apiProvider).updateRequired(),
);

Map<String, String> get _appHeaders => buildNumber == 0
    ? const {}
    : {'x-app-platform': appPlatform, 'x-app-build': '$buildNumber'};

class Api {
  final http.Client client;
  final String baseUrl;
  Api(this.client, String baseUrl)
    : baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), '');

  /// Session token of the account, set by the account controller
  String? token;

  /// Called when the server rejects the token
  void Function()? onUnauthorized;

  /// Language of error texts, set by localeProvider. The API answers in it too.
  AppLocale locale = AppLocale.de;

  Map<String, String> get _headers => {
    'accept': 'application/json',
    'accept-language': locale.name,
    ..._appHeaders,
  };

  Uri _url(String path) => Uri.parse('$baseUrl/api/v1$path');

  /// Asked once at launch. Offline or failing, the app just starts.
  Future<bool> updateRequired() async {
    if (buildNumber == 0) return false;
    try {
      final response = await client
          .get(_url('/app'), headers: _appHeaders)
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 426;
    } on Exception {
      return false;
    }
  }

  Future<Song> song(String input, {String country = 'DE'}) async {
    try {
      final response = await client
          .get(
            _url('/song')
                .replace(queryParameters: {'input': input, 'country': country}),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode >= 400) {
        _noteError(response.statusCode);
        throw ApiException(
          _errorMessage(response) ?? locale.messages.serviceUnavailable,
        );
      }
      return Song.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(locale.messages.searchTimeout);
    } on http.ClientException {
      _noteError('offline');
      throw ApiException(locale.messages.offline);
    } on FormatException {
      throw ApiException(locale.messages.invalidAnswer);
    } on TypeError {
      throw ApiException(locale.messages.invalidAnswer);
    }
  }

  /// JSON call of the account endpoints. Every call that changes something
  /// sends the JSON content type, the web proxy refuses it otherwise. [auth]
  /// adds the session token.
  Future<Object?> request(
    String method,
    String path, {
    Object? body,
    bool auth = false,
  }) async {
    final request = http.Request(method, _url(path))..headers.addAll(_headers);
    if (method != 'GET') {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body ?? const {});
    }
    final sent = auth ? token : null;
    if (sent != null) request.headers['authorization'] = 'Bearer $sent';
    try {
      final response = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 25)),
      );
      final decoded = response.bodyBytes.isEmpty
          ? null
          : jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode >= 400) {
        if (response.statusCode == 401 && sent != null) onUnauthorized?.call();
        throw ApiException(
          _errorMessage(response) ?? locale.messages.serviceUnavailable,
          status: response.statusCode,
          body: decoded,
        );
      }
      return decoded;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(locale.messages.sendTimeout);
    } on http.ClientException {
      throw ApiException(locale.messages.offline);
    } on FormatException {
      throw ApiException(locale.messages.invalidAnswer);
    }
  }

  Future<void> sendFeedback(Map<String, dynamic> body) async {
    try {
      final response = await client
          .post(
            _url('/feedback'),
            headers: {'content-type': 'application/json', ..._headers},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode >= 400) {
        throw ApiException(
          _errorMessage(response) ?? locale.messages.serviceUnavailable,
        );
      }
    } on TimeoutException {
      throw ApiException(locale.messages.sendTimeout);
    } on http.ClientException {
      throw ApiException(locale.messages.offline);
    }
  }
}

String? _errorMessage(http.Response response) {
  try {
    if (jsonDecode(utf8.decode(response.bodyBytes)) case {
      'error': final String message,
    }) {
      return message;
    }
  } on FormatException {
    // Not from our API, e.g. a proxy page
  }
  return null;
}
