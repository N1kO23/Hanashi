/// A user identifier of the form `name@host`.
///
/// The host part is the server the account lives on, so IDs stay unique
/// across servers that federate. During development the host may carry a port.
/// An ID has at most [maxLength] characters.
class UserId {
  const UserId._(this.name, this.host);

  final String name;
  final String host;

  static const maxLength = 128;

  static final _namePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,31}$');
  static final _hostPattern = RegExp(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:\d{1,5})?$');

  factory UserId(String name, String host) {
    if (!isValidName(name)) throw FormatException('Invalid user name', name);
    if (!isValidHost(host)) throw FormatException('Invalid host', host);
    if (name.length + 1 + host.length > maxLength) throw FormatException('User ID too long', '$name@$host');
    return UserId._(name, host);
  }

  factory UserId.parse(String value) {
    final at = value.lastIndexOf('@');
    if (at <= 0) throw FormatException('Expected name@host', value);
    return UserId(value.substring(0, at), value.substring(at + 1));
  }

  static UserId? tryParse(String value) {
    try {
      return UserId.parse(value);
    } on FormatException {
      return null;
    }
  }

  /// What to call [userId] while their own name is not known: their name; or
  /// for a user of another server than [me]'s, their whole ID, so that
  /// `alice@a` never passes for `alice@b`.
  static String fallbackName(String userId, {String? me}) {
    final id = tryParse(userId);
    if (id == null) return userId;
    final ownHost = me == null ? null : tryParse(me)?.host;
    return ownHost == null || id.host == ownHost ? id.name : userId;
  }

  static bool isValidName(String name) => _namePattern.hasMatch(name);
  static bool isValidHost(String host) => _hostPattern.hasMatch(host);

  @override
  String toString() => '$name@$host';

  @override
  bool operator ==(Object other) => other is UserId && other.name == name && other.host == host;

  @override
  int get hashCode => Object.hash(name, host);
}
