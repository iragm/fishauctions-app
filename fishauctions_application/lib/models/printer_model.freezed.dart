// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'printer_model.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

BluetoothPrinter _$BluetoothPrinterFromJson(Map<String, dynamic> json) {
  return _BluetoothPrinter.fromJson(json);
}

/// @nodoc
mixin _$BluetoothPrinter {
  // The BLE remote identifier (Android MAC, iOS OS-assigned UUID). Used to
  // reconnect without a fresh scan via `BluetoothDevice.fromId`.
  String get address => throw _privateConstructorUsedError;
  String get name =>
      throw _privateConstructorUsedError; // The GATT characteristic we write label bytes to, once discovered. Stored
  // so a reconnect can target it directly instead of re-sniffing the device.
  // Null until the printer has been connected at least once.
  String? get serviceUuid => throw _privateConstructorUsedError;
  String? get characteristicUuid =>
      throw _privateConstructorUsedError; // True while an active connection is open.
  bool get connected => throw _privateConstructorUsedError;

  /// Serializes this BluetoothPrinter to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of BluetoothPrinter
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $BluetoothPrinterCopyWith<BluetoothPrinter> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $BluetoothPrinterCopyWith<$Res> {
  factory $BluetoothPrinterCopyWith(
    BluetoothPrinter value,
    $Res Function(BluetoothPrinter) then,
  ) = _$BluetoothPrinterCopyWithImpl<$Res, BluetoothPrinter>;
  @useResult
  $Res call({
    String address,
    String name,
    String? serviceUuid,
    String? characteristicUuid,
    bool connected,
  });
}

/// @nodoc
class _$BluetoothPrinterCopyWithImpl<$Res, $Val extends BluetoothPrinter>
    implements $BluetoothPrinterCopyWith<$Res> {
  _$BluetoothPrinterCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of BluetoothPrinter
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? address = null,
    Object? name = null,
    Object? serviceUuid = freezed,
    Object? characteristicUuid = freezed,
    Object? connected = null,
  }) {
    return _then(
      _value.copyWith(
            address: null == address
                ? _value.address
                : address // ignore: cast_nullable_to_non_nullable
                      as String,
            name: null == name
                ? _value.name
                : name // ignore: cast_nullable_to_non_nullable
                      as String,
            serviceUuid: freezed == serviceUuid
                ? _value.serviceUuid
                : serviceUuid // ignore: cast_nullable_to_non_nullable
                      as String?,
            characteristicUuid: freezed == characteristicUuid
                ? _value.characteristicUuid
                : characteristicUuid // ignore: cast_nullable_to_non_nullable
                      as String?,
            connected: null == connected
                ? _value.connected
                : connected // ignore: cast_nullable_to_non_nullable
                      as bool,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$BluetoothPrinterImplCopyWith<$Res>
    implements $BluetoothPrinterCopyWith<$Res> {
  factory _$$BluetoothPrinterImplCopyWith(
    _$BluetoothPrinterImpl value,
    $Res Function(_$BluetoothPrinterImpl) then,
  ) = __$$BluetoothPrinterImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    String address,
    String name,
    String? serviceUuid,
    String? characteristicUuid,
    bool connected,
  });
}

/// @nodoc
class __$$BluetoothPrinterImplCopyWithImpl<$Res>
    extends _$BluetoothPrinterCopyWithImpl<$Res, _$BluetoothPrinterImpl>
    implements _$$BluetoothPrinterImplCopyWith<$Res> {
  __$$BluetoothPrinterImplCopyWithImpl(
    _$BluetoothPrinterImpl _value,
    $Res Function(_$BluetoothPrinterImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of BluetoothPrinter
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? address = null,
    Object? name = null,
    Object? serviceUuid = freezed,
    Object? characteristicUuid = freezed,
    Object? connected = null,
  }) {
    return _then(
      _$BluetoothPrinterImpl(
        address: null == address
            ? _value.address
            : address // ignore: cast_nullable_to_non_nullable
                  as String,
        name: null == name
            ? _value.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        serviceUuid: freezed == serviceUuid
            ? _value.serviceUuid
            : serviceUuid // ignore: cast_nullable_to_non_nullable
                  as String?,
        characteristicUuid: freezed == characteristicUuid
            ? _value.characteristicUuid
            : characteristicUuid // ignore: cast_nullable_to_non_nullable
                  as String?,
        connected: null == connected
            ? _value.connected
            : connected // ignore: cast_nullable_to_non_nullable
                  as bool,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$BluetoothPrinterImpl implements _BluetoothPrinter {
  const _$BluetoothPrinterImpl({
    required this.address,
    required this.name,
    this.serviceUuid,
    this.characteristicUuid,
    this.connected = false,
  });

  factory _$BluetoothPrinterImpl.fromJson(Map<String, dynamic> json) =>
      _$$BluetoothPrinterImplFromJson(json);

  // The BLE remote identifier (Android MAC, iOS OS-assigned UUID). Used to
  // reconnect without a fresh scan via `BluetoothDevice.fromId`.
  @override
  final String address;
  @override
  final String name;
  // The GATT characteristic we write label bytes to, once discovered. Stored
  // so a reconnect can target it directly instead of re-sniffing the device.
  // Null until the printer has been connected at least once.
  @override
  final String? serviceUuid;
  @override
  final String? characteristicUuid;
  // True while an active connection is open.
  @override
  @JsonKey()
  final bool connected;

  @override
  String toString() {
    return 'BluetoothPrinter(address: $address, name: $name, serviceUuid: $serviceUuid, characteristicUuid: $characteristicUuid, connected: $connected)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$BluetoothPrinterImpl &&
            (identical(other.address, address) || other.address == address) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.serviceUuid, serviceUuid) ||
                other.serviceUuid == serviceUuid) &&
            (identical(other.characteristicUuid, characteristicUuid) ||
                other.characteristicUuid == characteristicUuid) &&
            (identical(other.connected, connected) ||
                other.connected == connected));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    address,
    name,
    serviceUuid,
    characteristicUuid,
    connected,
  );

  /// Create a copy of BluetoothPrinter
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$BluetoothPrinterImplCopyWith<_$BluetoothPrinterImpl> get copyWith =>
      __$$BluetoothPrinterImplCopyWithImpl<_$BluetoothPrinterImpl>(
        this,
        _$identity,
      );

  @override
  Map<String, dynamic> toJson() {
    return _$$BluetoothPrinterImplToJson(this);
  }
}

abstract class _BluetoothPrinter implements BluetoothPrinter {
  const factory _BluetoothPrinter({
    required final String address,
    required final String name,
    final String? serviceUuid,
    final String? characteristicUuid,
    final bool connected,
  }) = _$BluetoothPrinterImpl;

  factory _BluetoothPrinter.fromJson(Map<String, dynamic> json) =
      _$BluetoothPrinterImpl.fromJson;

  // The BLE remote identifier (Android MAC, iOS OS-assigned UUID). Used to
  // reconnect without a fresh scan via `BluetoothDevice.fromId`.
  @override
  String get address;
  @override
  String get name; // The GATT characteristic we write label bytes to, once discovered. Stored
  // so a reconnect can target it directly instead of re-sniffing the device.
  // Null until the printer has been connected at least once.
  @override
  String? get serviceUuid;
  @override
  String? get characteristicUuid; // True while an active connection is open.
  @override
  bool get connected;

  /// Create a copy of BluetoothPrinter
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$BluetoothPrinterImplCopyWith<_$BluetoothPrinterImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
