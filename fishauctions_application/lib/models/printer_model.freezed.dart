// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'printer_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$BluetoothPrinter {

 String get address; String get name; String? get serviceUuid; String? get characteristicUuid; String? get profileSlug; double? get labelWidthMm; double? get labelHeightMm; bool get connected;
/// Create a copy of BluetoothPrinter
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BluetoothPrinterCopyWith<BluetoothPrinter> get copyWith => _$BluetoothPrinterCopyWithImpl<BluetoothPrinter>(this as BluetoothPrinter, _$identity);

  /// Serializes this BluetoothPrinter to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BluetoothPrinter&&(identical(other.address, address) || other.address == address)&&(identical(other.name, name) || other.name == name)&&(identical(other.serviceUuid, serviceUuid) || other.serviceUuid == serviceUuid)&&(identical(other.characteristicUuid, characteristicUuid) || other.characteristicUuid == characteristicUuid)&&(identical(other.profileSlug, profileSlug) || other.profileSlug == profileSlug)&&(identical(other.labelWidthMm, labelWidthMm) || other.labelWidthMm == labelWidthMm)&&(identical(other.labelHeightMm, labelHeightMm) || other.labelHeightMm == labelHeightMm)&&(identical(other.connected, connected) || other.connected == connected));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,address,name,serviceUuid,characteristicUuid,profileSlug,labelWidthMm,labelHeightMm,connected);

@override
String toString() {
  return 'BluetoothPrinter(address: $address, name: $name, serviceUuid: $serviceUuid, characteristicUuid: $characteristicUuid, profileSlug: $profileSlug, labelWidthMm: $labelWidthMm, labelHeightMm: $labelHeightMm, connected: $connected)';
}


}

