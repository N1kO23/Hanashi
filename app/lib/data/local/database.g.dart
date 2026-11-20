// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $KeyValuesTable extends KeyValues
    with TableInfo<$KeyValuesTable, KeyValue> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KeyValuesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'key_values';
  @override
  VerificationContext validateIntegrity(
    Insertable<KeyValue> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  KeyValue map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KeyValue(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $KeyValuesTable createAlias(String alias) {
    return $KeyValuesTable(attachedDatabase, alias);
  }
}

class KeyValue extends DataClass implements Insertable<KeyValue> {
  final String key;
  final String value;
  const KeyValue({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  KeyValuesCompanion toCompanion(bool nullToAbsent) {
    return KeyValuesCompanion(key: Value(key), value: Value(value));
  }

  factory KeyValue.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KeyValue(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  KeyValue copyWith({String? key, String? value}) =>
      KeyValue(key: key ?? this.key, value: value ?? this.value);
  KeyValue copyWithCompanion(KeyValuesCompanion data) {
    return KeyValue(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KeyValue(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KeyValue && other.key == this.key && other.value == this.value);
}

class KeyValuesCompanion extends UpdateCompanion<KeyValue> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const KeyValuesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KeyValuesCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<KeyValue> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KeyValuesCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return KeyValuesCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KeyValuesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProfilesTable extends Profiles with TableInfo<$ProfilesTable, Profile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _avatarMeta = const VerificationMeta('avatar');
  @override
  late final GeneratedColumn<String> avatar = GeneratedColumn<String>(
    'avatar',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _versionMeta = const VerificationMeta(
    'version',
  );
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
    'version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _wantedVersionMeta = const VerificationMeta(
    'wantedVersion',
  );
  @override
  late final GeneratedColumn<int> wantedVersion = GeneratedColumn<int>(
    'wanted_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _profileKeyMeta = const VerificationMeta(
    'profileKey',
  );
  @override
  late final GeneratedColumn<String> profileKey = GeneratedColumn<String>(
    'profile_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cardMeta = const VerificationMeta('card');
  @override
  late final GeneratedColumn<String> card = GeneratedColumn<String>(
    'card',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cardJsonMeta = const VerificationMeta(
    'cardJson',
  );
  @override
  late final GeneratedColumn<String> cardJson = GeneratedColumn<String>(
    'card_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cardFetchedMeta = const VerificationMeta(
    'cardFetched',
  );
  @override
  late final GeneratedColumn<String> cardFetched = GeneratedColumn<String>(
    'card_fetched',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    displayName,
    avatar,
    version,
    wantedVersion,
    profileKey,
    card,
    cardJson,
    cardFetched,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<Profile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('avatar')) {
      context.handle(
        _avatarMeta,
        avatar.isAcceptableOrUnknown(data['avatar']!, _avatarMeta),
      );
    }
    if (data.containsKey('version')) {
      context.handle(
        _versionMeta,
        version.isAcceptableOrUnknown(data['version']!, _versionMeta),
      );
    }
    if (data.containsKey('wanted_version')) {
      context.handle(
        _wantedVersionMeta,
        wantedVersion.isAcceptableOrUnknown(
          data['wanted_version']!,
          _wantedVersionMeta,
        ),
      );
    }
    if (data.containsKey('profile_key')) {
      context.handle(
        _profileKeyMeta,
        profileKey.isAcceptableOrUnknown(data['profile_key']!, _profileKeyMeta),
      );
    }
    if (data.containsKey('card')) {
      context.handle(
        _cardMeta,
        card.isAcceptableOrUnknown(data['card']!, _cardMeta),
      );
    }
    if (data.containsKey('card_json')) {
      context.handle(
        _cardJsonMeta,
        cardJson.isAcceptableOrUnknown(data['card_json']!, _cardJsonMeta),
      );
    }
    if (data.containsKey('card_fetched')) {
      context.handle(
        _cardFetchedMeta,
        cardFetched.isAcceptableOrUnknown(
          data['card_fetched']!,
          _cardFetchedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Profile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Profile(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      avatar: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar'],
      ),
      version: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}version'],
      )!,
      wantedVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}wanted_version'],
      )!,
      profileKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_key'],
      ),
      card: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}card'],
      ),
      cardJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}card_json'],
      ),
      cardFetched: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}card_fetched'],
      ),
    );
  }

  @override
  $ProfilesTable createAlias(String alias) {
    return $ProfilesTable(attachedDatabase, alias);
  }
}

class Profile extends DataClass implements Insertable<Profile> {
  final String id;
  final String displayName;

  /// Their profile picture, a [MediaRef] as JSON; null for none.
  final String? avatar;

  /// The newest of their signed profile records this device took; older ones
  /// are refused, so the server cannot bring one back. 0: none yet.
  final int version;

  /// The newest version they announced; above [version] while it has yet to
  /// be fetched.
  final int wantedVersion;

  /// Base64 key that opened their record, or said to; null if unknown so far.
  final String? profileKey;

