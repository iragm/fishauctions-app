// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'auth_models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

TokenPair _$TokenPairFromJson(Map<String, dynamic> json) {
  return _TokenPair.fromJson(json);
}

/// @nodoc
mixin _$TokenPair {
  String get access => throw _privateConstructorUsedError;
  String get refresh => throw _privateConstructorUsedError;

  /// Serializes this TokenPair to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of TokenPair
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $TokenPairCopyWith<TokenPair> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $TokenPairCopyWith<$Res> {
  factory $TokenPairCopyWith(TokenPair value, $Res Function(TokenPair) then) =
      _$TokenPairCopyWithImpl<$Res, TokenPair>;
  @useResult
  $Res call({String access, String refresh});
}

/// @nodoc
class _$TokenPairCopyWithImpl<$Res, $Val extends TokenPair>
    implements $TokenPairCopyWith<$Res> {
  _$TokenPairCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of TokenPair
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? access = null, Object? refresh = null}) {
    return _then(
      _value.copyWith(
            access: null == access
                ? _value.access
                : access // ignore: cast_nullable_to_non_nullable
                      as String,
            refresh: null == refresh
                ? _value.refresh
                : refresh // ignore: cast_nullable_to_non_nullable
                      as String,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$TokenPairImplCopyWith<$Res>
    implements $TokenPairCopyWith<$Res> {
  factory _$$TokenPairImplCopyWith(
    _$TokenPairImpl value,
    $Res Function(_$TokenPairImpl) then,
  ) = __$$TokenPairImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String access, String refresh});
}

/// @nodoc
class __$$TokenPairImplCopyWithImpl<$Res>
    extends _$TokenPairCopyWithImpl<$Res, _$TokenPairImpl>
    implements _$$TokenPairImplCopyWith<$Res> {
  __$$TokenPairImplCopyWithImpl(
    _$TokenPairImpl _value,
    $Res Function(_$TokenPairImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of TokenPair
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? access = null, Object? refresh = null}) {
    return _then(
      _$TokenPairImpl(
        access: null == access
            ? _value.access
            : access // ignore: cast_nullable_to_non_nullable
                  as String,
        refresh: null == refresh
            ? _value.refresh
            : refresh // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$TokenPairImpl implements _TokenPair {
  const _$TokenPairImpl({required this.access, required this.refresh});

  factory _$TokenPairImpl.fromJson(Map<String, dynamic> json) =>
      _$$TokenPairImplFromJson(json);

  @override
  final String access;
  @override
  final String refresh;

  @override
  String toString() {
    return 'TokenPair(access: $access, refresh: $refresh)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$TokenPairImpl &&
            (identical(other.access, access) || other.access == access) &&
            (identical(other.refresh, refresh) || other.refresh == refresh));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, access, refresh);

  /// Create a copy of TokenPair
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$TokenPairImplCopyWith<_$TokenPairImpl> get copyWith =>
      __$$TokenPairImplCopyWithImpl<_$TokenPairImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$TokenPairImplToJson(this);
  }
}

abstract class _TokenPair implements TokenPair {
  const factory _TokenPair({
    required final String access,
    required final String refresh,
  }) = _$TokenPairImpl;

  factory _TokenPair.fromJson(Map<String, dynamic> json) =
      _$TokenPairImpl.fromJson;

  @override
  String get access;
  @override
  String get refresh;

  /// Create a copy of TokenPair
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$TokenPairImplCopyWith<_$TokenPairImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

AppUser _$AppUserFromJson(Map<String, dynamic> json) {
  return _AppUser.fromJson(json);
}

/// @nodoc
mixin _$AppUser {
  int get id => throw _privateConstructorUsedError;
  String get username => throw _privateConstructorUsedError;
  String get email => throw _privateConstructorUsedError;
  @JsonKey(name: 'first_name')
  String get firstName => throw _privateConstructorUsedError;
  @JsonKey(name: 'last_name')
  String get lastName => throw _privateConstructorUsedError;
  @JsonKey(name: 'is_staff')
  bool get isStaff => throw _privateConstructorUsedError;
  @JsonKey(name: 'date_joined')
  DateTime? get dateJoined => throw _privateConstructorUsedError;

  /// Serializes this AppUser to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of AppUser
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $AppUserCopyWith<AppUser> get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $AppUserCopyWith<$Res> {
  factory $AppUserCopyWith(AppUser value, $Res Function(AppUser) then) =
      _$AppUserCopyWithImpl<$Res, AppUser>;
  @useResult
  $Res call({
    int id,
    String username,
    String email,
    @JsonKey(name: 'first_name') String firstName,
    @JsonKey(name: 'last_name') String lastName,
    @JsonKey(name: 'is_staff') bool isStaff,
    @JsonKey(name: 'date_joined') DateTime? dateJoined,
  });
}

/// @nodoc
class _$AppUserCopyWithImpl<$Res, $Val extends AppUser>
    implements $AppUserCopyWith<$Res> {
  _$AppUserCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of AppUser
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? username = null,
    Object? email = null,
    Object? firstName = null,
    Object? lastName = null,
    Object? isStaff = null,
    Object? dateJoined = freezed,
  }) {
    return _then(
      _value.copyWith(
            id: null == id
                ? _value.id
                : id // ignore: cast_nullable_to_non_nullable
                      as int,
            username: null == username
                ? _value.username
                : username // ignore: cast_nullable_to_non_nullable
                      as String,
            email: null == email
                ? _value.email
                : email // ignore: cast_nullable_to_non_nullable
                      as String,
            firstName: null == firstName
                ? _value.firstName
                : firstName // ignore: cast_nullable_to_non_nullable
                      as String,
            lastName: null == lastName
                ? _value.lastName
                : lastName // ignore: cast_nullable_to_non_nullable
                      as String,
            isStaff: null == isStaff
                ? _value.isStaff
                : isStaff // ignore: cast_nullable_to_non_nullable
                      as bool,
            dateJoined: freezed == dateJoined
                ? _value.dateJoined
                : dateJoined // ignore: cast_nullable_to_non_nullable
                      as DateTime?,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$AppUserImplCopyWith<$Res> implements $AppUserCopyWith<$Res> {
  factory _$$AppUserImplCopyWith(
    _$AppUserImpl value,
    $Res Function(_$AppUserImpl) then,
  ) = __$$AppUserImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    int id,
    String username,
    String email,
    @JsonKey(name: 'first_name') String firstName,
    @JsonKey(name: 'last_name') String lastName,
    @JsonKey(name: 'is_staff') bool isStaff,
    @JsonKey(name: 'date_joined') DateTime? dateJoined,
  });
}

/// @nodoc
class __$$AppUserImplCopyWithImpl<$Res>
    extends _$AppUserCopyWithImpl<$Res, _$AppUserImpl>
    implements _$$AppUserImplCopyWith<$Res> {
  __$$AppUserImplCopyWithImpl(
    _$AppUserImpl _value,
    $Res Function(_$AppUserImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of AppUser
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? id = null,
    Object? username = null,
    Object? email = null,
    Object? firstName = null,
    Object? lastName = null,
    Object? isStaff = null,
    Object? dateJoined = freezed,
  }) {
    return _then(
      _$AppUserImpl(
        id: null == id
            ? _value.id
            : id // ignore: cast_nullable_to_non_nullable
                  as int,
        username: null == username
            ? _value.username
            : username // ignore: cast_nullable_to_non_nullable
                  as String,
        email: null == email
            ? _value.email
            : email // ignore: cast_nullable_to_non_nullable
                  as String,
        firstName: null == firstName
            ? _value.firstName
            : firstName // ignore: cast_nullable_to_non_nullable
                  as String,
        lastName: null == lastName
            ? _value.lastName
            : lastName // ignore: cast_nullable_to_non_nullable
                  as String,
        isStaff: null == isStaff
            ? _value.isStaff
            : isStaff // ignore: cast_nullable_to_non_nullable
                  as bool,
        dateJoined: freezed == dateJoined
            ? _value.dateJoined
            : dateJoined // ignore: cast_nullable_to_non_nullable
                  as DateTime?,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$AppUserImpl implements _AppUser {
  const _$AppUserImpl({
    required this.id,
    required this.username,
    required this.email,
    @JsonKey(name: 'first_name') this.firstName = '',
    @JsonKey(name: 'last_name') this.lastName = '',
    @JsonKey(name: 'is_staff') this.isStaff = false,
    @JsonKey(name: 'date_joined') this.dateJoined,
  });

  factory _$AppUserImpl.fromJson(Map<String, dynamic> json) =>
      _$$AppUserImplFromJson(json);

  @override
  final int id;
  @override
  final String username;
  @override
  final String email;
  @override
  @JsonKey(name: 'first_name')
  final String firstName;
  @override
  @JsonKey(name: 'last_name')
  final String lastName;
  @override
  @JsonKey(name: 'is_staff')
  final bool isStaff;
  @override
  @JsonKey(name: 'date_joined')
  final DateTime? dateJoined;

  @override
  String toString() {
    return 'AppUser(id: $id, username: $username, email: $email, firstName: $firstName, lastName: $lastName, isStaff: $isStaff, dateJoined: $dateJoined)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$AppUserImpl &&
            (identical(other.id, id) || other.id == id) &&
            (identical(other.username, username) ||
                other.username == username) &&
            (identical(other.email, email) || other.email == email) &&
            (identical(other.firstName, firstName) ||
                other.firstName == firstName) &&
            (identical(other.lastName, lastName) ||
                other.lastName == lastName) &&
            (identical(other.isStaff, isStaff) || other.isStaff == isStaff) &&
            (identical(other.dateJoined, dateJoined) ||
                other.dateJoined == dateJoined));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    id,
    username,
    email,
    firstName,
    lastName,
    isStaff,
    dateJoined,
  );

  /// Create a copy of AppUser
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$AppUserImplCopyWith<_$AppUserImpl> get copyWith =>
      __$$AppUserImplCopyWithImpl<_$AppUserImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$AppUserImplToJson(this);
  }
}

abstract class _AppUser implements AppUser {
  const factory _AppUser({
    required final int id,
    required final String username,
    required final String email,
    @JsonKey(name: 'first_name') final String firstName,
    @JsonKey(name: 'last_name') final String lastName,
    @JsonKey(name: 'is_staff') final bool isStaff,
    @JsonKey(name: 'date_joined') final DateTime? dateJoined,
  }) = _$AppUserImpl;

  factory _AppUser.fromJson(Map<String, dynamic> json) = _$AppUserImpl.fromJson;

  @override
  int get id;
  @override
  String get username;
  @override
  String get email;
  @override
  @JsonKey(name: 'first_name')
  String get firstName;
  @override
  @JsonKey(name: 'last_name')
  String get lastName;
  @override
  @JsonKey(name: 'is_staff')
  bool get isStaff;
  @override
  @JsonKey(name: 'date_joined')
  DateTime? get dateJoined;

  /// Create a copy of AppUser
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$AppUserImplCopyWith<_$AppUserImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

LoginCredentials _$LoginCredentialsFromJson(Map<String, dynamic> json) {
  return _LoginCredentials.fromJson(json);
}

/// @nodoc
mixin _$LoginCredentials {
  String get credential => throw _privateConstructorUsedError;
  String get password => throw _privateConstructorUsedError;

  /// Serializes this LoginCredentials to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of LoginCredentials
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $LoginCredentialsCopyWith<LoginCredentials> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $LoginCredentialsCopyWith<$Res> {
  factory $LoginCredentialsCopyWith(
    LoginCredentials value,
    $Res Function(LoginCredentials) then,
  ) = _$LoginCredentialsCopyWithImpl<$Res, LoginCredentials>;
  @useResult
  $Res call({String credential, String password});
}

/// @nodoc
class _$LoginCredentialsCopyWithImpl<$Res, $Val extends LoginCredentials>
    implements $LoginCredentialsCopyWith<$Res> {
  _$LoginCredentialsCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of LoginCredentials
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? credential = null, Object? password = null}) {
    return _then(
      _value.copyWith(
            credential: null == credential
                ? _value.credential
                : credential // ignore: cast_nullable_to_non_nullable
                      as String,
            password: null == password
                ? _value.password
                : password // ignore: cast_nullable_to_non_nullable
                      as String,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$LoginCredentialsImplCopyWith<$Res>
    implements $LoginCredentialsCopyWith<$Res> {
  factory _$$LoginCredentialsImplCopyWith(
    _$LoginCredentialsImpl value,
    $Res Function(_$LoginCredentialsImpl) then,
  ) = __$$LoginCredentialsImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String credential, String password});
}

/// @nodoc
class __$$LoginCredentialsImplCopyWithImpl<$Res>
    extends _$LoginCredentialsCopyWithImpl<$Res, _$LoginCredentialsImpl>
    implements _$$LoginCredentialsImplCopyWith<$Res> {
  __$$LoginCredentialsImplCopyWithImpl(
    _$LoginCredentialsImpl _value,
    $Res Function(_$LoginCredentialsImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of LoginCredentials
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? credential = null, Object? password = null}) {
    return _then(
      _$LoginCredentialsImpl(
        credential: null == credential
            ? _value.credential
            : credential // ignore: cast_nullable_to_non_nullable
                  as String,
        password: null == password
            ? _value.password
            : password // ignore: cast_nullable_to_non_nullable
                  as String,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$LoginCredentialsImpl implements _LoginCredentials {
  const _$LoginCredentialsImpl({
    required this.credential,
    required this.password,
  });

  factory _$LoginCredentialsImpl.fromJson(Map<String, dynamic> json) =>
      _$$LoginCredentialsImplFromJson(json);

  @override
  final String credential;
  @override
  final String password;

  @override
  String toString() {
    return 'LoginCredentials(credential: $credential, password: $password)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$LoginCredentialsImpl &&
            (identical(other.credential, credential) ||
                other.credential == credential) &&
            (identical(other.password, password) ||
                other.password == password));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(runtimeType, credential, password);

  /// Create a copy of LoginCredentials
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$LoginCredentialsImplCopyWith<_$LoginCredentialsImpl> get copyWith =>
      __$$LoginCredentialsImplCopyWithImpl<_$LoginCredentialsImpl>(
        this,
        _$identity,
      );

  @override
  Map<String, dynamic> toJson() {
    return _$$LoginCredentialsImplToJson(this);
  }
}

abstract class _LoginCredentials implements LoginCredentials {
  const factory _LoginCredentials({
    required final String credential,
    required final String password,
  }) = _$LoginCredentialsImpl;

  factory _LoginCredentials.fromJson(Map<String, dynamic> json) =
      _$LoginCredentialsImpl.fromJson;

  @override
  String get credential;
  @override
  String get password;

  /// Create a copy of LoginCredentials
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$LoginCredentialsImplCopyWith<_$LoginCredentialsImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
