import 'dart:convert';
import 'dart:typed_data';

/// The bytes a user's identity key signs to vouch for one of their devices.
/// Must match `DeviceRecordMessage` in the Go server.
Uint8List deviceRecordMessage(String userId, String deviceId, String mlsSigKeyBase64) =>
    utf8.encode('hanashi-device-v1\n$userId\n$deviceId\n$mlsSigKeyBase64');

/// One device in the key directory (`GET /keys/users/{id}`).
class DeviceKeyInfo {
  const DeviceKeyInfo({required this.deviceId, required this.mlsSigKey, this.signature, this.signedVersion});

  final String deviceId;

  /// Base64 Ed25519 public key the device uses in MLS.
  final String mlsSigKey;

  /// Base64 signature by the user's identity key over [deviceRecordMessage];
  /// null while the device is unverified.
  final String? signature;
  final int? signedVersion;

  factory DeviceKeyInfo.fromJson(Map<String, Object?> json) => DeviceKeyInfo(
    deviceId: json['deviceId'] as String,
    mlsSigKey: json['mlsSigKey'] as String,
    signature: json['signature'] as String?,
    signedVersion: json['signedVersion'] as int?,
  );
}

/// A user's published keys. [identityKey] is null until they set up encryption.
class UserKeys {
  const UserKeys({required this.userId, required this.devices, this.identityKey, this.identityVersion});

  final String userId;

  /// Base64 Ed25519 identity public key.
  final String? identityKey;
  final int? identityVersion;
  final List<DeviceKeyInfo> devices;

  factory UserKeys.fromJson(Map<String, Object?> json) => UserKeys(
    userId: json['userId'] as String,
    identityKey: json['identityKey'] as String?,
    identityVersion: json['identityVersion'] as int?,
    devices: [for (final d in json['devices'] as List) DeviceKeyInfo.fromJson((d as Map).cast<String, Object?>())],
  );
}
