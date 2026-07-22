// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auth_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_TokenPair _$TokenPairFromJson(Map<String, dynamic> json) => _TokenPair(
  access: json['access'] as String,
  refresh: json['refresh'] as String,
);

Map<String, dynamic> _$TokenPairToJson(_TokenPair instance) =>
    <String, dynamic>{'access': instance.access, 'refresh': instance.refresh};

_AppUser _$AppUserFromJson(Map<String, dynamic> json) => _AppUser(
  id: (json['id'] as num).toInt(),
  username: json['username'] as String,
  email: json['email'] as String,
  firstName: json['first_name'] as String? ?? '',
  lastName: json['last_name'] as String? ?? '',
  isStaff: json['is_staff'] as bool? ?? false,
  dateJoined: json['date_joined'] == null
      ? null
      : DateTime.parse(json['date_joined'] as String),
);

Map<String, dynamic> _$AppUserToJson(_AppUser instance) => <String, dynamic>{
  'id': instance.id,
  'username': instance.username,
  'email': instance.email,
  'first_name': instance.firstName,
  'last_name': instance.lastName,
  'is_staff': instance.isStaff,
  'date_joined': instance.dateJoined?.toIso8601String(),
};

_LoginCredentials _$LoginCredentialsFromJson(Map<String, dynamic> json) =>
    _LoginCredentials(
      credential: json['credential'] as String,
      password: json['password'] as String,
    );

Map<String, dynamic> _$LoginCredentialsToJson(_LoginCredentials instance) =>
    <String, dynamic>{
      'credential': instance.credential,
      'password': instance.password,
    };
