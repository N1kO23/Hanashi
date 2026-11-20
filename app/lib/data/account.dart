import 'dart:convert';

import '../e2ee/secure_store.dart';

/// The signed-in account on this device.
class Account {
  const Account({
    required this.serverUrl,
    required this.userId,
    required this.displayName,
    required this.token,
    required this.deviceId,
  });

  final String serverUrl;

  /// `name@host`.
  final String userId;
  final String displayName;

  /// Bearer token for this device.
  final String token;
  final String deviceId;

  factory Account.fromJson(Map<String, Object?> json) => Account(
    serverUrl: json['serverUrl'] as String,
    userId: json['userId'] as String,
    displayName: json['displayName'] as String,
    token: json['token'] as String,
    deviceId: json['deviceId'] as String,
  );

  Map<String, Object?> toJson() => {
    'serverUrl': serverUrl,
    'userId': userId,
    'displayName': displayName,
    'token': token,
    'deviceId': deviceId,
  };

  /// The account lives in secure storage under this key, token included.
  static const storageKey = 'account';

  /// The signed-in account, if any; readable from any engine.
  static Future<Account?> read(SecureStore store) async {
    final raw = await store.read(storageKey);
    return raw == null ? null : Account.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
  }

  Future<void> write(SecureStore store) => store.write(storageKey, jsonEncode(toJson()));
}