/// @nodoc
abstract mixin class $BluetoothPrinterCopyWith<$Res>  {
  factory $BluetoothPrinterCopyWith(BluetoothPrinter value, $Res Function(BluetoothPrinter) _then) = _$BluetoothPrinterCopyWithImpl;
@useResult
$Res call({
 String address, String name, String? serviceUuid, String? characteristicUuid, String? profileSlug, double? labelWidthMm, double? labelHeightMm, bool connected
});




}
/// @nodoc
class _$BluetoothPrinterCopyWithImpl<$Res>
    implements $BluetoothPrinterCopyWith<$Res> {
  _$BluetoothPrinterCopyWithImpl(this._self, this._then);

  final BluetoothPrinter _self;
  final $Res Function(BluetoothPrinter) _then;

/// Create a copy of BluetoothPrinter
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? address = null,Object? name = null,Object? serviceUuid = freezed,Object? characteristicUuid = freezed,Object? profileSlug = freezed,Object? labelWidthMm = freezed,Object? labelHeightMm = freezed,Object? connected = null,}) {
  return _then(_self.copyWith(
address: null == address ? _self.address : address // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,serviceUuid: freezed == serviceUuid ? _self.serviceUuid : serviceUuid // ignore: cast_nullable_to_non_nullable
as String?,characteristicUuid: freezed == characteristicUuid ? _self.characteristicUuid : characteristicUuid // ignore: cast_nullable_to_non_nullable
as String?,profileSlug: freezed == profileSlug ? _self.profileSlug : profileSlug // ignore: cast_nullable_to_non_nullable
as String?,labelWidthMm: freezed == labelWidthMm ? _self.labelWidthMm : labelWidthMm // ignore: cast_nullable_to_non_nullable
as double?,labelHeightMm: freezed == labelHeightMm ? _self.labelHeightMm : labelHeightMm // ignore: cast_nullable_to_non_nullable
as double?,connected: null == connected ? _self.connected : connected // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [BluetoothPrinter].
extension BluetoothPrinterPatterns on BluetoothPrinter {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _BluetoothPrinter value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _BluetoothPrinter() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _BluetoothPrinter value)  $default,){
final _that = this;
switch (_that) {
case _BluetoothPrinter():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _BluetoothPrinter value)?  $default,){
final _that = this;
switch (_that) {
case _BluetoothPrinter() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String address,  String name,  String? serviceUuid,  String? characteristicUuid,  String? profileSlug,  double? labelWidthMm,  double? labelHeightMm,  bool connected)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BluetoothPrinter() when $default != null:
return $default(_that.address,_that.name,_that.serviceUuid,_that.characteristicUuid,_that.profileSlug,_that.labelWidthMm,_that.labelHeightMm,_that.connected);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String address,  String name,  String? serviceUuid,  String? characteristicUuid,  String? profileSlug,  double? labelWidthMm,  double? labelHeightMm,  bool connected)  $default,) {final _that = this;
switch (_that) {
case _BluetoothPrinter():
return $default(_that.address,_that.name,_that.serviceUuid,_that.characteristicUuid,_that.profileSlug,_that.labelWidthMm,_that.labelHeightMm,_that.connected);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String address,  String name,  String? serviceUuid,  String? characteristicUuid,  String? profileSlug,  double? labelWidthMm,  double? labelHeightMm,  bool connected)?  $default,) {final _that = this;
switch (_that) {
case _BluetoothPrinter() when $default != null:
return $default(_that.address,_that.name,_that.serviceUuid,_that.characteristicUuid,_that.profileSlug,_that.labelWidthMm,_that.labelHeightMm,_that.connected);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _BluetoothPrinter implements BluetoothPrinter {
  const _BluetoothPrinter({required this.address, required this.name, this.serviceUuid, this.characteristicUuid, this.profileSlug, this.labelWidthMm, this.labelHeightMm, this.connected = false});
  factory _BluetoothPrinter.fromJson(Map<String, dynamic> json) => _$BluetoothPrinterFromJson(json);

@override final  String address;
@override final  String name;
@override final  String? serviceUuid;
@override final  String? characteristicUuid;
@override final  String? profileSlug;
@override final  double? labelWidthMm;
@override final  double? labelHeightMm;
@override@JsonKey() final  bool connected;

/// Create a copy of BluetoothPrinter
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$BluetoothPrinterCopyWith<_BluetoothPrinter> get copyWith => __$BluetoothPrinterCopyWithImpl<_BluetoothPrinter>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$BluetoothPrinterToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BluetoothPrinter&&(identical(other.address, address) || other.address == address)&&(identical(other.name, name) || other.name == name)&&(identical(other.serviceUuid, serviceUuid) || other.serviceUuid == serviceUuid)&&(identical(other.characteristicUuid, characteristicUuid) || other.characteristicUuid == characteristicUuid)&&(identical(other.profileSlug, profileSlug) || other.profileSlug == profileSlug)&&(identical(other.labelWidthMm, labelWidthMm) || other.labelWidthMm == labelWidthMm)&&(identical(other.labelHeightMm, labelHeightMm) || other.labelHeightMm == labelHeightMm)&&(identical(other.connected, connected) || other.connected == connected));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,address,name,serviceUuid,characteristicUuid,profileSlug,labelWidthMm,labelHeightMm,connected);

@override
String toString() {
  return 'BluetoothPrinter(address: $address, name: $name, serviceUuid: $serviceUuid, characteristicUuid: $characteristicUuid, profileSlug: $profileSlug, labelWidthMm: $labelWidthMm, labelHeightMm: $labelHeightMm, connected: $connected)';
}


}

/// @nodoc
abstract mixin class _$BluetoothPrinterCopyWith<$Res> implements $BluetoothPrinterCopyWith<$Res> {
  factory _$BluetoothPrinterCopyWith(_BluetoothPrinter value, $Res Function(_BluetoothPrinter) _then) = __$BluetoothPrinterCopyWithImpl;
@override @useResult
$Res call({
 String address, String name, String? serviceUuid, String? characteristicUuid, String? profileSlug, double? labelWidthMm, double? labelHeightMm, bool connected
});




}
/// @nodoc
class __$BluetoothPrinterCopyWithImpl<$Res>
    implements _$BluetoothPrinterCopyWith<$Res> {
  __$BluetoothPrinterCopyWithImpl(this._self, this._then);

  final _BluetoothPrinter _self;
  final $Res Function(_BluetoothPrinter) _then;

/// Create a copy of BluetoothPrinter
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? address = null,Object? name = null,Object? serviceUuid = freezed,Object? characteristicUuid = freezed,Object? profileSlug = freezed,Object? labelWidthMm = freezed,Object? labelHeightMm = freezed,Object? connected = null,}) {
  return _then(_BluetoothPrinter(
address: null == address ? _self.address : address // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,serviceUuid: freezed == serviceUuid ? _self.serviceUuid : serviceUuid // ignore: cast_nullable_to_non_nullable
as String?,characteristicUuid: freezed == characteristicUuid ? _self.characteristicUuid : characteristicUuid // ignore: cast_nullable_to_non_nullable
as String?,profileSlug: freezed == profileSlug ? _self.profileSlug : profileSlug // ignore: cast_nullable_to_non_nullable
as String?,labelWidthMm: freezed == labelWidthMm ? _self.labelWidthMm : labelWidthMm // ignore: cast_nullable_to_non_nullable
as double?,labelHeightMm: freezed == labelHeightMm ? _self.labelHeightMm : labelHeightMm // ignore: cast_nullable_to_non_nullable
as double?,connected: null == connected ? _self.connected : connected // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
