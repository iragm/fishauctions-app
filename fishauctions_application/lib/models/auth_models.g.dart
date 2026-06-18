// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auth_models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$TokenPairImpl _$$TokenPairImplFromJson(Map<String, dynamic> json) =>
    _$TokenPairImpl(
      access: json['access'] as String,
      refresh: json['refresh'] as String,
    );

Map<String, dynamic> _$$TokenPairImplToJson(_$TokenPairImpl instance) =>
    <String, dynamic>{'access': instance.access, 'refresh': instance.refresh};

_$AppUserImpl _$$AppUserImplFromJson(Map<String, dynamic> json) =>
    _$AppUserImpl(
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

Map<String, dynamic> _$$AppUserImplToJson(_$AppUserImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'username': instance.username,
      'email': instance.email,
      'first_name': instance.firstName,
      'last_name': instance.lastName,
      'is_staff': instance.isStaff,
      'date_joined': instance.dateJoined?.toIso8601String(),
    };

_$LoginCredentialsImpl _$$LoginCredentialsImplFromJson(
  Map<String, dynamic> json,
) => _$LoginCredentialsImpl(
  credential: json['credential'] as String,
  password: json['password'] as String,
);

Map<String, dynamic> _$$LoginCredentialsImplToJson(
  _$LoginCredentialsImpl instance,
) => <String, dynamic>{
  'credential': instance.credential,
  'password': instance.password,
};