  /// Their [ProfileCard] file as their profile says (a [MediaRef] as JSON),
  /// null for none; and the card as last fetched (JSON), with the hash of the
  /// file it came from. A newer card shows once it is fetched.
  final String? card;
  final String? cardJson;
  final String? cardFetched;
  const Profile({
    required this.id,
    required this.displayName,
    this.avatar,
    required this.version,
    required this.wantedVersion,
    this.profileKey,
    this.card,
    this.cardJson,
    this.cardFetched,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['display_name'] = Variable<String>(displayName);
    if (!nullToAbsent || avatar != null) {
      map['avatar'] = Variable<String>(avatar);
    }
    map['version'] = Variable<int>(version);
    map['wanted_version'] = Variable<int>(wantedVersion);
    if (!nullToAbsent || profileKey != null) {
      map['profile_key'] = Variable<String>(profileKey);
    }
    if (!nullToAbsent || card != null) {
      map['card'] = Variable<String>(card);
    }
    if (!nullToAbsent || cardJson != null) {
      map['card_json'] = Variable<String>(cardJson);
    }
    if (!nullToAbsent || cardFetched != null) {
      map['card_fetched'] = Variable<String>(cardFetched);
    }
    return map;
  }

  ProfilesCompanion toCompanion(bool nullToAbsent) {
    return ProfilesCompanion(
      id: Value(id),
      displayName: Value(displayName),
      avatar: avatar == null && nullToAbsent
          ? const Value.absent()
          : Value(avatar),
      version: Value(version),
      wantedVersion: Value(wantedVersion),
      profileKey: profileKey == null && nullToAbsent
          ? const Value.absent()
          : Value(profileKey),
      card: card == null && nullToAbsent ? const Value.absent() : Value(card),
      cardJson: cardJson == null && nullToAbsent
          ? const Value.absent()
          : Value(cardJson),
      cardFetched: cardFetched == null && nullToAbsent
          ? const Value.absent()
          : Value(cardFetched),
    );
  }

  factory Profile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Profile(
      id: serializer.fromJson<String>(json['id']),
      displayName: serializer.fromJson<String>(json['displayName']),
      avatar: serializer.fromJson<String?>(json['avatar']),
      version: serializer.fromJson<int>(json['version']),
      wantedVersion: serializer.fromJson<int>(json['wantedVersion']),
      profileKey: serializer.fromJson<String?>(json['profileKey']),
      card: serializer.fromJson<String?>(json['card']),
      cardJson: serializer.fromJson<String?>(json['cardJson']),
      cardFetched: serializer.fromJson<String?>(json['cardFetched']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'displayName': serializer.toJson<String>(displayName),
      'avatar': serializer.toJson<String?>(avatar),
      'version': serializer.toJson<int>(version),
      'wantedVersion': serializer.toJson<int>(wantedVersion),
      'profileKey': serializer.toJson<String?>(profileKey),
      'card': serializer.toJson<String?>(card),
      'cardJson': serializer.toJson<String?>(cardJson),
      'cardFetched': serializer.toJson<String?>(cardFetched),
    };
  }

  Profile copyWith({
    String? id,
    String? displayName,
    Value<String?> avatar = const Value.absent(),
    int? version,
    int? wantedVersion,
    Value<String?> profileKey = const Value.absent(),
    Value<String?> card = const Value.absent(),
    Value<String?> cardJson = const Value.absent(),
    Value<String?> cardFetched = const Value.absent(),
  }) => Profile(
    id: id ?? this.id,
    displayName: displayName ?? this.displayName,
    avatar: avatar.present ? avatar.value : this.avatar,
    version: version ?? this.version,
    wantedVersion: wantedVersion ?? this.wantedVersion,
    profileKey: profileKey.present ? profileKey.value : this.profileKey,
    card: card.present ? card.value : this.card,
    cardJson: cardJson.present ? cardJson.value : this.cardJson,
    cardFetched: cardFetched.present ? cardFetched.value : this.cardFetched,
  );
  Profile copyWithCompanion(ProfilesCompanion data) {
    return Profile(
      id: data.id.present ? data.id.value : this.id,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      avatar: data.avatar.present ? data.avatar.value : this.avatar,
      version: data.version.present ? data.version.value : this.version,
      wantedVersion: data.wantedVersion.present
          ? data.wantedVersion.value
          : this.wantedVersion,
      profileKey: data.profileKey.present
          ? data.profileKey.value
          : this.profileKey,
      card: data.card.present ? data.card.value : this.card,
      cardJson: data.cardJson.present ? data.cardJson.value : this.cardJson,
      cardFetched: data.cardFetched.present
          ? data.cardFetched.value
          : this.cardFetched,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Profile(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('avatar: $avatar, ')
          ..write('version: $version, ')
          ..write('wantedVersion: $wantedVersion, ')
          ..write('profileKey: $profileKey, ')
          ..write('card: $card, ')
          ..write('cardJson: $cardJson, ')
          ..write('cardFetched: $cardFetched')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    avatar,
    version,
    wantedVersion,
    profileKey,
    card,
    cardJson,
    cardFetched,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Profile &&
          other.id == this.id &&
          other.displayName == this.displayName &&
          other.avatar == this.avatar &&
          other.version == this.version &&
          other.wantedVersion == this.wantedVersion &&
          other.profileKey == this.profileKey &&
          other.card == this.card &&
          other.cardJson == this.cardJson &&
          other.cardFetched == this.cardFetched);
}

class ProfilesCompanion extends UpdateCompanion<Profile> {
  final Value<String> id;
  final Value<String> displayName;
  final Value<String?> avatar;
  final Value<int> version;
  final Value<int> wantedVersion;
  final Value<String?> profileKey;
  final Value<String?> card;
  final Value<String?> cardJson;
  final Value<String?> cardFetched;
  final Value<int> rowid;
  const ProfilesCompanion({
    this.id = const Value.absent(),
    this.displayName = const Value.absent(),
    this.avatar = const Value.absent(),
    this.version = const Value.absent(),
    this.wantedVersion = const Value.absent(),
    this.profileKey = const Value.absent(),
    this.card = const Value.absent(),
    this.cardJson = const Value.absent(),
    this.cardFetched = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProfilesCompanion.insert({
    required String id,
    required String displayName,
    this.avatar = const Value.absent(),
    this.version = const Value.absent(),
    this.wantedVersion = const Value.absent(),
    this.profileKey = const Value.absent(),
    this.card = const Value.absent(),
    this.cardJson = const Value.absent(),
    this.cardFetched = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       displayName = Value(displayName);
  static Insertable<Profile> custom({
    Expression<String>? id,
    Expression<String>? displayName,
    Expression<String>? avatar,
    Expression<int>? version,
    Expression<int>? wantedVersion,
    Expression<String>? profileKey,
    Expression<String>? card,
    Expression<String>? cardJson,
    Expression<String>? cardFetched,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (displayName != null) 'display_name': displayName,
      if (avatar != null) 'avatar': avatar,
      if (version != null) 'version': version,
      if (wantedVersion != null) 'wanted_version': wantedVersion,
      if (profileKey != null) 'profile_key': profileKey,
      if (card != null) 'card': card,
      if (cardJson != null) 'card_json': cardJson,
      if (cardFetched != null) 'card_fetched': cardFetched,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProfilesCompanion copyWith({
    Value<String>? id,
    Value<String>? displayName,
    Value<String?>? avatar,
    Value<int>? version,
    Value<int>? wantedVersion,
    Value<String?>? profileKey,
    Value<String?>? card,
    Value<String?>? cardJson,
    Value<String?>? cardFetched,
    Value<int>? rowid,
  }) {
    return ProfilesCompanion(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      avatar: avatar ?? this.avatar,
      version: version ?? this.version,
      wantedVersion: wantedVersion ?? this.wantedVersion,
      profileKey: profileKey ?? this.profileKey,
      card: card ?? this.card,
      cardJson: cardJson ?? this.cardJson,
      cardFetched: cardFetched ?? this.cardFetched,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (avatar.present) {
      map['avatar'] = Variable<String>(avatar.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (wantedVersion.present) {
      map['wanted_version'] = Variable<int>(wantedVersion.value);
    }
    if (profileKey.present) {
      map['profile_key'] = Variable<String>(profileKey.value);
    }
    if (card.present) {
      map['card'] = Variable<String>(card.value);
    }
    if (cardJson.present) {
      map['card_json'] = Variable<String>(cardJson.value);
    }
    if (cardFetched.present) {
      map['card_fetched'] = Variable<String>(cardFetched.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfilesCompanion(')
          ..write('id: $id, ')
          ..write('displayName: $displayName, ')
          ..write('avatar: $avatar, ')
          ..write('version: $version, ')
          ..write('wantedVersion: $wantedVersion, ')
          ..write('profileKey: $profileKey, ')
          ..write('card: $card, ')
          ..write('cardJson: $cardJson, ')
          ..write('cardFetched: $cardFetched, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, ConversationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isDirectMeta = const VerificationMeta(
    'isDirect',
  );
  @override
  late final GeneratedColumn<bool> isDirect = GeneratedColumn<bool>(
    'is_direct',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_direct" IN (0, 1))',
    ),
  );
  static const VerificationMeta _readUpToMeta = const VerificationMeta(
    'readUpTo',
  );
  @override
  late final GeneratedColumn<int> readUpTo = GeneratedColumn<int>(
    'read_up_to',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _moreHistoryMeta = const VerificationMeta(
    'moreHistory',
  );
  @override
  late final GeneratedColumn<bool> moreHistory = GeneratedColumn<bool>(
    'more_history',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("more_history" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _securityIssueMeta = const VerificationMeta(
    'securityIssue',
  );
  @override
  late final GeneratedColumn<String> securityIssue = GeneratedColumn<String>(
    'security_issue',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pictureMeta = const VerificationMeta(
    'picture',
  );
  @override
  late final GeneratedColumn<String> picture = GeneratedColumn<String>(
    'picture',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    isDirect,
    readUpTo,
    moreHistory,
    addedAt,
    securityIssue,
    picture,
    description,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConversationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('is_direct')) {
      context.handle(
        _isDirectMeta,
        isDirect.isAcceptableOrUnknown(data['is_direct']!, _isDirectMeta),
      );
    } else if (isInserting) {
      context.missing(_isDirectMeta);
    }
    if (data.containsKey('read_up_to')) {
      context.handle(
        _readUpToMeta,
        readUpTo.isAcceptableOrUnknown(data['read_up_to']!, _readUpToMeta),
      );
    }
    if (data.containsKey('more_history')) {
      context.handle(
        _moreHistoryMeta,
        moreHistory.isAcceptableOrUnknown(
          data['more_history']!,
          _moreHistoryMeta,
        ),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    if (data.containsKey('security_issue')) {
      context.handle(
        _securityIssueMeta,
        securityIssue.isAcceptableOrUnknown(
          data['security_issue']!,
          _securityIssueMeta,
        ),
      );
    }
    if (data.containsKey('picture')) {
      context.handle(
        _pictureMeta,
        picture.isAcceptableOrUnknown(data['picture']!, _pictureMeta),
      );
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConversationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      ),
      isDirect: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_direct'],
      )!,
      readUpTo: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}read_up_to'],
      )!,
      moreHistory: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}more_history'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}added_at'],
      )!,
      securityIssue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}security_issue'],
      ),
      picture: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}picture'],
      ),
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      ),
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class ConversationRow extends DataClass implements Insertable<ConversationRow> {
  final String id;
  final String? title;
  final bool isDirect;

  /// The user's read marker; synced across their devices.
  final int readUpTo;

  /// Older messages exist on the server than the oldest one stored here.
  final bool moreHistory;

  /// When the conversation appeared locally; orders chats without messages.
  final int addedAt;

  /// Set while sending is blocked for security reasons (an unverified device
  /// in the group, or a contact whose security key changed).
  final String? securityIssue;

  /// A group's picture ([MediaRef] as JSON; null: none). This, [title] and
  /// [description] are copies, for lists, of what its [GroupStates] row says.
  final String? picture;

  /// What a group is about (null: nothing said).
  final String? description;
  const ConversationRow({
    required this.id,
    this.title,
    required this.isDirect,
    required this.readUpTo,
    required this.moreHistory,
    required this.addedAt,
    this.securityIssue,
    this.picture,
    this.description,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || title != null) {
      map['title'] = Variable<String>(title);
    }
    map['is_direct'] = Variable<bool>(isDirect);
    map['read_up_to'] = Variable<int>(readUpTo);
    map['more_history'] = Variable<bool>(moreHistory);
    map['added_at'] = Variable<int>(addedAt);
    if (!nullToAbsent || securityIssue != null) {
      map['security_issue'] = Variable<String>(securityIssue);
    }
    if (!nullToAbsent || picture != null) {
      map['picture'] = Variable<String>(picture);
    }
    if (!nullToAbsent || description != null) {
      map['description'] = Variable<String>(description);
    }
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      title: title == null && nullToAbsent
          ? const Value.absent()
          : Value(title),
      isDirect: Value(isDirect),
      readUpTo: Value(readUpTo),
      moreHistory: Value(moreHistory),
      addedAt: Value(addedAt),
      securityIssue: securityIssue == null && nullToAbsent
          ? const Value.absent()
          : Value(securityIssue),
      picture: picture == null && nullToAbsent
          ? const Value.absent()
          : Value(picture),
      description: description == null && nullToAbsent
          ? const Value.absent()
          : Value(description),
    );
  }

  factory ConversationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String?>(json['title']),
      isDirect: serializer.fromJson<bool>(json['isDirect']),
      readUpTo: serializer.fromJson<int>(json['readUpTo']),
      moreHistory: serializer.fromJson<bool>(json['moreHistory']),
      addedAt: serializer.fromJson<int>(json['addedAt']),
      securityIssue: serializer.fromJson<String?>(json['securityIssue']),
      picture: serializer.fromJson<String?>(json['picture']),
      description: serializer.fromJson<String?>(json['description']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String?>(title),
      'isDirect': serializer.toJson<bool>(isDirect),
      'readUpTo': serializer.toJson<int>(readUpTo),
      'moreHistory': serializer.toJson<bool>(moreHistory),
      'addedAt': serializer.toJson<int>(addedAt),
      'securityIssue': serializer.toJson<String?>(securityIssue),
      'picture': serializer.toJson<String?>(picture),
      'description': serializer.toJson<String?>(description),
    };
  }

  ConversationRow copyWith({
    String? id,
    Value<String?> title = const Value.absent(),
    bool? isDirect,
    int? readUpTo,
    bool? moreHistory,
    int? addedAt,
    Value<String?> securityIssue = const Value.absent(),
    Value<String?> picture = const Value.absent(),
    Value<String?> description = const Value.absent(),
  }) => ConversationRow(
    id: id ?? this.id,
    title: title.present ? title.value : this.title,
    isDirect: isDirect ?? this.isDirect,
    readUpTo: readUpTo ?? this.readUpTo,
    moreHistory: moreHistory ?? this.moreHistory,
    addedAt: addedAt ?? this.addedAt,
    securityIssue: securityIssue.present
        ? securityIssue.value
        : this.securityIssue,
    picture: picture.present ? picture.value : this.picture,
    description: description.present ? description.value : this.description,
  );
  ConversationRow copyWithCompanion(ConversationsCompanion data) {
    return ConversationRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      isDirect: data.isDirect.present ? data.isDirect.value : this.isDirect,
      readUpTo: data.readUpTo.present ? data.readUpTo.value : this.readUpTo,
      moreHistory: data.moreHistory.present
          ? data.moreHistory.value
          : this.moreHistory,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      securityIssue: data.securityIssue.present
          ? data.securityIssue.value
          : this.securityIssue,
      picture: data.picture.present ? data.picture.value : this.picture,
      description: data.description.present
          ? data.description.value
          : this.description,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('isDirect: $isDirect, ')
          ..write('readUpTo: $readUpTo, ')
          ..write('moreHistory: $moreHistory, ')
          ..write('addedAt: $addedAt, ')
          ..write('securityIssue: $securityIssue, ')
          ..write('picture: $picture, ')
          ..write('description: $description')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    isDirect,
    readUpTo,
    moreHistory,
    addedAt,
    securityIssue,
    picture,
    description,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.isDirect == this.isDirect &&
          other.readUpTo == this.readUpTo &&
          other.moreHistory == this.moreHistory &&
          other.addedAt == this.addedAt &&
          other.securityIssue == this.securityIssue &&
          other.picture == this.picture &&
          other.description == this.description);
}

class ConversationsCompanion extends UpdateCompanion<ConversationRow> {
  final Value<String> id;
  final Value<String?> title;
  final Value<bool> isDirect;
  final Value<int> readUpTo;
  final Value<bool> moreHistory;
  final Value<int> addedAt;
  final Value<String?> securityIssue;
  final Value<String?> picture;
  final Value<String?> description;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.isDirect = const Value.absent(),
    this.readUpTo = const Value.absent(),
    this.moreHistory = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.securityIssue = const Value.absent(),
    this.picture = const Value.absent(),
    this.description = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    this.title = const Value.absent(),
    required bool isDirect,
    this.readUpTo = const Value.absent(),
    this.moreHistory = const Value.absent(),
    required int addedAt,
    this.securityIssue = const Value.absent(),
    this.picture = const Value.absent(),
    this.description = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       isDirect = Value(isDirect),
       addedAt = Value(addedAt);
  static Insertable<ConversationRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<bool>? isDirect,
    Expression<int>? readUpTo,
    Expression<bool>? moreHistory,
    Expression<int>? addedAt,
    Expression<String>? securityIssue,
    Expression<String>? picture,
    Expression<String>? description,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (isDirect != null) 'is_direct': isDirect,
      if (readUpTo != null) 'read_up_to': readUpTo,
      if (moreHistory != null) 'more_history': moreHistory,
      if (addedAt != null) 'added_at': addedAt,
      if (securityIssue != null) 'security_issue': securityIssue,
      if (picture != null) 'picture': picture,
      if (description != null) 'description': description,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith({
    Value<String>? id,
    Value<String?>? title,
    Value<bool>? isDirect,
    Value<int>? readUpTo,
    Value<bool>? moreHistory,
    Value<int>? addedAt,
    Value<String?>? securityIssue,
    Value<String?>? picture,
    Value<String?>? description,
    Value<int>? rowid,
  }) {
    return ConversationsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      isDirect: isDirect ?? this.isDirect,
      readUpTo: readUpTo ?? this.readUpTo,
      moreHistory: moreHistory ?? this.moreHistory,
      addedAt: addedAt ?? this.addedAt,
      securityIssue: securityIssue ?? this.securityIssue,
      picture: picture ?? this.picture,
      description: description ?? this.description,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (isDirect.present) {
      map['is_direct'] = Variable<bool>(isDirect.value);
    }
    if (readUpTo.present) {
      map['read_up_to'] = Variable<int>(readUpTo.value);
    }
    if (moreHistory.present) {
      map['more_history'] = Variable<bool>(moreHistory.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    if (securityIssue.present) {
      map['security_issue'] = Variable<String>(securityIssue.value);
    }
    if (picture.present) {
      map['picture'] = Variable<String>(picture.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('isDirect: $isDirect, ')
          ..write('readUpTo: $readUpTo, ')
          ..write('moreHistory: $moreHistory, ')
          ..write('addedAt: $addedAt, ')
          ..write('securityIssue: $securityIssue, ')
          ..write('picture: $picture, ')
          ..write('description: $description, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MembersTable extends Members with TableInfo<$MembersTable, Member> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MembersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _convIdMeta = const VerificationMeta('convId');
  @override
  late final GeneratedColumn<String> convId = GeneratedColumn<String>(
    'conv_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [convId, userId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'members';
  @override
  VerificationContext validateIntegrity(
    Insertable<Member> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conv_id')) {
      context.handle(
        _convIdMeta,
        convId.isAcceptableOrUnknown(data['conv_id']!, _convIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convIdMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {convId, userId};
  @override
  Member map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Member(
      convId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conv_id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
    );
  }

  @override
  $MembersTable createAlias(String alias) {
    return $MembersTable(attachedDatabase, alias);
  }
}

class Member extends DataClass implements Insertable<Member> {
  final String convId;
  final String userId;
  const Member({required this.convId, required this.userId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conv_id'] = Variable<String>(convId);
    map['user_id'] = Variable<String>(userId);
    return map;
  }

  MembersCompanion toCompanion(bool nullToAbsent) {
    return MembersCompanion(convId: Value(convId), userId: Value(userId));
  }

  factory Member.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Member(
      convId: serializer.fromJson<String>(json['convId']),
      userId: serializer.fromJson<String>(json['userId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'convId': serializer.toJson<String>(convId),
      'userId': serializer.toJson<String>(userId),
    };
  }

  Member copyWith({String? convId, String? userId}) =>
      Member(convId: convId ?? this.convId, userId: userId ?? this.userId);
  Member copyWithCompanion(MembersCompanion data) {
    return Member(
      convId: data.convId.present ? data.convId.value : this.convId,
      userId: data.userId.present ? data.userId.value : this.userId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Member(')
          ..write('convId: $convId, ')
          ..write('userId: $userId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(convId, userId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Member &&
          other.convId == this.convId &&
          other.userId == this.userId);
}

class MembersCompanion extends UpdateCompanion<Member> {
  final Value<String> convId;
  final Value<String> userId;
  final Value<int> rowid;
  const MembersCompanion({
    this.convId = const Value.absent(),
    this.userId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MembersCompanion.insert({
    required String convId,
    required String userId,
    this.rowid = const Value.absent(),
  }) : convId = Value(convId),
       userId = Value(userId);
  static Insertable<Member> custom({
    Expression<String>? convId,
    Expression<String>? userId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (convId != null) 'conv_id': convId,
      if (userId != null) 'user_id': userId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MembersCompanion copyWith({
    Value<String>? convId,
    Value<String>? userId,
    Value<int>? rowid,
  }) {
    return MembersCompanion(
      convId: convId ?? this.convId,
      userId: userId ?? this.userId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (convId.present) {
      map['conv_id'] = Variable<String>(convId.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MembersCompanion(')
          ..write('convId: $convId, ')
          ..write('userId: $userId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages with TableInfo<$MessagesTable, Message> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _convIdMeta = const VerificationMeta('convId');
  @override
  late final GeneratedColumn<String> convId = GeneratedColumn<String>(
    'conv_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _senderMeta = const VerificationMeta('sender');
  @override
  late final GeneratedColumn<String> sender = GeneratedColumn<String>(
    'sender',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tsMeta = const VerificationMeta('ts');
  @override
  late final GeneratedColumn<int> ts = GeneratedColumn<int>(
    'ts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _envelopeMeta = const VerificationMeta(
    'envelope',
  );
  @override
  late final GeneratedColumn<String> envelope = GeneratedColumn<String>(
    'envelope',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<DeliveryState, int> state =
      GeneratedColumn<int>(
        'state',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: true,
      ).withConverter<DeliveryState>($MessagesTable.$converterstate);
  static const VerificationMeta _attachmentPathMeta = const VerificationMeta(
    'attachmentPath',
  );
  @override
  late final GeneratedColumn<String> attachmentPath = GeneratedColumn<String>(
    'attachment_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _thumbnailPathMeta = const VerificationMeta(
    'thumbnailPath',
  );
  @override
  late final GeneratedColumn<String> thumbnailPath = GeneratedColumn<String>(
    'thumbnail_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _wireMeta = const VerificationMeta('wire');
  @override
  late final GeneratedColumn<String> wire = GeneratedColumn<String>(
    'wire',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _keyBackedUpMeta = const VerificationMeta(
    'keyBackedUp',
  );
  @override
  late final GeneratedColumn<bool> keyBackedUp = GeneratedColumn<bool>(
    'key_backed_up',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("key_backed_up" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _isSystemMeta = const VerificationMeta(
    'isSystem',
  );
  @override
  late final GeneratedColumn<bool> isSystem = GeneratedColumn<bool>(
    'is_system',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_system" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _targetMeta = const VerificationMeta('target');
  @override
  late final GeneratedColumn<String> target = GeneratedColumn<String>(
    'target',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    convId,
    seq,
    sender,
    ts,
    envelope,
    state,
    attachmentPath,
    thumbnailPath,
    wire,
    contentKey,
    keyBackedUp,
    isSystem,
    kind,
    target,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<Message> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conv_id')) {
      context.handle(
        _convIdMeta,
        convId.isAcceptableOrUnknown(data['conv_id']!, _convIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convIdMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    }
    if (data.containsKey('sender')) {
      context.handle(
        _senderMeta,
        sender.isAcceptableOrUnknown(data['sender']!, _senderMeta),
      );
    } else if (isInserting) {
      context.missing(_senderMeta);
    }
    if (data.containsKey('ts')) {
      context.handle(_tsMeta, ts.isAcceptableOrUnknown(data['ts']!, _tsMeta));
    } else if (isInserting) {
      context.missing(_tsMeta);
    }
    if (data.containsKey('envelope')) {
      context.handle(
        _envelopeMeta,
        envelope.isAcceptableOrUnknown(data['envelope']!, _envelopeMeta),
      );
    } else if (isInserting) {
      context.missing(_envelopeMeta);
    }
    if (data.containsKey('attachment_path')) {
      context.handle(
        _attachmentPathMeta,
        attachmentPath.isAcceptableOrUnknown(
          data['attachment_path']!,
          _attachmentPathMeta,
        ),
      );
    }
    if (data.containsKey('thumbnail_path')) {
      context.handle(
        _thumbnailPathMeta,
        thumbnailPath.isAcceptableOrUnknown(
          data['thumbnail_path']!,
          _thumbnailPathMeta,
        ),
      );
    }
    if (data.containsKey('wire')) {
      context.handle(
        _wireMeta,
        wire.isAcceptableOrUnknown(data['wire']!, _wireMeta),
      );
    }
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    }
    if (data.containsKey('key_backed_up')) {
      context.handle(
        _keyBackedUpMeta,
        keyBackedUp.isAcceptableOrUnknown(
          data['key_backed_up']!,
          _keyBackedUpMeta,
        ),
      );
    }
    if (data.containsKey('is_system')) {
      context.handle(
        _isSystemMeta,
        isSystem.isAcceptableOrUnknown(data['is_system']!, _isSystemMeta),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    }
    if (data.containsKey('target')) {
      context.handle(
        _targetMeta,
        target.isAcceptableOrUnknown(data['target']!, _targetMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Message map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Message(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      convId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conv_id'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      ),
      sender: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender'],
      )!,
      ts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ts'],
      )!,
      envelope: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}envelope'],
      )!,
      state: $MessagesTable.$converterstate.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}state'],
        )!,
      ),
      attachmentPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attachment_path'],
      ),
      thumbnailPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumbnail_path'],
      ),
      wire: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wire'],
      ),
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      ),
      keyBackedUp: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}key_backed_up'],
      )!,
      isSystem: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_system'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      ),
      target: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target'],
      ),
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<DeliveryState, int, int> $converterstate =
      const EnumIndexConverter<DeliveryState>(DeliveryState.values);
}

class Message extends DataClass implements Insertable<Message> {
  /// Client-generated ULID.
  final String id;
  final String convId;
  final int? seq;
  final String sender;
  final int ts;
  final String envelope;
  final DeliveryState state;

  /// Local files to upload before a pending media message can be sent.
  final String? attachmentPath;
  final String? thumbnailPath;

  /// The encrypted envelope as received, kept while the message cannot be
  /// decrypted yet (and for the key backup).
  final String? wire;

  /// Base64 content key, once known.
  final String? contentKey;

  /// Whether [contentKey] is in the account's key backup on the server.
  final bool keyBackedUp;

  /// A line about the group itself ("Kumiko added Naoko"), not a message:
  /// never unread, never notified.
  final bool isSystem;

  /// For a hidden message, what it is (one of [Envelope.hiddenTypes]); null
  /// for messages shown in the timeline.
  final String? kind;

  /// For a reaction, edit or deletion: the message it is about.
  final String? target;
  const Message({
    required this.id,
    required this.convId,
    this.seq,
    required this.sender,
    required this.ts,
    required this.envelope,
    required this.state,
    this.attachmentPath,
    this.thumbnailPath,
    this.wire,
    this.contentKey,
    required this.keyBackedUp,
    required this.isSystem,
    this.kind,
    this.target,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conv_id'] = Variable<String>(convId);
    if (!nullToAbsent || seq != null) {
      map['seq'] = Variable<int>(seq);
    }
    map['sender'] = Variable<String>(sender);
    map['ts'] = Variable<int>(ts);
    map['envelope'] = Variable<String>(envelope);
    {
      map['state'] = Variable<int>($MessagesTable.$converterstate.toSql(state));
    }
    if (!nullToAbsent || attachmentPath != null) {
      map['attachment_path'] = Variable<String>(attachmentPath);
    }
    if (!nullToAbsent || thumbnailPath != null) {
      map['thumbnail_path'] = Variable<String>(thumbnailPath);
    }
    if (!nullToAbsent || wire != null) {
      map['wire'] = Variable<String>(wire);
    }
    if (!nullToAbsent || contentKey != null) {
      map['content_key'] = Variable<String>(contentKey);
    }
    map['key_backed_up'] = Variable<bool>(keyBackedUp);
    map['is_system'] = Variable<bool>(isSystem);
    if (!nullToAbsent || kind != null) {
      map['kind'] = Variable<String>(kind);
    }
    if (!nullToAbsent || target != null) {
      map['target'] = Variable<String>(target);
    }
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      convId: Value(convId),
      seq: seq == null && nullToAbsent ? const Value.absent() : Value(seq),
      sender: Value(sender),
      ts: Value(ts),
      envelope: Value(envelope),
      state: Value(state),
      attachmentPath: attachmentPath == null && nullToAbsent
          ? const Value.absent()
          : Value(attachmentPath),
      thumbnailPath: thumbnailPath == null && nullToAbsent
          ? const Value.absent()
          : Value(thumbnailPath),
      wire: wire == null && nullToAbsent ? const Value.absent() : Value(wire),
      contentKey: contentKey == null && nullToAbsent
          ? const Value.absent()
          : Value(contentKey),
      keyBackedUp: Value(keyBackedUp),
      isSystem: Value(isSystem),
      kind: kind == null && nullToAbsent ? const Value.absent() : Value(kind),
      target: target == null && nullToAbsent
          ? const Value.absent()
          : Value(target),
    );
  }

  factory Message.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Message(
      id: serializer.fromJson<String>(json['id']),
      convId: serializer.fromJson<String>(json['convId']),
      seq: serializer.fromJson<int?>(json['seq']),
      sender: serializer.fromJson<String>(json['sender']),
      ts: serializer.fromJson<int>(json['ts']),
      envelope: serializer.fromJson<String>(json['envelope']),
      state: $MessagesTable.$converterstate.fromJson(
        serializer.fromJson<int>(json['state']),
      ),
      attachmentPath: serializer.fromJson<String?>(json['attachmentPath']),
      thumbnailPath: serializer.fromJson<String?>(json['thumbnailPath']),
      wire: serializer.fromJson<String?>(json['wire']),
      contentKey: serializer.fromJson<String?>(json['contentKey']),
      keyBackedUp: serializer.fromJson<bool>(json['keyBackedUp']),
      isSystem: serializer.fromJson<bool>(json['isSystem']),
      kind: serializer.fromJson<String?>(json['kind']),
      target: serializer.fromJson<String?>(json['target']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'convId': serializer.toJson<String>(convId),
      'seq': serializer.toJson<int?>(seq),
      'sender': serializer.toJson<String>(sender),
      'ts': serializer.toJson<int>(ts),
      'envelope': serializer.toJson<String>(envelope),
      'state': serializer.toJson<int>(
        $MessagesTable.$converterstate.toJson(state),
      ),
      'attachmentPath': serializer.toJson<String?>(attachmentPath),
      'thumbnailPath': serializer.toJson<String?>(thumbnailPath),
      'wire': serializer.toJson<String?>(wire),
      'contentKey': serializer.toJson<String?>(contentKey),
      'keyBackedUp': serializer.toJson<bool>(keyBackedUp),
      'isSystem': serializer.toJson<bool>(isSystem),
      'kind': serializer.toJson<String?>(kind),
      'target': serializer.toJson<String?>(target),
    };
  }

  Message copyWith({
    String? id,
    String? convId,
    Value<int?> seq = const Value.absent(),
    String? sender,
    int? ts,
    String? envelope,
    DeliveryState? state,
    Value<String?> attachmentPath = const Value.absent(),
    Value<String?> thumbnailPath = const Value.absent(),
    Value<String?> wire = const Value.absent(),
    Value<String?> contentKey = const Value.absent(),
    bool? keyBackedUp,
    bool? isSystem,
    Value<String?> kind = const Value.absent(),
    Value<String?> target = const Value.absent(),
  }) => Message(
    id: id ?? this.id,
    convId: convId ?? this.convId,
    seq: seq.present ? seq.value : this.seq,
    sender: sender ?? this.sender,
    ts: ts ?? this.ts,
    envelope: envelope ?? this.envelope,
    state: state ?? this.state,
    attachmentPath: attachmentPath.present
        ? attachmentPath.value
        : this.attachmentPath,
    thumbnailPath: thumbnailPath.present
        ? thumbnailPath.value
        : this.thumbnailPath,
    wire: wire.present ? wire.value : this.wire,
    contentKey: contentKey.present ? contentKey.value : this.contentKey,
    keyBackedUp: keyBackedUp ?? this.keyBackedUp,
    isSystem: isSystem ?? this.isSystem,
    kind: kind.present ? kind.value : this.kind,
    target: target.present ? target.value : this.target,
  );
  Message copyWithCompanion(MessagesCompanion data) {
    return Message(
      id: data.id.present ? data.id.value : this.id,
      convId: data.convId.present ? data.convId.value : this.convId,
      seq: data.seq.present ? data.seq.value : this.seq,
      sender: data.sender.present ? data.sender.value : this.sender,
      ts: data.ts.present ? data.ts.value : this.ts,
      envelope: data.envelope.present ? data.envelope.value : this.envelope,
      state: data.state.present ? data.state.value : this.state,
      attachmentPath: data.attachmentPath.present
          ? data.attachmentPath.value
          : this.attachmentPath,
      thumbnailPath: data.thumbnailPath.present
          ? data.thumbnailPath.value
          : this.thumbnailPath,
      wire: data.wire.present ? data.wire.value : this.wire,
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
      keyBackedUp: data.keyBackedUp.present
          ? data.keyBackedUp.value
          : this.keyBackedUp,
      isSystem: data.isSystem.present ? data.isSystem.value : this.isSystem,
      kind: data.kind.present ? data.kind.value : this.kind,
      target: data.target.present ? data.target.value : this.target,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Message(')
          ..write('id: $id, ')
          ..write('convId: $convId, ')
          ..write('seq: $seq, ')
          ..write('sender: $sender, ')
          ..write('ts: $ts, ')
          ..write('envelope: $envelope, ')
          ..write('state: $state, ')
          ..write('attachmentPath: $attachmentPath, ')
          ..write('thumbnailPath: $thumbnailPath, ')
          ..write('wire: $wire, ')
          ..write('contentKey: $contentKey, ')
          ..write('keyBackedUp: $keyBackedUp, ')
          ..write('isSystem: $isSystem, ')
          ..write('kind: $kind, ')
          ..write('target: $target')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    convId,
    seq,
    sender,
    ts,
    envelope,
    state,
    attachmentPath,
    thumbnailPath,
    wire,
    contentKey,
    keyBackedUp,
    isSystem,
    kind,
    target,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Message &&
          other.id == this.id &&
          other.convId == this.convId &&
          other.seq == this.seq &&
          other.sender == this.sender &&
          other.ts == this.ts &&
          other.envelope == this.envelope &&
          other.state == this.state &&
          other.attachmentPath == this.attachmentPath &&
          other.thumbnailPath == this.thumbnailPath &&
          other.wire == this.wire &&
          other.contentKey == this.contentKey &&
          other.keyBackedUp == this.keyBackedUp &&
          other.isSystem == this.isSystem &&
          other.kind == this.kind &&
          other.target == this.target);
}

class MessagesCompanion extends UpdateCompanion<Message> {
  final Value<String> id;
  final Value<String> convId;
  final Value<int?> seq;
  final Value<String> sender;
  final Value<int> ts;
  final Value<String> envelope;
  final Value<DeliveryState> state;
  final Value<String?> attachmentPath;
  final Value<String?> thumbnailPath;
  final Value<String?> wire;
  final Value<String?> contentKey;
  final Value<bool> keyBackedUp;
  final Value<bool> isSystem;
  final Value<String?> kind;
  final Value<String?> target;
  final Value<int> rowid;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.convId = const Value.absent(),
    this.seq = const Value.absent(),
    this.sender = const Value.absent(),
    this.ts = const Value.absent(),
    this.envelope = const Value.absent(),
    this.state = const Value.absent(),
    this.attachmentPath = const Value.absent(),
    this.thumbnailPath = const Value.absent(),
    this.wire = const Value.absent(),
    this.contentKey = const Value.absent(),
    this.keyBackedUp = const Value.absent(),
    this.isSystem = const Value.absent(),
    this.kind = const Value.absent(),
    this.target = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    required String id,
    required String convId,
    this.seq = const Value.absent(),
    required String sender,
    required int ts,
    required String envelope,
    required DeliveryState state,
    this.attachmentPath = const Value.absent(),
    this.thumbnailPath = const Value.absent(),
    this.wire = const Value.absent(),
    this.contentKey = const Value.absent(),
    this.keyBackedUp = const Value.absent(),
    this.isSystem = const Value.absent(),
    this.kind = const Value.absent(),
    this.target = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       convId = Value(convId),
       sender = Value(sender),
       ts = Value(ts),
       envelope = Value(envelope),
       state = Value(state);
  static Insertable<Message> custom({
    Expression<String>? id,
    Expression<String>? convId,
    Expression<int>? seq,
    Expression<String>? sender,
    Expression<int>? ts,
    Expression<String>? envelope,
    Expression<int>? state,
    Expression<String>? attachmentPath,
    Expression<String>? thumbnailPath,
    Expression<String>? wire,
    Expression<String>? contentKey,
    Expression<bool>? keyBackedUp,
    Expression<bool>? isSystem,
    Expression<String>? kind,
    Expression<String>? target,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (convId != null) 'conv_id': convId,
      if (seq != null) 'seq': seq,
      if (sender != null) 'sender': sender,
      if (ts != null) 'ts': ts,
      if (envelope != null) 'envelope': envelope,
      if (state != null) 'state': state,
      if (attachmentPath != null) 'attachment_path': attachmentPath,
      if (thumbnailPath != null) 'thumbnail_path': thumbnailPath,
      if (wire != null) 'wire': wire,
      if (contentKey != null) 'content_key': contentKey,
      if (keyBackedUp != null) 'key_backed_up': keyBackedUp,
      if (isSystem != null) 'is_system': isSystem,
      if (kind != null) 'kind': kind,
      if (target != null) 'target': target,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith({
    Value<String>? id,
    Value<String>? convId,
    Value<int?>? seq,
    Value<String>? sender,
    Value<int>? ts,
    Value<String>? envelope,
    Value<DeliveryState>? state,
    Value<String?>? attachmentPath,
    Value<String?>? thumbnailPath,
    Value<String?>? wire,
    Value<String?>? contentKey,
    Value<bool>? keyBackedUp,
    Value<bool>? isSystem,
    Value<String?>? kind,
    Value<String?>? target,
    Value<int>? rowid,
  }) {
    return MessagesCompanion(
      id: id ?? this.id,
      convId: convId ?? this.convId,
      seq: seq ?? this.seq,
      sender: sender ?? this.sender,
      ts: ts ?? this.ts,
      envelope: envelope ?? this.envelope,
      state: state ?? this.state,
      attachmentPath: attachmentPath ?? this.attachmentPath,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      wire: wire ?? this.wire,
      contentKey: contentKey ?? this.contentKey,
      keyBackedUp: keyBackedUp ?? this.keyBackedUp,
      isSystem: isSystem ?? this.isSystem,
      kind: kind ?? this.kind,
      target: target ?? this.target,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (convId.present) {
      map['conv_id'] = Variable<String>(convId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (sender.present) {
      map['sender'] = Variable<String>(sender.value);
    }
    if (ts.present) {
      map['ts'] = Variable<int>(ts.value);
    }
    if (envelope.present) {
      map['envelope'] = Variable<String>(envelope.value);
    }
    if (state.present) {
      map['state'] = Variable<int>(
        $MessagesTable.$converterstate.toSql(state.value),
      );
    }
    if (attachmentPath.present) {
      map['attachment_path'] = Variable<String>(attachmentPath.value);
    }
    if (thumbnailPath.present) {
      map['thumbnail_path'] = Variable<String>(thumbnailPath.value);
    }
    if (wire.present) {
      map['wire'] = Variable<String>(wire.value);
    }
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (keyBackedUp.present) {
      map['key_backed_up'] = Variable<bool>(keyBackedUp.value);
    }
    if (isSystem.present) {
      map['is_system'] = Variable<bool>(isSystem.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (target.present) {
      map['target'] = Variable<String>(target.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('convId: $convId, ')
          ..write('seq: $seq, ')
          ..write('sender: $sender, ')
          ..write('ts: $ts, ')
          ..write('envelope: $envelope, ')
          ..write('state: $state, ')
          ..write('attachmentPath: $attachmentPath, ')
          ..write('thumbnailPath: $thumbnailPath, ')
          ..write('wire: $wire, ')
          ..write('contentKey: $contentKey, ')
          ..write('keyBackedUp: $keyBackedUp, ')
          ..write('isSystem: $isSystem, ')
          ..write('kind: $kind, ')
          ..write('target: $target, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PinnedIdentitiesTable extends PinnedIdentities
    with TableInfo<$PinnedIdentitiesTable, PinnedIdentity> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PinnedIdentitiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _identityKeyMeta = const VerificationMeta(
    'identityKey',
  );
  @override
  late final GeneratedColumn<String> identityKey = GeneratedColumn<String>(
    'identity_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _changedToMeta = const VerificationMeta(
    'changedTo',
  );
  @override
  late final GeneratedColumn<String> changedTo = GeneratedColumn<String>(
    'changed_to',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _verifiedKeyMeta = const VerificationMeta(
    'verifiedKey',
  );
  @override
  late final GeneratedColumn<String> verifiedKey = GeneratedColumn<String>(
    'verified_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _verifiedAtMeta = const VerificationMeta(
    'verifiedAt',
  );
  @override
  late final GeneratedColumn<int> verifiedAt = GeneratedColumn<int>(
    'verified_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    identityKey,
    changedTo,
    verifiedKey,
    verifiedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pinned_identities';
  @override
  VerificationContext validateIntegrity(
    Insertable<PinnedIdentity> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('identity_key')) {
      context.handle(
        _identityKeyMeta,
        identityKey.isAcceptableOrUnknown(
          data['identity_key']!,
          _identityKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_identityKeyMeta);
    }
    if (data.containsKey('changed_to')) {
      context.handle(
        _changedToMeta,
        changedTo.isAcceptableOrUnknown(data['changed_to']!, _changedToMeta),
      );
    }
    if (data.containsKey('verified_key')) {
      context.handle(
        _verifiedKeyMeta,
        verifiedKey.isAcceptableOrUnknown(
          data['verified_key']!,
          _verifiedKeyMeta,
        ),
      );
    }
    if (data.containsKey('verified_at')) {
      context.handle(
        _verifiedAtMeta,
        verifiedAt.isAcceptableOrUnknown(data['verified_at']!, _verifiedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId};
  @override
  PinnedIdentity map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PinnedIdentity(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      identityKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}identity_key'],
      )!,
      changedTo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}changed_to'],
      ),
      verifiedKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}verified_key'],
      ),
      verifiedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}verified_at'],
      ),
    );
  }

  @override
  $PinnedIdentitiesTable createAlias(String alias) {
    return $PinnedIdentitiesTable(attachedDatabase, alias);
  }
}

class PinnedIdentity extends DataClass implements Insertable<PinnedIdentity> {
  final String userId;
  final String identityKey;

  /// A different key the server now shows, not yet accepted by the user.
  final String? changedTo;

  /// The key the user verified for this contact (emoji verification). They
  /// count as verified while it equals [identityKey].
  final String? verifiedKey;

  /// When the user's statement behind [verifiedKey] was made (see
  /// `Attestation`); older statements are ignored.
  final int? verifiedAt;
  const PinnedIdentity({
    required this.userId,
    required this.identityKey,
    this.changedTo,
    this.verifiedKey,
    this.verifiedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<String>(userId);
    map['identity_key'] = Variable<String>(identityKey);
    if (!nullToAbsent || changedTo != null) {
      map['changed_to'] = Variable<String>(changedTo);
    }
    if (!nullToAbsent || verifiedKey != null) {
      map['verified_key'] = Variable<String>(verifiedKey);
    }
    if (!nullToAbsent || verifiedAt != null) {
      map['verified_at'] = Variable<int>(verifiedAt);
    }
    return map;
  }

  PinnedIdentitiesCompanion toCompanion(bool nullToAbsent) {
    return PinnedIdentitiesCompanion(
      userId: Value(userId),
      identityKey: Value(identityKey),
      changedTo: changedTo == null && nullToAbsent
          ? const Value.absent()
          : Value(changedTo),
      verifiedKey: verifiedKey == null && nullToAbsent
          ? const Value.absent()
          : Value(verifiedKey),
      verifiedAt: verifiedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(verifiedAt),
    );
  }

  factory PinnedIdentity.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PinnedIdentity(
      userId: serializer.fromJson<String>(json['userId']),
      identityKey: serializer.fromJson<String>(json['identityKey']),
      changedTo: serializer.fromJson<String?>(json['changedTo']),
      verifiedKey: serializer.fromJson<String?>(json['verifiedKey']),
      verifiedAt: serializer.fromJson<int?>(json['verifiedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<String>(userId),
      'identityKey': serializer.toJson<String>(identityKey),
      'changedTo': serializer.toJson<String?>(changedTo),
      'verifiedKey': serializer.toJson<String?>(verifiedKey),
      'verifiedAt': serializer.toJson<int?>(verifiedAt),
    };
  }

  PinnedIdentity copyWith({
    String? userId,
    String? identityKey,
    Value<String?> changedTo = const Value.absent(),
    Value<String?> verifiedKey = const Value.absent(),
    Value<int?> verifiedAt = const Value.absent(),
  }) => PinnedIdentity(
    userId: userId ?? this.userId,
    identityKey: identityKey ?? this.identityKey,
    changedTo: changedTo.present ? changedTo.value : this.changedTo,
    verifiedKey: verifiedKey.present ? verifiedKey.value : this.verifiedKey,
    verifiedAt: verifiedAt.present ? verifiedAt.value : this.verifiedAt,
  );
  PinnedIdentity copyWithCompanion(PinnedIdentitiesCompanion data) {
    return PinnedIdentity(
      userId: data.userId.present ? data.userId.value : this.userId,
      identityKey: data.identityKey.present
          ? data.identityKey.value
          : this.identityKey,
      changedTo: data.changedTo.present ? data.changedTo.value : this.changedTo,
      verifiedKey: data.verifiedKey.present
          ? data.verifiedKey.value
          : this.verifiedKey,
      verifiedAt: data.verifiedAt.present
          ? data.verifiedAt.value
          : this.verifiedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PinnedIdentity(')
          ..write('userId: $userId, ')
          ..write('identityKey: $identityKey, ')
          ..write('changedTo: $changedTo, ')
          ..write('verifiedKey: $verifiedKey, ')
          ..write('verifiedAt: $verifiedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(userId, identityKey, changedTo, verifiedKey, verifiedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PinnedIdentity &&
          other.userId == this.userId &&
          other.identityKey == this.identityKey &&
          other.changedTo == this.changedTo &&
          other.verifiedKey == this.verifiedKey &&
          other.verifiedAt == this.verifiedAt);
}

class PinnedIdentitiesCompanion extends UpdateCompanion<PinnedIdentity> {
  final Value<String> userId;
  final Value<String> identityKey;
  final Value<String?> changedTo;
  final Value<String?> verifiedKey;
  final Value<int?> verifiedAt;
  final Value<int> rowid;
  const PinnedIdentitiesCompanion({
    this.userId = const Value.absent(),
    this.identityKey = const Value.absent(),
    this.changedTo = const Value.absent(),
    this.verifiedKey = const Value.absent(),
    this.verifiedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PinnedIdentitiesCompanion.insert({
    required String userId,
    required String identityKey,
    this.changedTo = const Value.absent(),
    this.verifiedKey = const Value.absent(),
    this.verifiedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       identityKey = Value(identityKey);
  static Insertable<PinnedIdentity> custom({
    Expression<String>? userId,
    Expression<String>? identityKey,
    Expression<String>? changedTo,
    Expression<String>? verifiedKey,
    Expression<int>? verifiedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (identityKey != null) 'identity_key': identityKey,
      if (changedTo != null) 'changed_to': changedTo,
      if (verifiedKey != null) 'verified_key': verifiedKey,
      if (verifiedAt != null) 'verified_at': verifiedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PinnedIdentitiesCompanion copyWith({
    Value<String>? userId,
    Value<String>? identityKey,
    Value<String?>? changedTo,
    Value<String?>? verifiedKey,
    Value<int?>? verifiedAt,
    Value<int>? rowid,
  }) {
    return PinnedIdentitiesCompanion(
      userId: userId ?? this.userId,
      identityKey: identityKey ?? this.identityKey,
      changedTo: changedTo ?? this.changedTo,
      verifiedKey: verifiedKey ?? this.verifiedKey,
      verifiedAt: verifiedAt ?? this.verifiedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (identityKey.present) {
      map['identity_key'] = Variable<String>(identityKey.value);
    }
    if (changedTo.present) {
      map['changed_to'] = Variable<String>(changedTo.value);
    }
    if (verifiedKey.present) {
      map['verified_key'] = Variable<String>(verifiedKey.value);
    }
    if (verifiedAt.present) {
      map['verified_at'] = Variable<int>(verifiedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PinnedIdentitiesCompanion(')
          ..write('userId: $userId, ')
          ..write('identityKey: $identityKey, ')
          ..write('changedTo: $changedTo, ')
          ..write('verifiedKey: $verifiedKey, ')
          ..write('verifiedAt: $verifiedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GroupUsersTable extends GroupUsers
    with TableInfo<$GroupUsersTable, GroupUser> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupUsersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _convIdMeta = const VerificationMeta('convId');
  @override
  late final GeneratedColumn<String> convId = GeneratedColumn<String>(
    'conv_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [convId, userId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'group_users';
  @override
  VerificationContext validateIntegrity(
    Insertable<GroupUser> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conv_id')) {
      context.handle(
        _convIdMeta,
        convId.isAcceptableOrUnknown(data['conv_id']!, _convIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convIdMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {convId, userId};
  @override
  GroupUser map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GroupUser(
      convId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conv_id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
    );
  }

  @override
  $GroupUsersTable createAlias(String alias) {
    return $GroupUsersTable(attachedDatabase, alias);
  }
}

class GroupUser extends DataClass implements Insertable<GroupUser> {
  final String convId;
  final String userId;
  const GroupUser({required this.convId, required this.userId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conv_id'] = Variable<String>(convId);
    map['user_id'] = Variable<String>(userId);
    return map;
  }

  GroupUsersCompanion toCompanion(bool nullToAbsent) {
    return GroupUsersCompanion(convId: Value(convId), userId: Value(userId));
  }

  factory GroupUser.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GroupUser(
      convId: serializer.fromJson<String>(json['convId']),
      userId: serializer.fromJson<String>(json['userId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'convId': serializer.toJson<String>(convId),
      'userId': serializer.toJson<String>(userId),
    };
  }

  GroupUser copyWith({String? convId, String? userId}) =>
      GroupUser(convId: convId ?? this.convId, userId: userId ?? this.userId);
  GroupUser copyWithCompanion(GroupUsersCompanion data) {
    return GroupUser(
      convId: data.convId.present ? data.convId.value : this.convId,
      userId: data.userId.present ? data.userId.value : this.userId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GroupUser(')
          ..write('convId: $convId, ')
          ..write('userId: $userId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(convId, userId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GroupUser &&
          other.convId == this.convId &&
          other.userId == this.userId);
}

class GroupUsersCompanion extends UpdateCompanion<GroupUser> {
  final Value<String> convId;
  final Value<String> userId;
  final Value<int> rowid;
  const GroupUsersCompanion({
    this.convId = const Value.absent(),
    this.userId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GroupUsersCompanion.insert({
    required String convId,
    required String userId,
    this.rowid = const Value.absent(),
  }) : convId = Value(convId),
       userId = Value(userId);
  static Insertable<GroupUser> custom({
    Expression<String>? convId,
    Expression<String>? userId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (convId != null) 'conv_id': convId,
      if (userId != null) 'user_id': userId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GroupUsersCompanion copyWith({
    Value<String>? convId,
    Value<String>? userId,
    Value<int>? rowid,
  }) {
    return GroupUsersCompanion(
      convId: convId ?? this.convId,
      userId: userId ?? this.userId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (convId.present) {
      map['conv_id'] = Variable<String>(convId.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupUsersCompanion(')
          ..write('convId: $convId, ')
          ..write('userId: $userId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SuspiciousLeavesTable extends SuspiciousLeaves
    with TableInfo<$SuspiciousLeavesTable, SuspiciousLeave> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SuspiciousLeavesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _convIdMeta = const VerificationMeta('convId');
  @override
  late final GeneratedColumn<String> convId = GeneratedColumn<String>(
    'conv_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _signatureKeyMeta = const VerificationMeta(
    'signatureKey',
  );
  @override
  late final GeneratedColumn<String> signatureKey = GeneratedColumn<String>(
    'signature_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [convId, signatureKey];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'suspicious_leaves';
  @override
  VerificationContext validateIntegrity(
    Insertable<SuspiciousLeave> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conv_id')) {
      context.handle(
        _convIdMeta,
        convId.isAcceptableOrUnknown(data['conv_id']!, _convIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convIdMeta);
    }
    if (data.containsKey('signature_key')) {
      context.handle(
        _signatureKeyMeta,
        signatureKey.isAcceptableOrUnknown(
          data['signature_key']!,
          _signatureKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_signatureKeyMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {convId, signatureKey};
  @override
  SuspiciousLeave map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SuspiciousLeave(
      convId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conv_id'],
      )!,
      signatureKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}signature_key'],
      )!,
    );
  }

  @override
  $SuspiciousLeavesTable createAlias(String alias) {
    return $SuspiciousLeavesTable(attachedDatabase, alias);
  }
}

class SuspiciousLeave extends DataClass implements Insertable<SuspiciousLeave> {
  final String convId;
  final String signatureKey;
  const SuspiciousLeave({required this.convId, required this.signatureKey});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conv_id'] = Variable<String>(convId);
    map['signature_key'] = Variable<String>(signatureKey);
    return map;
  }

  SuspiciousLeavesCompanion toCompanion(bool nullToAbsent) {
    return SuspiciousLeavesCompanion(
      convId: Value(convId),
      signatureKey: Value(signatureKey),
    );
  }

  factory SuspiciousLeave.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SuspiciousLeave(
      convId: serializer.fromJson<String>(json['convId']),
      signatureKey: serializer.fromJson<String>(json['signatureKey']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'convId': serializer.toJson<String>(convId),
      'signatureKey': serializer.toJson<String>(signatureKey),
    };
  }

  SuspiciousLeave copyWith({String? convId, String? signatureKey}) =>
      SuspiciousLeave(
        convId: convId ?? this.convId,
        signatureKey: signatureKey ?? this.signatureKey,
      );
  SuspiciousLeave copyWithCompanion(SuspiciousLeavesCompanion data) {
    return SuspiciousLeave(
      convId: data.convId.present ? data.convId.value : this.convId,
      signatureKey: data.signatureKey.present
          ? data.signatureKey.value
          : this.signatureKey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SuspiciousLeave(')
          ..write('convId: $convId, ')
          ..write('signatureKey: $signatureKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(convId, signatureKey);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SuspiciousLeave &&
          other.convId == this.convId &&
          other.signatureKey == this.signatureKey);
}

class SuspiciousLeavesCompanion extends UpdateCompanion<SuspiciousLeave> {
  final Value<String> convId;
  final Value<String> signatureKey;
  final Value<int> rowid;
  const SuspiciousLeavesCompanion({
    this.convId = const Value.absent(),
    this.signatureKey = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SuspiciousLeavesCompanion.insert({
    required String convId,
    required String signatureKey,
    this.rowid = const Value.absent(),
  }) : convId = Value(convId),
       signatureKey = Value(signatureKey);
  static Insertable<SuspiciousLeave> custom({
    Expression<String>? convId,
    Expression<String>? signatureKey,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (convId != null) 'conv_id': convId,
      if (signatureKey != null) 'signature_key': signatureKey,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SuspiciousLeavesCompanion copyWith({
    Value<String>? convId,
    Value<String>? signatureKey,
    Value<int>? rowid,
  }) {
    return SuspiciousLeavesCompanion(
      convId: convId ?? this.convId,
      signatureKey: signatureKey ?? this.signatureKey,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (convId.present) {
      map['conv_id'] = Variable<String>(convId.value);
    }
    if (signatureKey.present) {
      map['signature_key'] = Variable<String>(signatureKey.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SuspiciousLeavesCompanion(')
          ..write('convId: $convId, ')
          ..write('signatureKey: $signatureKey, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KeyRotationsTable extends KeyRotations
    with TableInfo<$KeyRotationsTable, KeyRotation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KeyRotationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _convIdMeta = const VerificationMeta('convId');
  @override
  late final GeneratedColumn<String> convId = GeneratedColumn<String>(
    'conv_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rotatedAtMeta = const VerificationMeta(
    'rotatedAt',
  );
  @override
  late final GeneratedColumn<int> rotatedAt = GeneratedColumn<int>(
    'rotated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sentSinceMeta = const VerificationMeta(
    'sentSince',
  );
  @override
  late final GeneratedColumn<int> sentSince = GeneratedColumn<int>(
    'sent_since',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [convId, rotatedAt, sentSince];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'key_rotations';
  @override
  VerificationContext validateIntegrity(
    Insertable<KeyRotation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conv_id')) {
      context.handle(
        _convIdMeta,
        convId.isAcceptableOrUnknown(data['conv_id']!, _convIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convIdMeta);
    }
    if (data.containsKey('rotated_at')) {
      context.handle(
        _rotatedAtMeta,
        rotatedAt.isAcceptableOrUnknown(data['rotated_at']!, _rotatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_rotatedAtMeta);
    }
    if (data.containsKey('sent_since')) {
      context.handle(
        _sentSinceMeta,
        sentSince.isAcceptableOrUnknown(data['sent_since']!, _sentSinceMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {convId};
  @override
  KeyRotation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KeyRotation(
      convId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conv_id'],
      )!,
      rotatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}rotated_at'],
      )!,
      sentSince: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sent_since'],
      )!,
    );
  }

  @override
  $KeyRotationsTable createAlias(String alias) {
    return $KeyRotationsTable(attachedDatabase, alias);
  }
}

class KeyRotation extends DataClass implements Insertable<KeyRotation> {
  final String convId;
  final int rotatedAt;
  final int sentSince;
  const KeyRotation({
    required this.convId,
    required this.rotatedAt,
    required this.sentSince,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conv_id'] = Variable<String>(convId);
    map['rotated_at'] = Variable<int>(rotatedAt);
    map['sent_since'] = Variable<int>(sentSince);
    return map;
  }

  KeyRotationsCompanion toCompanion(bool nullToAbsent) {
    return KeyRotationsCompanion(
      convId: Value(convId),
      rotatedAt: Value(rotatedAt),
      sentSince: Value(sentSince),
    );
  }

  factory KeyRotation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KeyRotation(
      convId: serializer.fromJson<String>(json['convId']),
      rotatedAt: serializer.fromJson<int>(json['rotatedAt']),
      sentSince: serializer.fromJson<int>(json['sentSince']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'convId': serializer.toJson<String>(convId),
      'rotatedAt': serializer.toJson<int>(rotatedAt),
      'sentSince': serializer.toJson<int>(sentSince),
    };
  }

  KeyRotation copyWith({String? convId, int? rotatedAt, int? sentSince}) =>
      KeyRotation(
        convId: convId ?? this.convId,
        rotatedAt: rotatedAt ?? this.rotatedAt,
        sentSince: sentSince ?? this.sentSince,
      );
  KeyRotation copyWithCompanion(KeyRotationsCompanion data) {
    return KeyRotation(
      convId: data.convId.present ? data.convId.value : this.convId,
      rotatedAt: data.rotatedAt.present ? data.rotatedAt.value : this.rotatedAt,
      sentSince: data.sentSince.present ? data.sentSince.value : this.sentSince,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KeyRotation(')
          ..write('convId: $convId, ')
          ..write('rotatedAt: $rotatedAt, ')
          ..write('sentSince: $sentSince')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(convId, rotatedAt, sentSince);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KeyRotation &&
          other.convId == this.convId &&
          other.rotatedAt == this.rotatedAt &&
          other.sentSince == this.sentSince);
}

class KeyRotationsCompanion extends UpdateCompanion<KeyRotation> {
  final Value<String> convId;
  final Value<int> rotatedAt;
  final Value<int> sentSince;
  final Value<int> rowid;
  const KeyRotationsCompanion({
    this.convId = const Value.absent(),
    this.rotatedAt = const Value.absent(),
    this.sentSince = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KeyRotationsCompanion.insert({
    required String convId,
    required int rotatedAt,
    this.sentSince = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : convId = Value(convId),
       rotatedAt = Value(rotatedAt);
  static Insertable<KeyRotation> custom({
    Expression<String>? convId,
    Expression<int>? rotatedAt,
    Expression<int>? sentSince,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (convId != null) 'conv_id': convId,
      if (rotatedAt != null) 'rotated_at': rotatedAt,
      if (sentSince != null) 'sent_since': sentSince,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KeyRotationsCompanion copyWith({
    Value<String>? convId,
    Value<int>? rotatedAt,
    Value<int>? sentSince,
    Value<int>? rowid,
  }) {
    return KeyRotationsCompanion(
      convId: convId ?? this.convId,
      rotatedAt: rotatedAt ?? this.rotatedAt,
      sentSince: sentSince ?? this.sentSince,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (convId.present) {
      map['conv_id'] = Variable<String>(convId.value);
    }
    if (rotatedAt.present) {
      map['rotated_at'] = Variable<int>(rotatedAt.value);
    }
    if (sentSince.present) {
      map['sent_since'] = Variable<int>(sentSince.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KeyRotationsCompanion(')
          ..write('convId: $convId, ')
          ..write('rotatedAt: $rotatedAt, ')
          ..write('sentSince: $sentSince, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SharedKeysTable extends SharedKeys
    with TableInfo<$SharedKeysTable, SharedKey> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SharedKeysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _shareIdMeta = const VerificationMeta(
    'shareId',
  );
  @override
  late final GeneratedColumn<String> shareId = GeneratedColumn<String>(
    'share_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _convIdMeta = const VerificationMeta('convId');
  @override
  late final GeneratedColumn<String> convId = GeneratedColumn<String>(
    'conv_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    shareId,
    convId,
    messageId,
    contentKey,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'shared_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<SharedKey> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('share_id')) {
      context.handle(
        _shareIdMeta,
        shareId.isAcceptableOrUnknown(data['share_id']!, _shareIdMeta),
      );
    } else if (isInserting) {
      context.missing(_shareIdMeta);
    }
    if (data.containsKey('conv_id')) {
      context.handle(
        _convIdMeta,
        convId.isAcceptableOrUnknown(data['conv_id']!, _convIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convIdMeta);
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_contentKeyMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {shareId, messageId};
  @override
  SharedKey map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SharedKey(
      shareId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}share_id'],
      )!,
      convId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conv_id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      )!,
    );
  }

  @override
  $SharedKeysTable createAlias(String alias) {
    return $SharedKeysTable(attachedDatabase, alias);
  }
}

class SharedKey extends DataClass implements Insertable<SharedKey> {
  /// The [Envelope.historyType] message they came in.
  final String shareId;
  final String convId;
  final String messageId;

  /// Base64, as [Messages.contentKey].
  final String contentKey;
  const SharedKey({
    required this.shareId,
    required this.convId,
    required this.messageId,
    required this.contentKey,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['share_id'] = Variable<String>(shareId);
    map['conv_id'] = Variable<String>(convId);
    map['message_id'] = Variable<String>(messageId);
    map['content_key'] = Variable<String>(contentKey);
    return map;
  }

  SharedKeysCompanion toCompanion(bool nullToAbsent) {
    return SharedKeysCompanion(
      shareId: Value(shareId),
      convId: Value(convId),
      messageId: Value(messageId),
      contentKey: Value(contentKey),
    );
  }

  factory SharedKey.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SharedKey(
      shareId: serializer.fromJson<String>(json['shareId']),
      convId: serializer.fromJson<String>(json['convId']),
      messageId: serializer.fromJson<String>(json['messageId']),
      contentKey: serializer.fromJson<String>(json['contentKey']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'shareId': serializer.toJson<String>(shareId),
      'convId': serializer.toJson<String>(convId),
      'messageId': serializer.toJson<String>(messageId),
      'contentKey': serializer.toJson<String>(contentKey),
    };
  }

  SharedKey copyWith({
    String? shareId,
    String? convId,
    String? messageId,
    String? contentKey,
  }) => SharedKey(
    shareId: shareId ?? this.shareId,
    convId: convId ?? this.convId,
    messageId: messageId ?? this.messageId,
    contentKey: contentKey ?? this.contentKey,
  );
  SharedKey copyWithCompanion(SharedKeysCompanion data) {
    return SharedKey(
      shareId: data.shareId.present ? data.shareId.value : this.shareId,
      convId: data.convId.present ? data.convId.value : this.convId,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SharedKey(')
          ..write('shareId: $shareId, ')
          ..write('convId: $convId, ')
          ..write('messageId: $messageId, ')
          ..write('contentKey: $contentKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(shareId, convId, messageId, contentKey);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SharedKey &&
          other.shareId == this.shareId &&
          other.convId == this.convId &&
          other.messageId == this.messageId &&
          other.contentKey == this.contentKey);
}

class SharedKeysCompanion extends UpdateCompanion<SharedKey> {
  final Value<String> shareId;
  final Value<String> convId;
  final Value<String> messageId;
  final Value<String> contentKey;
  final Value<int> rowid;
  const SharedKeysCompanion({
    this.shareId = const Value.absent(),
    this.convId = const Value.absent(),
    this.messageId = const Value.absent(),
    this.contentKey = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SharedKeysCompanion.insert({
    required String shareId,
    required String convId,
    required String messageId,
    required String contentKey,
    this.rowid = const Value.absent(),
  }) : shareId = Value(shareId),
       convId = Value(convId),
       messageId = Value(messageId),
       contentKey = Value(contentKey);
  static Insertable<SharedKey> custom({
    Expression<String>? shareId,
    Expression<String>? convId,
    Expression<String>? messageId,
    Expression<String>? contentKey,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (shareId != null) 'share_id': shareId,
      if (convId != null) 'conv_id': convId,
      if (messageId != null) 'message_id': messageId,
      if (contentKey != null) 'content_key': contentKey,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SharedKeysCompanion copyWith({
    Value<String>? shareId,
    Value<String>? convId,
    Value<String>? messageId,
    Value<String>? contentKey,
    Value<int>? rowid,
  }) {
    return SharedKeysCompanion(
      shareId: shareId ?? this.shareId,
      convId: convId ?? this.convId,
      messageId: messageId ?? this.messageId,
      contentKey: contentKey ?? this.contentKey,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (shareId.present) {
      map['share_id'] = Variable<String>(shareId.value);
    }
    if (convId.present) {
      map['conv_id'] = Variable<String>(convId.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SharedKeysCompanion(')
          ..write('shareId: $shareId, ')
          ..write('convId: $convId, ')
          ..write('messageId: $messageId, ')
          ..write('contentKey: $contentKey, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GroupStatesTable extends GroupStates
    with TableInfo<$GroupStatesTable, GroupStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _convIdMeta = const VerificationMeta('convId');
  @override
  late final GeneratedColumn<String> convId = GeneratedColumn<String>(
    'conv_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hashMeta = const VerificationMeta('hash');
  @override
  late final GeneratedColumn<String> hash = GeneratedColumn<String>(
    'hash',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _documentMeta = const VerificationMeta(
    'document',
  );
  @override
  late final GeneratedColumn<String> document = GeneratedColumn<String>(
    'document',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rosterMeta = const VerificationMeta('roster');
  @override
  late final GeneratedColumn<String> roster = GeneratedColumn<String>(
    'roster',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _verifiedMeta = const VerificationMeta(
    'verified',
  );
  @override
  late final GeneratedColumn<bool> verified = GeneratedColumn<bool>(
    'verified',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("verified" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    convId,
    hash,
    document,
    roster,
    verified,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'group_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<GroupStateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conv_id')) {
      context.handle(
        _convIdMeta,
        convId.isAcceptableOrUnknown(data['conv_id']!, _convIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convIdMeta);
    }
    if (data.containsKey('hash')) {
      context.handle(
        _hashMeta,
        hash.isAcceptableOrUnknown(data['hash']!, _hashMeta),
      );
    }
    if (data.containsKey('document')) {
      context.handle(
        _documentMeta,
        document.isAcceptableOrUnknown(data['document']!, _documentMeta),
      );
    }
    if (data.containsKey('roster')) {
      context.handle(
        _rosterMeta,
        roster.isAcceptableOrUnknown(data['roster']!, _rosterMeta),
      );
    }
    if (data.containsKey('verified')) {
      context.handle(
        _verifiedMeta,
        verified.isAcceptableOrUnknown(data['verified']!, _verifiedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {convId};
  @override
  GroupStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GroupStateRow(
      convId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conv_id'],
      )!,
      hash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hash'],
      ),
      document: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}document'],
      ),
      roster: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}roster'],
      )!,
      verified: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}verified'],
      )!,
    );
  }

  @override
  $GroupStatesTable createAlias(String alias) {
    return $GroupStatesTable(attachedDatabase, alias);
  }
}

class GroupStateRow extends DataClass implements Insertable<GroupStateRow> {
  final String convId;

  /// Base64 hash of the document the commits pin; null until one says.
  final String? hash;

  /// Base64 of the last document that matched a pinned hash. While [hash] says
  /// otherwise, this one keeps showing and the state counts as pending.
  final String? document;

  /// JSON `{userId: base64 profile key}`.
  final String roster;

  /// Whether [hash] came from a commit this device applied, rather than from
  /// whoever sealed the state for it when it joined.
  final bool verified;
  const GroupStateRow({
    required this.convId,
    this.hash,
    this.document,
    required this.roster,
    required this.verified,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conv_id'] = Variable<String>(convId);
    if (!nullToAbsent || hash != null) {
      map['hash'] = Variable<String>(hash);
    }
    if (!nullToAbsent || document != null) {
      map['document'] = Variable<String>(document);
    }
    map['roster'] = Variable<String>(roster);
    map['verified'] = Variable<bool>(verified);
    return map;
  }

  GroupStatesCompanion toCompanion(bool nullToAbsent) {
    return GroupStatesCompanion(
      convId: Value(convId),
      hash: hash == null && nullToAbsent ? const Value.absent() : Value(hash),
      document: document == null && nullToAbsent
          ? const Value.absent()
          : Value(document),
      roster: Value(roster),
      verified: Value(verified),
    );
  }

  factory GroupStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GroupStateRow(
      convId: serializer.fromJson<String>(json['convId']),
      hash: serializer.fromJson<String?>(json['hash']),
      document: serializer.fromJson<String?>(json['document']),
      roster: serializer.fromJson<String>(json['roster']),
      verified: serializer.fromJson<bool>(json['verified']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'convId': serializer.toJson<String>(convId),
      'hash': serializer.toJson<String?>(hash),
      'document': serializer.toJson<String?>(document),
      'roster': serializer.toJson<String>(roster),
      'verified': serializer.toJson<bool>(verified),
    };
  }

  GroupStateRow copyWith({
    String? convId,
    Value<String?> hash = const Value.absent(),
    Value<String?> document = const Value.absent(),
    String? roster,
    bool? verified,
  }) => GroupStateRow(
    convId: convId ?? this.convId,
    hash: hash.present ? hash.value : this.hash,
    document: document.present ? document.value : this.document,
    roster: roster ?? this.roster,
    verified: verified ?? this.verified,
  );
  GroupStateRow copyWithCompanion(GroupStatesCompanion data) {
    return GroupStateRow(
      convId: data.convId.present ? data.convId.value : this.convId,
      hash: data.hash.present ? data.hash.value : this.hash,
      document: data.document.present ? data.document.value : this.document,
      roster: data.roster.present ? data.roster.value : this.roster,
      verified: data.verified.present ? data.verified.value : this.verified,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GroupStateRow(')
          ..write('convId: $convId, ')
          ..write('hash: $hash, ')
          ..write('document: $document, ')
          ..write('roster: $roster, ')
          ..write('verified: $verified')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(convId, hash, document, roster, verified);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GroupStateRow &&
          other.convId == this.convId &&
          other.hash == this.hash &&
          other.document == this.document &&
          other.roster == this.roster &&
          other.verified == this.verified);
}

class GroupStatesCompanion extends UpdateCompanion<GroupStateRow> {
  final Value<String> convId;
  final Value<String?> hash;
  final Value<String?> document;
  final Value<String> roster;
  final Value<bool> verified;
  final Value<int> rowid;
  const GroupStatesCompanion({
    this.convId = const Value.absent(),
    this.hash = const Value.absent(),
    this.document = const Value.absent(),
    this.roster = const Value.absent(),
    this.verified = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GroupStatesCompanion.insert({
    required String convId,
    this.hash = const Value.absent(),
    this.document = const Value.absent(),
    this.roster = const Value.absent(),
    this.verified = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : convId = Value(convId);
  static Insertable<GroupStateRow> custom({
    Expression<String>? convId,
    Expression<String>? hash,
    Expression<String>? document,
    Expression<String>? roster,
    Expression<bool>? verified,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (convId != null) 'conv_id': convId,
      if (hash != null) 'hash': hash,
      if (document != null) 'document': document,
      if (roster != null) 'roster': roster,
      if (verified != null) 'verified': verified,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GroupStatesCompanion copyWith({
    Value<String>? convId,
    Value<String?>? hash,
    Value<String?>? document,
    Value<String>? roster,
    Value<bool>? verified,
    Value<int>? rowid,
  }) {
    return GroupStatesCompanion(
      convId: convId ?? this.convId,
      hash: hash ?? this.hash,
      document: document ?? this.document,
      roster: roster ?? this.roster,
      verified: verified ?? this.verified,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (convId.present) {
      map['conv_id'] = Variable<String>(convId.value);
    }
    if (hash.present) {
      map['hash'] = Variable<String>(hash.value);
    }
    if (document.present) {
      map['document'] = Variable<String>(document.value);
    }
    if (roster.present) {
      map['roster'] = Variable<String>(roster.value);
    }
    if (verified.present) {
      map['verified'] = Variable<bool>(verified.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupStatesCompanion(')
          ..write('convId: $convId, ')
          ..write('hash: $hash, ')
          ..write('document: $document, ')
          ..write('roster: $roster, ')
          ..write('verified: $verified, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ContactsTable extends Contacts
    with TableInfo<$ContactsTable, ContactRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ContactsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<ContactState, String> state =
      GeneratedColumn<String>(
        'state',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<ContactState>($ContactsTable.$converterstate);
  static const VerificationMeta _sinceMeta = const VerificationMeta('since');
  @override
  late final GeneratedColumn<int> since = GeneratedColumn<int>(
    'since',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _trustedMeta = const VerificationMeta(
    'trusted',
  );
  @override
  late final GeneratedColumn<bool> trusted = GeneratedColumn<bool>(
    'trusted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("trusted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [userId, state, since, trusted];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'contacts';
  @override
  VerificationContext validateIntegrity(
    Insertable<ContactRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('since')) {
      context.handle(
        _sinceMeta,
        since.isAcceptableOrUnknown(data['since']!, _sinceMeta),
      );
    }
    if (data.containsKey('trusted')) {
      context.handle(
        _trustedMeta,
        trusted.isAcceptableOrUnknown(data['trusted']!, _trustedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId};
  @override
  ContactRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ContactRow(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      state: $ContactsTable.$converterstate.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}state'],
        )!,
      ),
      since: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}since'],
      )!,
      trusted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}trusted'],
      )!,
    );
  }

  @override
  $ContactsTable createAlias(String alias) {
    return $ContactsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<ContactState, String, String> $converterstate =
      const EnumNameConverter<ContactState>(ContactState.values);
}

class ContactRow extends DataClass implements Insertable<ContactRow> {
  final String userId;
  final ContactState state;
  final int since;
  final bool trusted;
  const ContactRow({
    required this.userId,
    required this.state,
    required this.since,
    required this.trusted,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<String>(userId);
    {
      map['state'] = Variable<String>(
        $ContactsTable.$converterstate.toSql(state),
      );
    }
    map['since'] = Variable<int>(since);
    map['trusted'] = Variable<bool>(trusted);
    return map;
  }

  ContactsCompanion toCompanion(bool nullToAbsent) {
    return ContactsCompanion(
      userId: Value(userId),
      state: Value(state),
      since: Value(since),
      trusted: Value(trusted),
    );
  }

  factory ContactRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ContactRow(
      userId: serializer.fromJson<String>(json['userId']),
      state: $ContactsTable.$converterstate.fromJson(
        serializer.fromJson<String>(json['state']),
      ),
      since: serializer.fromJson<int>(json['since']),
      trusted: serializer.fromJson<bool>(json['trusted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<String>(userId),
      'state': serializer.toJson<String>(
        $ContactsTable.$converterstate.toJson(state),
      ),
      'since': serializer.toJson<int>(since),
      'trusted': serializer.toJson<bool>(trusted),
    };
  }

  ContactRow copyWith({
    String? userId,
    ContactState? state,
    int? since,
    bool? trusted,
  }) => ContactRow(
    userId: userId ?? this.userId,
    state: state ?? this.state,
    since: since ?? this.since,
    trusted: trusted ?? this.trusted,
  );
  ContactRow copyWithCompanion(ContactsCompanion data) {
    return ContactRow(
      userId: data.userId.present ? data.userId.value : this.userId,
      state: data.state.present ? data.state.value : this.state,
      since: data.since.present ? data.since.value : this.since,
      trusted: data.trusted.present ? data.trusted.value : this.trusted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ContactRow(')
          ..write('userId: $userId, ')
          ..write('state: $state, ')
          ..write('since: $since, ')
          ..write('trusted: $trusted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(userId, state, since, trusted);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ContactRow &&
          other.userId == this.userId &&
          other.state == this.state &&
          other.since == this.since &&
          other.trusted == this.trusted);
}

class ContactsCompanion extends UpdateCompanion<ContactRow> {
  final Value<String> userId;
  final Value<ContactState> state;
  final Value<int> since;
  final Value<bool> trusted;
  final Value<int> rowid;
  const ContactsCompanion({
    this.userId = const Value.absent(),
    this.state = const Value.absent(),
    this.since = const Value.absent(),
    this.trusted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ContactsCompanion.insert({
    required String userId,
    required ContactState state,
    this.since = const Value.absent(),
    this.trusted = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       state = Value(state);
  static Insertable<ContactRow> custom({
    Expression<String>? userId,
    Expression<String>? state,
    Expression<int>? since,
    Expression<bool>? trusted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (state != null) 'state': state,
      if (since != null) 'since': since,
      if (trusted != null) 'trusted': trusted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ContactsCompanion copyWith({
    Value<String>? userId,
    Value<ContactState>? state,
    Value<int>? since,
    Value<bool>? trusted,
    Value<int>? rowid,
  }) {
    return ContactsCompanion(
      userId: userId ?? this.userId,
      state: state ?? this.state,
      since: since ?? this.since,
      trusted: trusted ?? this.trusted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(
        $ContactsTable.$converterstate.toSql(state.value),
      );
    }
    if (since.present) {
      map['since'] = Variable<int>(since.value);
    }
    if (trusted.present) {
      map['trusted'] = Variable<bool>(trusted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ContactsCompanion(')
          ..write('userId: $userId, ')
          ..write('state: $state, ')
          ..write('since: $since, ')
          ..write('trusted: $trusted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RefusedConversationsTable extends RefusedConversations
    with TableInfo<$RefusedConversationsTable, RefusedConversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RefusedConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _convIdMeta = const VerificationMeta('convId');
  @override
  late final GeneratedColumn<String> convId = GeneratedColumn<String>(
    'conv_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [convId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'refused_conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<RefusedConversation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conv_id')) {
      context.handle(
        _convIdMeta,
        convId.isAcceptableOrUnknown(data['conv_id']!, _convIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {convId};
  @override
  RefusedConversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RefusedConversation(
      convId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conv_id'],
      )!,
    );
  }

  @override
  $RefusedConversationsTable createAlias(String alias) {
    return $RefusedConversationsTable(attachedDatabase, alias);
  }
}

class RefusedConversation extends DataClass
    implements Insertable<RefusedConversation> {
  final String convId;
  const RefusedConversation({required this.convId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conv_id'] = Variable<String>(convId);
    return map;
  }

  RefusedConversationsCompanion toCompanion(bool nullToAbsent) {
    return RefusedConversationsCompanion(convId: Value(convId));
  }

  factory RefusedConversation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RefusedConversation(
      convId: serializer.fromJson<String>(json['convId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{'convId': serializer.toJson<String>(convId)};
  }

  RefusedConversation copyWith({String? convId}) =>
      RefusedConversation(convId: convId ?? this.convId);
  RefusedConversation copyWithCompanion(RefusedConversationsCompanion data) {
    return RefusedConversation(
      convId: data.convId.present ? data.convId.value : this.convId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RefusedConversation(')
          ..write('convId: $convId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => convId.hashCode;
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RefusedConversation && other.convId == this.convId);
}

class RefusedConversationsCompanion
    extends UpdateCompanion<RefusedConversation> {
  final Value<String> convId;
  final Value<int> rowid;
  const RefusedConversationsCompanion({
    this.convId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RefusedConversationsCompanion.insert({
    required String convId,
    this.rowid = const Value.absent(),
  }) : convId = Value(convId);
  static Insertable<RefusedConversation> custom({
    Expression<String>? convId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (convId != null) 'conv_id': convId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RefusedConversationsCompanion copyWith({
    Value<String>? convId,
    Value<int>? rowid,
  }) {
    return RefusedConversationsCompanion(
      convId: convId ?? this.convId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (convId.present) {
      map['conv_id'] = Variable<String>(convId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RefusedConversationsCompanion(')
          ..write('convId: $convId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $UnsettledCommitsTable extends UnsettledCommits
    with TableInfo<$UnsettledCommitsTable, UnsettledCommitRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $UnsettledCommitsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _convIdMeta = const VerificationMeta('convId');
  @override
  late final GeneratedColumn<String> convId = GeneratedColumn<String>(
    'conv_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<int> epoch = GeneratedColumn<int>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _creatingMeta = const VerificationMeta(
    'creating',
  );
  @override
  late final GeneratedColumn<bool> creating = GeneratedColumn<bool>(
    'creating',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("creating" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _documentMeta = const VerificationMeta(
    'document',
  );
  @override
  late final GeneratedColumn<String> document = GeneratedColumn<String>(
    'document',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _rosterMeta = const VerificationMeta('roster');
  @override
  late final GeneratedColumn<String> roster = GeneratedColumn<String>(
    'roster',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _changesDocumentMeta = const VerificationMeta(
    'changesDocument',
  );
  @override
  late final GeneratedColumn<bool> changesDocument = GeneratedColumn<bool>(
    'changes_document',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("changes_document" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _usersMeta = const VerificationMeta('users');
  @override
  late final GeneratedColumn<String> users = GeneratedColumn<String>(
    'users',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _requestMeta = const VerificationMeta(
    'request',
  );
  @override
  late final GeneratedColumn<String> request = GeneratedColumn<String>(
    'request',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    convId,
    epoch,
    creating,
    document,
    roster,
    changesDocument,
    users,
    request,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'unsettled_commits';
  @override
  VerificationContext validateIntegrity(
    Insertable<UnsettledCommitRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conv_id')) {
      context.handle(
        _convIdMeta,
        convId.isAcceptableOrUnknown(data['conv_id']!, _convIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convIdMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('creating')) {
      context.handle(
        _creatingMeta,
        creating.isAcceptableOrUnknown(data['creating']!, _creatingMeta),
      );
    }
    if (data.containsKey('document')) {
      context.handle(
        _documentMeta,
        document.isAcceptableOrUnknown(data['document']!, _documentMeta),
      );
    }
    if (data.containsKey('roster')) {
      context.handle(
        _rosterMeta,
        roster.isAcceptableOrUnknown(data['roster']!, _rosterMeta),
      );
    }
    if (data.containsKey('changes_document')) {
      context.handle(
        _changesDocumentMeta,
        changesDocument.isAcceptableOrUnknown(
          data['changes_document']!,
          _changesDocumentMeta,
        ),
      );
    }
    if (data.containsKey('users')) {
      context.handle(
        _usersMeta,
        users.isAcceptableOrUnknown(data['users']!, _usersMeta),
      );
    }
    if (data.containsKey('request')) {
      context.handle(
        _requestMeta,
        request.isAcceptableOrUnknown(data['request']!, _requestMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {convId};
  @override
  UnsettledCommitRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return UnsettledCommitRow(
      convId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conv_id'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}epoch'],
      )!,
      creating: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}creating'],
      )!,
      document: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}document'],
      ),
      roster: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}roster'],
      ),
      changesDocument: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}changes_document'],
      )!,
      users: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}users'],
      )!,
      request: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}request'],
      ),
    );
  }

  @override
  $UnsettledCommitsTable createAlias(String alias) {
    return $UnsettledCommitsTable(attachedDatabase, alias);
  }
}

class UnsettledCommitRow extends DataClass
    implements Insertable<UnsettledCommitRow> {
  final String convId;

  /// The epoch the commit is for.
  final int epoch;

  /// It creates the conversation: if that exists at all, it counted.
  final bool creating;

  /// The state it leaves the group with, as in [GroupStates]; null from a device
  /// that does not hold it.
  final String? document;
  final String? roster;

  /// It changes the document, which the user's own timeline should say.
  final bool changesDocument;

  /// JSON list of the users it brings in.
  final String users;

  /// For [creating]: the request as sent, JSON `{"members"?, "directWith"?,
  /// "group"}`, so that it can be sent again unchanged. The server answers a
  /// repeat with what the first one made.
  final String? request;
  const UnsettledCommitRow({
    required this.convId,
    required this.epoch,
    required this.creating,
    this.document,
    this.roster,
    required this.changesDocument,
    required this.users,
    this.request,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conv_id'] = Variable<String>(convId);
    map['epoch'] = Variable<int>(epoch);
    map['creating'] = Variable<bool>(creating);
    if (!nullToAbsent || document != null) {
      map['document'] = Variable<String>(document);
    }
    if (!nullToAbsent || roster != null) {
      map['roster'] = Variable<String>(roster);
    }
    map['changes_document'] = Variable<bool>(changesDocument);
    map['users'] = Variable<String>(users);
    if (!nullToAbsent || request != null) {
      map['request'] = Variable<String>(request);
    }
    return map;
  }

  UnsettledCommitsCompanion toCompanion(bool nullToAbsent) {
    return UnsettledCommitsCompanion(
      convId: Value(convId),
      epoch: Value(epoch),
      creating: Value(creating),
      document: document == null && nullToAbsent
          ? const Value.absent()
          : Value(document),
      roster: roster == null && nullToAbsent
          ? const Value.absent()
          : Value(roster),
      changesDocument: Value(changesDocument),
      users: Value(users),
      request: request == null && nullToAbsent
          ? const Value.absent()
          : Value(request),
    );
  }

  factory UnsettledCommitRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return UnsettledCommitRow(
      convId: serializer.fromJson<String>(json['convId']),
      epoch: serializer.fromJson<int>(json['epoch']),
      creating: serializer.fromJson<bool>(json['creating']),
      document: serializer.fromJson<String?>(json['document']),
      roster: serializer.fromJson<String?>(json['roster']),
      changesDocument: serializer.fromJson<bool>(json['changesDocument']),
      users: serializer.fromJson<String>(json['users']),
      request: serializer.fromJson<String?>(json['request']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'convId': serializer.toJson<String>(convId),
      'epoch': serializer.toJson<int>(epoch),
      'creating': serializer.toJson<bool>(creating),
      'document': serializer.toJson<String?>(document),
      'roster': serializer.toJson<String?>(roster),
      'changesDocument': serializer.toJson<bool>(changesDocument),
      'users': serializer.toJson<String>(users),
      'request': serializer.toJson<String?>(request),
    };
  }

  UnsettledCommitRow copyWith({
    String? convId,
    int? epoch,
    bool? creating,
    Value<String?> document = const Value.absent(),
    Value<String?> roster = const Value.absent(),
    bool? changesDocument,
    String? users,
    Value<String?> request = const Value.absent(),
  }) => UnsettledCommitRow(
    convId: convId ?? this.convId,
    epoch: epoch ?? this.epoch,
    creating: creating ?? this.creating,
    document: document.present ? document.value : this.document,
    roster: roster.present ? roster.value : this.roster,
    changesDocument: changesDocument ?? this.changesDocument,
    users: users ?? this.users,
    request: request.present ? request.value : this.request,
  );
  UnsettledCommitRow copyWithCompanion(UnsettledCommitsCompanion data) {
    return UnsettledCommitRow(
      convId: data.convId.present ? data.convId.value : this.convId,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      creating: data.creating.present ? data.creating.value : this.creating,
      document: data.document.present ? data.document.value : this.document,
      roster: data.roster.present ? data.roster.value : this.roster,
      changesDocument: data.changesDocument.present
          ? data.changesDocument.value
          : this.changesDocument,
      users: data.users.present ? data.users.value : this.users,
      request: data.request.present ? data.request.value : this.request,
    );
  }

  @override
  String toString() {
    return (StringBuffer('UnsettledCommitRow(')
          ..write('convId: $convId, ')
          ..write('epoch: $epoch, ')
          ..write('creating: $creating, ')
          ..write('document: $document, ')
          ..write('roster: $roster, ')
          ..write('changesDocument: $changesDocument, ')
          ..write('users: $users, ')
          ..write('request: $request')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    convId,
    epoch,
    creating,
    document,
    roster,
    changesDocument,
    users,
    request,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is UnsettledCommitRow &&
          other.convId == this.convId &&
          other.epoch == this.epoch &&
          other.creating == this.creating &&
          other.document == this.document &&
          other.roster == this.roster &&
          other.changesDocument == this.changesDocument &&
          other.users == this.users &&
          other.request == this.request);
}

class UnsettledCommitsCompanion extends UpdateCompanion<UnsettledCommitRow> {
  final Value<String> convId;
  final Value<int> epoch;
  final Value<bool> creating;
  final Value<String?> document;
  final Value<String?> roster;
  final Value<bool> changesDocument;
  final Value<String> users;
  final Value<String?> request;
  final Value<int> rowid;
  const UnsettledCommitsCompanion({
    this.convId = const Value.absent(),
    this.epoch = const Value.absent(),
    this.creating = const Value.absent(),
    this.document = const Value.absent(),
    this.roster = const Value.absent(),
    this.changesDocument = const Value.absent(),
    this.users = const Value.absent(),
    this.request = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  UnsettledCommitsCompanion.insert({
    required String convId,
    required int epoch,
    this.creating = const Value.absent(),
    this.document = const Value.absent(),
    this.roster = const Value.absent(),
    this.changesDocument = const Value.absent(),
    this.users = const Value.absent(),
    this.request = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : convId = Value(convId),
       epoch = Value(epoch);
  static Insertable<UnsettledCommitRow> custom({
    Expression<String>? convId,
    Expression<int>? epoch,
    Expression<bool>? creating,
    Expression<String>? document,
    Expression<String>? roster,
    Expression<bool>? changesDocument,
    Expression<String>? users,
    Expression<String>? request,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (convId != null) 'conv_id': convId,
      if (epoch != null) 'epoch': epoch,
      if (creating != null) 'creating': creating,
      if (document != null) 'document': document,
      if (roster != null) 'roster': roster,
      if (changesDocument != null) 'changes_document': changesDocument,
      if (users != null) 'users': users,
      if (request != null) 'request': request,
      if (rowid != null) 'rowid': rowid,
    });
  }

  UnsettledCommitsCompanion copyWith({
    Value<String>? convId,
    Value<int>? epoch,
    Value<bool>? creating,
    Value<String?>? document,
    Value<String?>? roster,
    Value<bool>? changesDocument,
    Value<String>? users,
    Value<String?>? request,
    Value<int>? rowid,
  }) {
    return UnsettledCommitsCompanion(
      convId: convId ?? this.convId,
      epoch: epoch ?? this.epoch,
      creating: creating ?? this.creating,
      document: document ?? this.document,
      roster: roster ?? this.roster,
      changesDocument: changesDocument ?? this.changesDocument,
      users: users ?? this.users,
      request: request ?? this.request,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (convId.present) {
      map['conv_id'] = Variable<String>(convId.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<int>(epoch.value);
    }
    if (creating.present) {
      map['creating'] = Variable<bool>(creating.value);
    }
    if (document.present) {
      map['document'] = Variable<String>(document.value);
    }
    if (roster.present) {
      map['roster'] = Variable<String>(roster.value);
    }
    if (changesDocument.present) {
      map['changes_document'] = Variable<bool>(changesDocument.value);
    }
    if (users.present) {
      map['users'] = Variable<String>(users.value);
    }
    if (request.present) {
      map['request'] = Variable<String>(request.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('UnsettledCommitsCompanion(')
          ..write('convId: $convId, ')
          ..write('epoch: $epoch, ')
          ..write('creating: $creating, ')
          ..write('document: $document, ')
          ..write('roster: $roster, ')
          ..write('changesDocument: $changesDocument, ')
          ..write('users: $users, ')
          ..write('request: $request, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $KeyValuesTable keyValues = $KeyValuesTable(this);
  late final $ProfilesTable profiles = $ProfilesTable(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $MembersTable members = $MembersTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $PinnedIdentitiesTable pinnedIdentities = $PinnedIdentitiesTable(
    this,
  );
  late final $GroupUsersTable groupUsers = $GroupUsersTable(this);
  late final $SuspiciousLeavesTable suspiciousLeaves = $SuspiciousLeavesTable(
    this,
  );
  late final $KeyRotationsTable keyRotations = $KeyRotationsTable(this);
  late final $SharedKeysTable sharedKeys = $SharedKeysTable(this);
  late final $GroupStatesTable groupStates = $GroupStatesTable(this);
  late final $ContactsTable contacts = $ContactsTable(this);
  late final $RefusedConversationsTable refusedConversations =
      $RefusedConversationsTable(this);
  late final $UnsettledCommitsTable unsettledCommits = $UnsettledCommitsTable(
    this,
  );
  late final Index messagesConvSeq = Index(
    'messages_conv_seq',
    'CREATE INDEX messages_conv_seq ON messages (conv_id, seq)',
  );
  late final Index messagesTarget = Index(
    'messages_target',
    'CREATE INDEX messages_target ON messages (target)',
  );
  late final Index sharedKeysMessage = Index(
    'shared_keys_message',
    'CREATE INDEX shared_keys_message ON shared_keys (message_id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    keyValues,
    profiles,
    conversations,
    members,
    messages,
    pinnedIdentities,
    groupUsers,
    suspiciousLeaves,
    keyRotations,
    sharedKeys,
    groupStates,
    contacts,
    refusedConversations,
    unsettledCommits,
    messagesConvSeq,
    messagesTarget,
    sharedKeysMessage,
  ];
}

typedef $$KeyValuesTableCreateCompanionBuilder = KeyValuesCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$KeyValuesTableUpdateCompanionBuilder = KeyValuesCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$KeyValuesTableFilterComposer
    extends Composer<_$AppDatabase, $KeyValuesTable> {
  $$KeyValuesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KeyValuesTableOrderingComposer
    extends Composer<_$AppDatabase, $KeyValuesTable> {
  $$KeyValuesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KeyValuesTableAnnotationComposer
    extends Composer<_$AppDatabase, $KeyValuesTable> {
  $$KeyValuesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$KeyValuesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KeyValuesTable,
          KeyValue,
          $$KeyValuesTableFilterComposer,
          $$KeyValuesTableOrderingComposer,
          $$KeyValuesTableAnnotationComposer,
          $$KeyValuesTableCreateCompanionBuilder,
          $$KeyValuesTableUpdateCompanionBuilder,
          (KeyValue, BaseReferences<_$AppDatabase, $KeyValuesTable, KeyValue>),
          KeyValue,
          PrefetchHooks Function()
        > {
  $$KeyValuesTableTableManager(_$AppDatabase db, $KeyValuesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KeyValuesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KeyValuesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KeyValuesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => KeyValuesCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => KeyValuesCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KeyValuesTable, KeyValue>(table),
                  BaseReferences<_$AppDatabase, $KeyValuesTable, KeyValue>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KeyValuesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KeyValuesTable,
      KeyValue,
      $$KeyValuesTableFilterComposer,
      $$KeyValuesTableOrderingComposer,
      $$KeyValuesTableAnnotationComposer,
      $$KeyValuesTableCreateCompanionBuilder,
      $$KeyValuesTableUpdateCompanionBuilder,
      (KeyValue, BaseReferences<_$AppDatabase, $KeyValuesTable, KeyValue>),
      KeyValue,
      PrefetchHooks Function()
    >;
typedef $$ProfilesTableCreateCompanionBuilder = ProfilesCompanion Function({
  required String id,
  required String displayName,
  Value<String?> avatar,
  Value<int> version,
  Value<int> wantedVersion,
  Value<String?> profileKey,
  Value<String?> card,
  Value<String?> cardJson,
  Value<String?> cardFetched,
  Value<int> rowid,
});
typedef $$ProfilesTableUpdateCompanionBuilder = ProfilesCompanion Function({
  Value<String> id,
  Value<String> displayName,
  Value<String?> avatar,
  Value<int> version,
  Value<int> wantedVersion,
  Value<String?> profileKey,
  Value<String?> card,
  Value<String?> cardJson,
  Value<String?> cardFetched,
  Value<int> rowid,
});

class $$ProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatar => $composableBuilder(
    column: $table.avatar,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get wantedVersion => $composableBuilder(
    column: $table.wantedVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileKey => $composableBuilder(
    column: $table.profileKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get card => $composableBuilder(
    column: $table.card,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cardJson => $composableBuilder(
    column: $table.cardJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cardFetched => $composableBuilder(
    column: $table.cardFetched,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatar => $composableBuilder(
    column: $table.avatar,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get version => $composableBuilder(
    column: $table.version,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get wantedVersion => $composableBuilder(
    column: $table.wantedVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileKey => $composableBuilder(
    column: $table.profileKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get card => $composableBuilder(
    column: $table.card,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cardJson => $composableBuilder(
    column: $table.cardJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cardFetched => $composableBuilder(
    column: $table.cardFetched,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get avatar =>
      $composableBuilder(column: $table.avatar, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<int> get wantedVersion => $composableBuilder(
    column: $table.wantedVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get profileKey => $composableBuilder(
    column: $table.profileKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get card =>
      $composableBuilder(column: $table.card, builder: (column) => column);

  GeneratedColumn<String> get cardJson =>
      $composableBuilder(column: $table.cardJson, builder: (column) => column);

  GeneratedColumn<String> get cardFetched => $composableBuilder(
    column: $table.cardFetched,
    builder: (column) => column,
  );
}

class $$ProfilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProfilesTable,
          Profile,
          $$ProfilesTableFilterComposer,
          $$ProfilesTableOrderingComposer,
          $$ProfilesTableAnnotationComposer,
          $$ProfilesTableCreateCompanionBuilder,
          $$ProfilesTableUpdateCompanionBuilder,
          (Profile, BaseReferences<_$AppDatabase, $ProfilesTable, Profile>),
          Profile,
          PrefetchHooks Function()
        > {
  $$ProfilesTableTableManager(_$AppDatabase db, $ProfilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String?> avatar = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<int> wantedVersion = const Value.absent(),
                Value<String?> profileKey = const Value.absent(),
                Value<String?> card = const Value.absent(),
                Value<String?> cardJson = const Value.absent(),
                Value<String?> cardFetched = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion(
                id: id,
                displayName: displayName,
                avatar: avatar,
                version: version,
                wantedVersion: wantedVersion,
                profileKey: profileKey,
                card: card,
                cardJson: cardJson,
                cardFetched: cardFetched,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String displayName,
                Value<String?> avatar = const Value.absent(),
                Value<int> version = const Value.absent(),
                Value<int> wantedVersion = const Value.absent(),
                Value<String?> profileKey = const Value.absent(),
                Value<String?> card = const Value.absent(),
                Value<String?> cardJson = const Value.absent(),
                Value<String?> cardFetched = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion.insert(
                id: id,
                displayName: displayName,
                avatar: avatar,
                version: version,
                wantedVersion: wantedVersion,
                profileKey: profileKey,
                card: card,
                cardJson: cardJson,
                cardFetched: cardFetched,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ProfilesTable, Profile>(table),
                  BaseReferences<_$AppDatabase, $ProfilesTable, Profile>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProfilesTable,
      Profile,
      $$ProfilesTableFilterComposer,
      $$ProfilesTableOrderingComposer,
      $$ProfilesTableAnnotationComposer,
      $$ProfilesTableCreateCompanionBuilder,
      $$ProfilesTableUpdateCompanionBuilder,
      (Profile, BaseReferences<_$AppDatabase, $ProfilesTable, Profile>),
      Profile,
      PrefetchHooks Function()
    >;
typedef $$ConversationsTableCreateCompanionBuilder =
    ConversationsCompanion Function({
      required String id,
      Value<String?> title,
      required bool isDirect,
      Value<int> readUpTo,
      Value<bool> moreHistory,
      required int addedAt,
      Value<String?> securityIssue,
      Value<String?> picture,
      Value<String?> description,
      Value<int> rowid,
    });
typedef $$ConversationsTableUpdateCompanionBuilder =
    ConversationsCompanion Function({
      Value<String> id,
      Value<String?> title,
      Value<bool> isDirect,
      Value<int> readUpTo,
      Value<bool> moreHistory,
      Value<int> addedAt,
      Value<String?> securityIssue,
      Value<String?> picture,
      Value<String?> description,
      Value<int> rowid,
    });

class $$ConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDirect => $composableBuilder(
    column: $table.isDirect,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get readUpTo => $composableBuilder(
    column: $table.readUpTo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get moreHistory => $composableBuilder(
    column: $table.moreHistory,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get securityIssue => $composableBuilder(
    column: $table.securityIssue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get picture => $composableBuilder(
    column: $table.picture,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDirect => $composableBuilder(
    column: $table.isDirect,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get readUpTo => $composableBuilder(
    column: $table.readUpTo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get moreHistory => $composableBuilder(
    column: $table.moreHistory,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get securityIssue => $composableBuilder(
    column: $table.securityIssue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get picture => $composableBuilder(
    column: $table.picture,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<bool> get isDirect =>
      $composableBuilder(column: $table.isDirect, builder: (column) => column);

  GeneratedColumn<int> get readUpTo =>
      $composableBuilder(column: $table.readUpTo, builder: (column) => column);

  GeneratedColumn<bool> get moreHistory => $composableBuilder(
    column: $table.moreHistory,
    builder: (column) => column,
  );

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<String> get securityIssue => $composableBuilder(
    column: $table.securityIssue,
    builder: (column) => column,
  );

  GeneratedColumn<String> get picture =>
      $composableBuilder(column: $table.picture, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );
}

class $$ConversationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConversationsTable,
          ConversationRow,
          $$ConversationsTableFilterComposer,
          $$ConversationsTableOrderingComposer,
          $$ConversationsTableAnnotationComposer,
          $$ConversationsTableCreateCompanionBuilder,
          $$ConversationsTableUpdateCompanionBuilder,
          (
            ConversationRow,
            BaseReferences<_$AppDatabase, $ConversationsTable, ConversationRow>,
          ),
          ConversationRow,
          PrefetchHooks Function()
        > {
  $$ConversationsTableTableManager(_$AppDatabase db, $ConversationsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<bool> isDirect = const Value.absent(),
                Value<int> readUpTo = const Value.absent(),
                Value<bool> moreHistory = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
                Value<String?> securityIssue = const Value.absent(),
                Value<String?> picture = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion(
                id: id,
                title: title,
                isDirect: isDirect,
                readUpTo: readUpTo,
                moreHistory: moreHistory,
                addedAt: addedAt,
                securityIssue: securityIssue,
                picture: picture,
                description: description,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> title = const Value.absent(),
                required bool isDirect,
                Value<int> readUpTo = const Value.absent(),
                Value<bool> moreHistory = const Value.absent(),
                required int addedAt,
                Value<String?> securityIssue = const Value.absent(),
                Value<String?> picture = const Value.absent(),
                Value<String?> description = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion.insert(
                id: id,
                title: title,
                isDirect: isDirect,
                readUpTo: readUpTo,
                moreHistory: moreHistory,
                addedAt: addedAt,
                securityIssue: securityIssue,
                picture: picture,
                description: description,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConversationsTable, ConversationRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ConversationsTable,
                    ConversationRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConversationsTable,
      ConversationRow,
      $$ConversationsTableFilterComposer,
      $$ConversationsTableOrderingComposer,
      $$ConversationsTableAnnotationComposer,
      $$ConversationsTableCreateCompanionBuilder,
      $$ConversationsTableUpdateCompanionBuilder,
      (
        ConversationRow,
        BaseReferences<_$AppDatabase, $ConversationsTable, ConversationRow>,
      ),
      ConversationRow,
      PrefetchHooks Function()
    >;
typedef $$MembersTableCreateCompanionBuilder = MembersCompanion Function({
  required String convId,
  required String userId,
  Value<int> rowid,
});
typedef $$MembersTableUpdateCompanionBuilder = MembersCompanion Function({
  Value<String> convId,
  Value<String> userId,
  Value<int> rowid,
});

class $$MembersTableFilterComposer
    extends Composer<_$AppDatabase, $MembersTable> {
  $$MembersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MembersTableOrderingComposer
    extends Composer<_$AppDatabase, $MembersTable> {
  $$MembersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MembersTableAnnotationComposer
    extends Composer<_$AppDatabase, $MembersTable> {
  $$MembersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get convId =>
      $composableBuilder(column: $table.convId, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);
}

class $$MembersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MembersTable,
          Member,
          $$MembersTableFilterComposer,
          $$MembersTableOrderingComposer,
          $$MembersTableAnnotationComposer,
          $$MembersTableCreateCompanionBuilder,
          $$MembersTableUpdateCompanionBuilder,
          (Member, BaseReferences<_$AppDatabase, $MembersTable, Member>),
          Member,
          PrefetchHooks Function()
        > {
  $$MembersTableTableManager(_$AppDatabase db, $MembersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MembersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MembersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MembersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> convId = const Value.absent(),
            Value<String> userId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => MembersCompanion(convId: convId, userId: userId, rowid: rowid),
          createCompanionCallback:
              ({
                required String convId,
                required String userId,
                Value<int> rowid = const Value.absent(),
              }) => MembersCompanion.insert(
                convId: convId,
                userId: userId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MembersTable, Member>(table),
                  BaseReferences<_$AppDatabase, $MembersTable, Member>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MembersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MembersTable,
      Member,
      $$MembersTableFilterComposer,
      $$MembersTableOrderingComposer,
      $$MembersTableAnnotationComposer,
      $$MembersTableCreateCompanionBuilder,
      $$MembersTableUpdateCompanionBuilder,
      (Member, BaseReferences<_$AppDatabase, $MembersTable, Member>),
      Member,
      PrefetchHooks Function()
    >;
typedef $$MessagesTableCreateCompanionBuilder = MessagesCompanion Function({
  required String id,
  required String convId,
  Value<int?> seq,
  required String sender,
  required int ts,
  required String envelope,
  required DeliveryState state,
  Value<String?> attachmentPath,
  Value<String?> thumbnailPath,
  Value<String?> wire,
  Value<String?> contentKey,
  Value<bool> keyBackedUp,
  Value<bool> isSystem,
  Value<String?> kind,
  Value<String?> target,
  Value<int> rowid,
});
typedef $$MessagesTableUpdateCompanionBuilder = MessagesCompanion Function({
  Value<String> id,
  Value<String> convId,
  Value<int?> seq,
  Value<String> sender,
  Value<int> ts,
  Value<String> envelope,
  Value<DeliveryState> state,
  Value<String?> attachmentPath,
  Value<String?> thumbnailPath,
  Value<String?> wire,
  Value<String?> contentKey,
  Value<bool> keyBackedUp,
  Value<bool> isSystem,
  Value<String?> kind,
  Value<String?> target,
  Value<int> rowid,
});

class $$MessagesTableFilterComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sender => $composableBuilder(
    column: $table.sender,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ts => $composableBuilder(
    column: $table.ts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get envelope => $composableBuilder(
    column: $table.envelope,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<DeliveryState, DeliveryState, int> get state =>
      $composableBuilder(
        column: $table.state,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get attachmentPath => $composableBuilder(
    column: $table.attachmentPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbnailPath => $composableBuilder(
    column: $table.thumbnailPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get wire => $composableBuilder(
    column: $table.wire,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get keyBackedUp => $composableBuilder(
    column: $table.keyBackedUp,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isSystem => $composableBuilder(
    column: $table.isSystem,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get target => $composableBuilder(
    column: $table.target,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sender => $composableBuilder(
    column: $table.sender,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ts => $composableBuilder(
    column: $table.ts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get envelope => $composableBuilder(
    column: $table.envelope,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attachmentPath => $composableBuilder(
    column: $table.attachmentPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbnailPath => $composableBuilder(
    column: $table.thumbnailPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get wire => $composableBuilder(
    column: $table.wire,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get keyBackedUp => $composableBuilder(
    column: $table.keyBackedUp,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isSystem => $composableBuilder(
    column: $table.isSystem,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get target => $composableBuilder(
    column: $table.target,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get convId =>
      $composableBuilder(column: $table.convId, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get sender =>
      $composableBuilder(column: $table.sender, builder: (column) => column);

  GeneratedColumn<int> get ts =>
      $composableBuilder(column: $table.ts, builder: (column) => column);

  GeneratedColumn<String> get envelope =>
      $composableBuilder(column: $table.envelope, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DeliveryState, int> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get attachmentPath => $composableBuilder(
    column: $table.attachmentPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get thumbnailPath => $composableBuilder(
    column: $table.thumbnailPath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get wire =>
      $composableBuilder(column: $table.wire, builder: (column) => column);

  GeneratedColumn<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get keyBackedUp => $composableBuilder(
    column: $table.keyBackedUp,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isSystem =>
      $composableBuilder(column: $table.isSystem, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get target =>
      $composableBuilder(column: $table.target, builder: (column) => column);
}

class $$MessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessagesTable,
          Message,
          $$MessagesTableFilterComposer,
          $$MessagesTableOrderingComposer,
          $$MessagesTableAnnotationComposer,
          $$MessagesTableCreateCompanionBuilder,
          $$MessagesTableUpdateCompanionBuilder,
          (Message, BaseReferences<_$AppDatabase, $MessagesTable, Message>),
          Message,
          PrefetchHooks Function()
        > {
  $$MessagesTableTableManager(_$AppDatabase db, $MessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> convId = const Value.absent(),
                Value<int?> seq = const Value.absent(),
                Value<String> sender = const Value.absent(),
                Value<int> ts = const Value.absent(),
                Value<String> envelope = const Value.absent(),
                Value<DeliveryState> state = const Value.absent(),
                Value<String?> attachmentPath = const Value.absent(),
                Value<String?> thumbnailPath = const Value.absent(),
                Value<String?> wire = const Value.absent(),
                Value<String?> contentKey = const Value.absent(),
                Value<bool> keyBackedUp = const Value.absent(),
                Value<bool> isSystem = const Value.absent(),
                Value<String?> kind = const Value.absent(),
                Value<String?> target = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion(
                id: id,
                convId: convId,
                seq: seq,
                sender: sender,
                ts: ts,
                envelope: envelope,
                state: state,
                attachmentPath: attachmentPath,
                thumbnailPath: thumbnailPath,
                wire: wire,
                contentKey: contentKey,
                keyBackedUp: keyBackedUp,
                isSystem: isSystem,
                kind: kind,
                target: target,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String convId,
                Value<int?> seq = const Value.absent(),
                required String sender,
                required int ts,
                required String envelope,
                required DeliveryState state,
                Value<String?> attachmentPath = const Value.absent(),
                Value<String?> thumbnailPath = const Value.absent(),
                Value<String?> wire = const Value.absent(),
                Value<String?> contentKey = const Value.absent(),
                Value<bool> keyBackedUp = const Value.absent(),
                Value<bool> isSystem = const Value.absent(),
                Value<String?> kind = const Value.absent(),
                Value<String?> target = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion.insert(
                id: id,
                convId: convId,
                seq: seq,
                sender: sender,
                ts: ts,
                envelope: envelope,
                state: state,
                attachmentPath: attachmentPath,
                thumbnailPath: thumbnailPath,
                wire: wire,
                contentKey: contentKey,
                keyBackedUp: keyBackedUp,
                isSystem: isSystem,
                kind: kind,
                target: target,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessagesTable, Message>(table),
                  BaseReferences<_$AppDatabase, $MessagesTable, Message>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessagesTable,
      Message,
      $$MessagesTableFilterComposer,
      $$MessagesTableOrderingComposer,
      $$MessagesTableAnnotationComposer,
      $$MessagesTableCreateCompanionBuilder,
      $$MessagesTableUpdateCompanionBuilder,
      (Message, BaseReferences<_$AppDatabase, $MessagesTable, Message>),
      Message,
      PrefetchHooks Function()
    >;
typedef $$PinnedIdentitiesTableCreateCompanionBuilder =
    PinnedIdentitiesCompanion Function({
      required String userId,
      required String identityKey,
      Value<String?> changedTo,
      Value<String?> verifiedKey,
      Value<int?> verifiedAt,
      Value<int> rowid,
    });
typedef $$PinnedIdentitiesTableUpdateCompanionBuilder =
    PinnedIdentitiesCompanion Function({
      Value<String> userId,
      Value<String> identityKey,
      Value<String?> changedTo,
      Value<String?> verifiedKey,
      Value<int?> verifiedAt,
      Value<int> rowid,
    });

class $$PinnedIdentitiesTableFilterComposer
    extends Composer<_$AppDatabase, $PinnedIdentitiesTable> {
  $$PinnedIdentitiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get identityKey => $composableBuilder(
    column: $table.identityKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get changedTo => $composableBuilder(
    column: $table.changedTo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get verifiedKey => $composableBuilder(
    column: $table.verifiedKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get verifiedAt => $composableBuilder(
    column: $table.verifiedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PinnedIdentitiesTableOrderingComposer
    extends Composer<_$AppDatabase, $PinnedIdentitiesTable> {
  $$PinnedIdentitiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get identityKey => $composableBuilder(
    column: $table.identityKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get changedTo => $composableBuilder(
    column: $table.changedTo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get verifiedKey => $composableBuilder(
    column: $table.verifiedKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get verifiedAt => $composableBuilder(
    column: $table.verifiedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PinnedIdentitiesTableAnnotationComposer
    extends Composer<_$AppDatabase, $PinnedIdentitiesTable> {
  $$PinnedIdentitiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get identityKey => $composableBuilder(
    column: $table.identityKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get changedTo =>
      $composableBuilder(column: $table.changedTo, builder: (column) => column);

  GeneratedColumn<String> get verifiedKey => $composableBuilder(
    column: $table.verifiedKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get verifiedAt => $composableBuilder(
    column: $table.verifiedAt,
    builder: (column) => column,
  );
}

class $$PinnedIdentitiesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PinnedIdentitiesTable,
          PinnedIdentity,
          $$PinnedIdentitiesTableFilterComposer,
          $$PinnedIdentitiesTableOrderingComposer,
          $$PinnedIdentitiesTableAnnotationComposer,
          $$PinnedIdentitiesTableCreateCompanionBuilder,
          $$PinnedIdentitiesTableUpdateCompanionBuilder,
          (
            PinnedIdentity,
            BaseReferences<
              _$AppDatabase,
              $PinnedIdentitiesTable,
              PinnedIdentity
            >,
          ),
          PinnedIdentity,
          PrefetchHooks Function()
        > {
  $$PinnedIdentitiesTableTableManager(
    _$AppDatabase db,
    $PinnedIdentitiesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PinnedIdentitiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PinnedIdentitiesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PinnedIdentitiesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> userId = const Value.absent(),
                Value<String> identityKey = const Value.absent(),
                Value<String?> changedTo = const Value.absent(),
                Value<String?> verifiedKey = const Value.absent(),
                Value<int?> verifiedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PinnedIdentitiesCompanion(
                userId: userId,
                identityKey: identityKey,
                changedTo: changedTo,
                verifiedKey: verifiedKey,
                verifiedAt: verifiedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String userId,
                required String identityKey,
                Value<String?> changedTo = const Value.absent(),
                Value<String?> verifiedKey = const Value.absent(),
                Value<int?> verifiedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PinnedIdentitiesCompanion.insert(
                userId: userId,
                identityKey: identityKey,
                changedTo: changedTo,
                verifiedKey: verifiedKey,
                verifiedAt: verifiedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PinnedIdentitiesTable, PinnedIdentity>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $PinnedIdentitiesTable,
                    PinnedIdentity
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PinnedIdentitiesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PinnedIdentitiesTable,
      PinnedIdentity,
      $$PinnedIdentitiesTableFilterComposer,
      $$PinnedIdentitiesTableOrderingComposer,
      $$PinnedIdentitiesTableAnnotationComposer,
      $$PinnedIdentitiesTableCreateCompanionBuilder,
      $$PinnedIdentitiesTableUpdateCompanionBuilder,
      (
        PinnedIdentity,
        BaseReferences<_$AppDatabase, $PinnedIdentitiesTable, PinnedIdentity>,
      ),
      PinnedIdentity,
      PrefetchHooks Function()
    >;
typedef $$GroupUsersTableCreateCompanionBuilder = GroupUsersCompanion Function({
  required String convId,
  required String userId,
  Value<int> rowid,
});
typedef $$GroupUsersTableUpdateCompanionBuilder = GroupUsersCompanion Function({
  Value<String> convId,
  Value<String> userId,
  Value<int> rowid,
});

class $$GroupUsersTableFilterComposer
    extends Composer<_$AppDatabase, $GroupUsersTable> {
  $$GroupUsersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$GroupUsersTableOrderingComposer
    extends Composer<_$AppDatabase, $GroupUsersTable> {
  $$GroupUsersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GroupUsersTableAnnotationComposer
    extends Composer<_$AppDatabase, $GroupUsersTable> {
  $$GroupUsersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get convId =>
      $composableBuilder(column: $table.convId, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);
}

class $$GroupUsersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GroupUsersTable,
          GroupUser,
          $$GroupUsersTableFilterComposer,
          $$GroupUsersTableOrderingComposer,
          $$GroupUsersTableAnnotationComposer,
          $$GroupUsersTableCreateCompanionBuilder,
          $$GroupUsersTableUpdateCompanionBuilder,
          (
            GroupUser,
            BaseReferences<_$AppDatabase, $GroupUsersTable, GroupUser>,
          ),
          GroupUser,
          PrefetchHooks Function()
        > {
  $$GroupUsersTableTableManager(_$AppDatabase db, $GroupUsersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupUsersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupUsersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupUsersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> convId = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupUsersCompanion(
                convId: convId,
                userId: userId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String convId,
                required String userId,
                Value<int> rowid = const Value.absent(),
              }) => GroupUsersCompanion.insert(
                convId: convId,
                userId: userId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$GroupUsersTable, GroupUser>(table),
                  BaseReferences<_$AppDatabase, $GroupUsersTable, GroupUser>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$GroupUsersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GroupUsersTable,
      GroupUser,
      $$GroupUsersTableFilterComposer,
      $$GroupUsersTableOrderingComposer,
      $$GroupUsersTableAnnotationComposer,
      $$GroupUsersTableCreateCompanionBuilder,
      $$GroupUsersTableUpdateCompanionBuilder,
      (GroupUser, BaseReferences<_$AppDatabase, $GroupUsersTable, GroupUser>),
      GroupUser,
      PrefetchHooks Function()
    >;
typedef $$SuspiciousLeavesTableCreateCompanionBuilder =
    SuspiciousLeavesCompanion Function({
      required String convId,
      required String signatureKey,
      Value<int> rowid,
    });
typedef $$SuspiciousLeavesTableUpdateCompanionBuilder =
    SuspiciousLeavesCompanion Function({
      Value<String> convId,
      Value<String> signatureKey,
      Value<int> rowid,
    });

class $$SuspiciousLeavesTableFilterComposer
    extends Composer<_$AppDatabase, $SuspiciousLeavesTable> {
  $$SuspiciousLeavesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get signatureKey => $composableBuilder(
    column: $table.signatureKey,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SuspiciousLeavesTableOrderingComposer
    extends Composer<_$AppDatabase, $SuspiciousLeavesTable> {
  $$SuspiciousLeavesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get signatureKey => $composableBuilder(
    column: $table.signatureKey,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SuspiciousLeavesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SuspiciousLeavesTable> {
  $$SuspiciousLeavesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get convId =>
      $composableBuilder(column: $table.convId, builder: (column) => column);

  GeneratedColumn<String> get signatureKey => $composableBuilder(
    column: $table.signatureKey,
    builder: (column) => column,
  );
}

class $$SuspiciousLeavesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SuspiciousLeavesTable,
          SuspiciousLeave,
          $$SuspiciousLeavesTableFilterComposer,
          $$SuspiciousLeavesTableOrderingComposer,
          $$SuspiciousLeavesTableAnnotationComposer,
          $$SuspiciousLeavesTableCreateCompanionBuilder,
          $$SuspiciousLeavesTableUpdateCompanionBuilder,
          (
            SuspiciousLeave,
            BaseReferences<
              _$AppDatabase,
              $SuspiciousLeavesTable,
              SuspiciousLeave
            >,
          ),
          SuspiciousLeave,
          PrefetchHooks Function()
        > {
  $$SuspiciousLeavesTableTableManager(
    _$AppDatabase db,
    $SuspiciousLeavesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SuspiciousLeavesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SuspiciousLeavesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SuspiciousLeavesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> convId = const Value.absent(),
                Value<String> signatureKey = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SuspiciousLeavesCompanion(
                convId: convId,
                signatureKey: signatureKey,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String convId,
                required String signatureKey,
                Value<int> rowid = const Value.absent(),
              }) => SuspiciousLeavesCompanion.insert(
                convId: convId,
                signatureKey: signatureKey,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SuspiciousLeavesTable, SuspiciousLeave>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SuspiciousLeavesTable,
                    SuspiciousLeave
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SuspiciousLeavesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SuspiciousLeavesTable,
      SuspiciousLeave,
      $$SuspiciousLeavesTableFilterComposer,
      $$SuspiciousLeavesTableOrderingComposer,
      $$SuspiciousLeavesTableAnnotationComposer,
      $$SuspiciousLeavesTableCreateCompanionBuilder,
      $$SuspiciousLeavesTableUpdateCompanionBuilder,
      (
        SuspiciousLeave,
        BaseReferences<_$AppDatabase, $SuspiciousLeavesTable, SuspiciousLeave>,
      ),
      SuspiciousLeave,
      PrefetchHooks Function()
    >;
typedef $$KeyRotationsTableCreateCompanionBuilder =
    KeyRotationsCompanion Function({
      required String convId,
      required int rotatedAt,
      Value<int> sentSince,
      Value<int> rowid,
    });
typedef $$KeyRotationsTableUpdateCompanionBuilder =
    KeyRotationsCompanion Function({
      Value<String> convId,
      Value<int> rotatedAt,
      Value<int> sentSince,
      Value<int> rowid,
    });

class $$KeyRotationsTableFilterComposer
    extends Composer<_$AppDatabase, $KeyRotationsTable> {
  $$KeyRotationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get rotatedAt => $composableBuilder(
    column: $table.rotatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sentSince => $composableBuilder(
    column: $table.sentSince,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KeyRotationsTableOrderingComposer
    extends Composer<_$AppDatabase, $KeyRotationsTable> {
  $$KeyRotationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get rotatedAt => $composableBuilder(
    column: $table.rotatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sentSince => $composableBuilder(
    column: $table.sentSince,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KeyRotationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $KeyRotationsTable> {
  $$KeyRotationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get convId =>
      $composableBuilder(column: $table.convId, builder: (column) => column);

  GeneratedColumn<int> get rotatedAt =>
      $composableBuilder(column: $table.rotatedAt, builder: (column) => column);

  GeneratedColumn<int> get sentSince =>
      $composableBuilder(column: $table.sentSince, builder: (column) => column);
}

class $$KeyRotationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KeyRotationsTable,
          KeyRotation,
          $$KeyRotationsTableFilterComposer,
          $$KeyRotationsTableOrderingComposer,
          $$KeyRotationsTableAnnotationComposer,
          $$KeyRotationsTableCreateCompanionBuilder,
          $$KeyRotationsTableUpdateCompanionBuilder,
          (
            KeyRotation,
            BaseReferences<_$AppDatabase, $KeyRotationsTable, KeyRotation>,
          ),
          KeyRotation,
          PrefetchHooks Function()
        > {
  $$KeyRotationsTableTableManager(_$AppDatabase db, $KeyRotationsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KeyRotationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KeyRotationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KeyRotationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> convId = const Value.absent(),
                Value<int> rotatedAt = const Value.absent(),
                Value<int> sentSince = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KeyRotationsCompanion(
                convId: convId,
                rotatedAt: rotatedAt,
                sentSince: sentSince,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String convId,
                required int rotatedAt,
                Value<int> sentSince = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KeyRotationsCompanion.insert(
                convId: convId,
                rotatedAt: rotatedAt,
                sentSince: sentSince,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KeyRotationsTable, KeyRotation>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $KeyRotationsTable,
                    KeyRotation
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KeyRotationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KeyRotationsTable,
      KeyRotation,
      $$KeyRotationsTableFilterComposer,
      $$KeyRotationsTableOrderingComposer,
      $$KeyRotationsTableAnnotationComposer,
      $$KeyRotationsTableCreateCompanionBuilder,
      $$KeyRotationsTableUpdateCompanionBuilder,
      (
        KeyRotation,
        BaseReferences<_$AppDatabase, $KeyRotationsTable, KeyRotation>,
      ),
      KeyRotation,
      PrefetchHooks Function()
    >;
typedef $$SharedKeysTableCreateCompanionBuilder = SharedKeysCompanion Function({
  required String shareId,
  required String convId,
  required String messageId,
  required String contentKey,
  Value<int> rowid,
});
typedef $$SharedKeysTableUpdateCompanionBuilder = SharedKeysCompanion Function({
  Value<String> shareId,
  Value<String> convId,
  Value<String> messageId,
  Value<String> contentKey,
  Value<int> rowid,
});

class $$SharedKeysTableFilterComposer
    extends Composer<_$AppDatabase, $SharedKeysTable> {
  $$SharedKeysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get shareId => $composableBuilder(
    column: $table.shareId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SharedKeysTableOrderingComposer
    extends Composer<_$AppDatabase, $SharedKeysTable> {
  $$SharedKeysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get shareId => $composableBuilder(
    column: $table.shareId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SharedKeysTableAnnotationComposer
    extends Composer<_$AppDatabase, $SharedKeysTable> {
  $$SharedKeysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get shareId =>
      $composableBuilder(column: $table.shareId, builder: (column) => column);

  GeneratedColumn<String> get convId =>
      $composableBuilder(column: $table.convId, builder: (column) => column);

  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => column,
  );
}

class $$SharedKeysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SharedKeysTable,
          SharedKey,
          $$SharedKeysTableFilterComposer,
          $$SharedKeysTableOrderingComposer,
          $$SharedKeysTableAnnotationComposer,
          $$SharedKeysTableCreateCompanionBuilder,
          $$SharedKeysTableUpdateCompanionBuilder,
          (
            SharedKey,
            BaseReferences<_$AppDatabase, $SharedKeysTable, SharedKey>,
          ),
          SharedKey,
          PrefetchHooks Function()
        > {
  $$SharedKeysTableTableManager(_$AppDatabase db, $SharedKeysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SharedKeysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SharedKeysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SharedKeysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> shareId = const Value.absent(),
                Value<String> convId = const Value.absent(),
                Value<String> messageId = const Value.absent(),
                Value<String> contentKey = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SharedKeysCompanion(
                shareId: shareId,
                convId: convId,
                messageId: messageId,
                contentKey: contentKey,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String shareId,
                required String convId,
                required String messageId,
                required String contentKey,
                Value<int> rowid = const Value.absent(),
              }) => SharedKeysCompanion.insert(
                shareId: shareId,
                convId: convId,
                messageId: messageId,
                contentKey: contentKey,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SharedKeysTable, SharedKey>(table),
                  BaseReferences<_$AppDatabase, $SharedKeysTable, SharedKey>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SharedKeysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SharedKeysTable,
      SharedKey,
      $$SharedKeysTableFilterComposer,
      $$SharedKeysTableOrderingComposer,
      $$SharedKeysTableAnnotationComposer,
      $$SharedKeysTableCreateCompanionBuilder,
      $$SharedKeysTableUpdateCompanionBuilder,
      (SharedKey, BaseReferences<_$AppDatabase, $SharedKeysTable, SharedKey>),
      SharedKey,
      PrefetchHooks Function()
    >;
typedef $$GroupStatesTableCreateCompanionBuilder =
    GroupStatesCompanion Function({
      required String convId,
      Value<String?> hash,
      Value<String?> document,
      Value<String> roster,
      Value<bool> verified,
      Value<int> rowid,
    });
typedef $$GroupStatesTableUpdateCompanionBuilder =
    GroupStatesCompanion Function({
      Value<String> convId,
      Value<String?> hash,
      Value<String?> document,
      Value<String> roster,
      Value<bool> verified,
      Value<int> rowid,
    });

class $$GroupStatesTableFilterComposer
    extends Composer<_$AppDatabase, $GroupStatesTable> {
  $$GroupStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hash => $composableBuilder(
    column: $table.hash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get document => $composableBuilder(
    column: $table.document,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roster => $composableBuilder(
    column: $table.roster,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get verified => $composableBuilder(
    column: $table.verified,
    builder: (column) => ColumnFilters(column),
  );
}

class $$GroupStatesTableOrderingComposer
    extends Composer<_$AppDatabase, $GroupStatesTable> {
  $$GroupStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hash => $composableBuilder(
    column: $table.hash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get document => $composableBuilder(
    column: $table.document,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roster => $composableBuilder(
    column: $table.roster,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get verified => $composableBuilder(
    column: $table.verified,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GroupStatesTableAnnotationComposer
    extends Composer<_$AppDatabase, $GroupStatesTable> {
  $$GroupStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get convId =>
      $composableBuilder(column: $table.convId, builder: (column) => column);

  GeneratedColumn<String> get hash =>
      $composableBuilder(column: $table.hash, builder: (column) => column);

  GeneratedColumn<String> get document =>
      $composableBuilder(column: $table.document, builder: (column) => column);

  GeneratedColumn<String> get roster =>
      $composableBuilder(column: $table.roster, builder: (column) => column);

  GeneratedColumn<bool> get verified =>
      $composableBuilder(column: $table.verified, builder: (column) => column);
}

class $$GroupStatesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GroupStatesTable,
          GroupStateRow,
          $$GroupStatesTableFilterComposer,
          $$GroupStatesTableOrderingComposer,
          $$GroupStatesTableAnnotationComposer,
          $$GroupStatesTableCreateCompanionBuilder,
          $$GroupStatesTableUpdateCompanionBuilder,
          (
            GroupStateRow,
            BaseReferences<_$AppDatabase, $GroupStatesTable, GroupStateRow>,
          ),
          GroupStateRow,
          PrefetchHooks Function()
        > {
  $$GroupStatesTableTableManager(_$AppDatabase db, $GroupStatesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> convId = const Value.absent(),
                Value<String?> hash = const Value.absent(),
                Value<String?> document = const Value.absent(),
                Value<String> roster = const Value.absent(),
                Value<bool> verified = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupStatesCompanion(
                convId: convId,
                hash: hash,
                document: document,
                roster: roster,
                verified: verified,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String convId,
                Value<String?> hash = const Value.absent(),
                Value<String?> document = const Value.absent(),
                Value<String> roster = const Value.absent(),
                Value<bool> verified = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupStatesCompanion.insert(
                convId: convId,
                hash: hash,
                document: document,
                roster: roster,
                verified: verified,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$GroupStatesTable, GroupStateRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $GroupStatesTable,
                    GroupStateRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$GroupStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GroupStatesTable,
      GroupStateRow,
      $$GroupStatesTableFilterComposer,
      $$GroupStatesTableOrderingComposer,
      $$GroupStatesTableAnnotationComposer,
      $$GroupStatesTableCreateCompanionBuilder,
      $$GroupStatesTableUpdateCompanionBuilder,
      (
        GroupStateRow,
        BaseReferences<_$AppDatabase, $GroupStatesTable, GroupStateRow>,
      ),
      GroupStateRow,
      PrefetchHooks Function()
    >;
typedef $$ContactsTableCreateCompanionBuilder = ContactsCompanion Function({
  required String userId,
  required ContactState state,
  Value<int> since,
  Value<bool> trusted,
  Value<int> rowid,
});
typedef $$ContactsTableUpdateCompanionBuilder = ContactsCompanion Function({
  Value<String> userId,
  Value<ContactState> state,
  Value<int> since,
  Value<bool> trusted,
  Value<int> rowid,
});

class $$ContactsTableFilterComposer
    extends Composer<_$AppDatabase, $ContactsTable> {
  $$ContactsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<ContactState, ContactState, String>
  get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<int> get since => $composableBuilder(
    column: $table.since,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get trusted => $composableBuilder(
    column: $table.trusted,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ContactsTableOrderingComposer
    extends Composer<_$AppDatabase, $ContactsTable> {
  $$ContactsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get since => $composableBuilder(
    column: $table.since,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get trusted => $composableBuilder(
    column: $table.trusted,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ContactsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ContactsTable> {
  $$ContactsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumnWithTypeConverter<ContactState, String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get since =>
      $composableBuilder(column: $table.since, builder: (column) => column);

  GeneratedColumn<bool> get trusted =>
      $composableBuilder(column: $table.trusted, builder: (column) => column);
}

class $$ContactsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ContactsTable,
          ContactRow,
          $$ContactsTableFilterComposer,
          $$ContactsTableOrderingComposer,
          $$ContactsTableAnnotationComposer,
          $$ContactsTableCreateCompanionBuilder,
          $$ContactsTableUpdateCompanionBuilder,
          (
            ContactRow,
            BaseReferences<_$AppDatabase, $ContactsTable, ContactRow>,
          ),
          ContactRow,
          PrefetchHooks Function()
        > {
  $$ContactsTableTableManager(_$AppDatabase db, $ContactsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ContactsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ContactsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ContactsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> userId = const Value.absent(),
                Value<ContactState> state = const Value.absent(),
                Value<int> since = const Value.absent(),
                Value<bool> trusted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ContactsCompanion(
                userId: userId,
                state: state,
                since: since,
                trusted: trusted,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String userId,
                required ContactState state,
                Value<int> since = const Value.absent(),
                Value<bool> trusted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ContactsCompanion.insert(
                userId: userId,
                state: state,
                since: since,
                trusted: trusted,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ContactsTable, ContactRow>(table),
                  BaseReferences<_$AppDatabase, $ContactsTable, ContactRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ContactsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ContactsTable,
      ContactRow,
      $$ContactsTableFilterComposer,
      $$ContactsTableOrderingComposer,
      $$ContactsTableAnnotationComposer,
      $$ContactsTableCreateCompanionBuilder,
      $$ContactsTableUpdateCompanionBuilder,
      (ContactRow, BaseReferences<_$AppDatabase, $ContactsTable, ContactRow>),
      ContactRow,
      PrefetchHooks Function()
    >;
typedef $$RefusedConversationsTableCreateCompanionBuilder =
    RefusedConversationsCompanion Function({
      required String convId,
      Value<int> rowid,
    });
typedef $$RefusedConversationsTableUpdateCompanionBuilder =
    RefusedConversationsCompanion Function({
      Value<String> convId,
      Value<int> rowid,
    });

class $$RefusedConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $RefusedConversationsTable> {
  $$RefusedConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RefusedConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $RefusedConversationsTable> {
  $$RefusedConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RefusedConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $RefusedConversationsTable> {
  $$RefusedConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get convId =>
      $composableBuilder(column: $table.convId, builder: (column) => column);
}

class $$RefusedConversationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RefusedConversationsTable,
          RefusedConversation,
          $$RefusedConversationsTableFilterComposer,
          $$RefusedConversationsTableOrderingComposer,
          $$RefusedConversationsTableAnnotationComposer,
          $$RefusedConversationsTableCreateCompanionBuilder,
          $$RefusedConversationsTableUpdateCompanionBuilder,
          (
            RefusedConversation,
            BaseReferences<
              _$AppDatabase,
              $RefusedConversationsTable,
              RefusedConversation
            >,
          ),
          RefusedConversation,
          PrefetchHooks Function()
        > {
  $$RefusedConversationsTableTableManager(
    _$AppDatabase db,
    $RefusedConversationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RefusedConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RefusedConversationsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$RefusedConversationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback: ({
            Value<String> convId = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => RefusedConversationsCompanion(convId: convId, rowid: rowid),
          createCompanionCallback:
              ({
                required String convId,
                Value<int> rowid = const Value.absent(),
              }) => RefusedConversationsCompanion.insert(
                convId: convId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RefusedConversationsTable, RefusedConversation>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $RefusedConversationsTable,
                    RefusedConversation
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RefusedConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RefusedConversationsTable,
      RefusedConversation,
      $$RefusedConversationsTableFilterComposer,
      $$RefusedConversationsTableOrderingComposer,
      $$RefusedConversationsTableAnnotationComposer,
      $$RefusedConversationsTableCreateCompanionBuilder,
      $$RefusedConversationsTableUpdateCompanionBuilder,
      (
        RefusedConversation,
        BaseReferences<
          _$AppDatabase,
          $RefusedConversationsTable,
          RefusedConversation
        >,
      ),
      RefusedConversation,
      PrefetchHooks Function()
    >;
typedef $$UnsettledCommitsTableCreateCompanionBuilder =
    UnsettledCommitsCompanion Function({
      required String convId,
      required int epoch,
      Value<bool> creating,
      Value<String?> document,
      Value<String?> roster,
      Value<bool> changesDocument,
      Value<String> users,
      Value<String?> request,
      Value<int> rowid,
    });
typedef $$UnsettledCommitsTableUpdateCompanionBuilder =
    UnsettledCommitsCompanion Function({
      Value<String> convId,
      Value<int> epoch,
      Value<bool> creating,
      Value<String?> document,
      Value<String?> roster,
      Value<bool> changesDocument,
      Value<String> users,
      Value<String?> request,
      Value<int> rowid,
    });

class $$UnsettledCommitsTableFilterComposer
    extends Composer<_$AppDatabase, $UnsettledCommitsTable> {
  $$UnsettledCommitsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get creating => $composableBuilder(
    column: $table.creating,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get document => $composableBuilder(
    column: $table.document,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get roster => $composableBuilder(
    column: $table.roster,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get changesDocument => $composableBuilder(
    column: $table.changesDocument,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get users => $composableBuilder(
    column: $table.users,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get request => $composableBuilder(
    column: $table.request,
    builder: (column) => ColumnFilters(column),
  );
}

class $$UnsettledCommitsTableOrderingComposer
    extends Composer<_$AppDatabase, $UnsettledCommitsTable> {
  $$UnsettledCommitsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get convId => $composableBuilder(
    column: $table.convId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get creating => $composableBuilder(
    column: $table.creating,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get document => $composableBuilder(
    column: $table.document,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get roster => $composableBuilder(
    column: $table.roster,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get changesDocument => $composableBuilder(
    column: $table.changesDocument,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get users => $composableBuilder(
    column: $table.users,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get request => $composableBuilder(
    column: $table.request,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$UnsettledCommitsTableAnnotationComposer
    extends Composer<_$AppDatabase, $UnsettledCommitsTable> {
  $$UnsettledCommitsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get convId =>
      $composableBuilder(column: $table.convId, builder: (column) => column);

  GeneratedColumn<int> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<bool> get creating =>
      $composableBuilder(column: $table.creating, builder: (column) => column);

  GeneratedColumn<String> get document =>
      $composableBuilder(column: $table.document, builder: (column) => column);

  GeneratedColumn<String> get roster =>
      $composableBuilder(column: $table.roster, builder: (column) => column);

  GeneratedColumn<bool> get changesDocument => $composableBuilder(
    column: $table.changesDocument,
    builder: (column) => column,
  );

  GeneratedColumn<String> get users =>
      $composableBuilder(column: $table.users, builder: (column) => column);

  GeneratedColumn<String> get request =>
      $composableBuilder(column: $table.request, builder: (column) => column);
}

class $$UnsettledCommitsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $UnsettledCommitsTable,
          UnsettledCommitRow,
          $$UnsettledCommitsTableFilterComposer,
          $$UnsettledCommitsTableOrderingComposer,
          $$UnsettledCommitsTableAnnotationComposer,
          $$UnsettledCommitsTableCreateCompanionBuilder,
          $$UnsettledCommitsTableUpdateCompanionBuilder,
          (
            UnsettledCommitRow,
            BaseReferences<
              _$AppDatabase,
              $UnsettledCommitsTable,
              UnsettledCommitRow
            >,
          ),
          UnsettledCommitRow,
          PrefetchHooks Function()
        > {
  $$UnsettledCommitsTableTableManager(
    _$AppDatabase db,
    $UnsettledCommitsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$UnsettledCommitsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$UnsettledCommitsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$UnsettledCommitsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> convId = const Value.absent(),
                Value<int> epoch = const Value.absent(),
                Value<bool> creating = const Value.absent(),
                Value<String?> document = const Value.absent(),
                Value<String?> roster = const Value.absent(),
                Value<bool> changesDocument = const Value.absent(),
                Value<String> users = const Value.absent(),
                Value<String?> request = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => UnsettledCommitsCompanion(
                convId: convId,
                epoch: epoch,
                creating: creating,
                document: document,
                roster: roster,
                changesDocument: changesDocument,
                users: users,
                request: request,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String convId,
                required int epoch,
                Value<bool> creating = const Value.absent(),
                Value<String?> document = const Value.absent(),
                Value<String?> roster = const Value.absent(),
                Value<bool> changesDocument = const Value.absent(),
                Value<String> users = const Value.absent(),
                Value<String?> request = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => UnsettledCommitsCompanion.insert(
                convId: convId,
                epoch: epoch,
                creating: creating,
                document: document,
                roster: roster,
                changesDocument: changesDocument,
                users: users,
                request: request,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$UnsettledCommitsTable, UnsettledCommitRow>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $UnsettledCommitsTable,
                    UnsettledCommitRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$UnsettledCommitsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $UnsettledCommitsTable,
      UnsettledCommitRow,
      $$UnsettledCommitsTableFilterComposer,
      $$UnsettledCommitsTableOrderingComposer,
      $$UnsettledCommitsTableAnnotationComposer,
      $$UnsettledCommitsTableCreateCompanionBuilder,
      $$UnsettledCommitsTableUpdateCompanionBuilder,
      (
        UnsettledCommitRow,
        BaseReferences<
          _$AppDatabase,
          $UnsettledCommitsTable,
          UnsettledCommitRow
        >,
      ),
      UnsettledCommitRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$KeyValuesTableTableManager get keyValues =>
      $$KeyValuesTableTableManager(_db, _db.keyValues);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db, _db.profiles);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$MembersTableTableManager get members =>
      $$MembersTableTableManager(_db, _db.members);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$PinnedIdentitiesTableTableManager get pinnedIdentities =>
      $$PinnedIdentitiesTableTableManager(_db, _db.pinnedIdentities);
  $$GroupUsersTableTableManager get groupUsers =>
      $$GroupUsersTableTableManager(_db, _db.groupUsers);
  $$SuspiciousLeavesTableTableManager get suspiciousLeaves =>
      $$SuspiciousLeavesTableTableManager(_db, _db.suspiciousLeaves);
  $$KeyRotationsTableTableManager get keyRotations =>
      $$KeyRotationsTableTableManager(_db, _db.keyRotations);
  $$SharedKeysTableTableManager get sharedKeys =>
      $$SharedKeysTableTableManager(_db, _db.sharedKeys);
  $$GroupStatesTableTableManager get groupStates =>
      $$GroupStatesTableTableManager(_db, _db.groupStates);
  $$ContactsTableTableManager get contacts =>
      $$ContactsTableTableManager(_db, _db.contacts);
  $$RefusedConversationsTableTableManager get refusedConversations =>
      $$RefusedConversationsTableTableManager(_db, _db.refusedConversations);
  $$UnsettledCommitsTableTableManager get unsettledCommits =>
      $$UnsettledCommitsTableTableManager(_db, _db.unsettledCommits);
}
