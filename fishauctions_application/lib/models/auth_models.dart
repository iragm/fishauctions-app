import 'package:freezed_annotation/freezed_annotation.dart';

part 'auth_models.freezed.dart';
part 'auth_models.g.dart';

@freezed
class TokenPair with _$TokenPair {
  const factory TokenPair({
    required String access,
    required String refresh,
  }) = _TokenPair;

  factory TokenPair.fromJson(Map<String, dynamic> json) =>
      _$TokenPairFromJson(json);
}

@freezed
class AppUser with _$AppUser {
  const factory AppUser({
    required int id,
    required String username,
    required String email,
    @JsonKey(name: 'first_name') @Default('') String firstName,
    @JsonKey(name: 'last_name') @Default('') String lastName,
    @JsonKey(name: 'is_staff') @Default(false) bool isStaff,
    @JsonKey(name: 'date_joined') DateTime? dateJoined,
  }) = _AppUser;

  factory AppUser.fromJson(Map<String, dynamic> json) =>
      _$AppUserFromJson(json);
}

@freezed
class LoginCredentials with _$LoginCredentials {
  const factory LoginCredentials({
    required String credential,
    required String password,
  }) = _LoginCredentials;

  factory LoginCredentials.fromJson(Map<String, dynamic> json) =>
      _$LoginCredentialsFromJson(json);
}
