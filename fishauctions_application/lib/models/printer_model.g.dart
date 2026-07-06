// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'printer_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$BluetoothPrinterImpl _$$BluetoothPrinterImplFromJson(
  Map<String, dynamic> json,
) => _$BluetoothPrinterImpl(
  address: json['address'] as String,
  name: json['name'] as String,
  serviceUuid: json['serviceUuid'] as String?,
  characteristicUuid: json['characteristicUuid'] as String?,
  profileSlug: json['profileSlug'] as String?,
  labelWidthMm: (json['labelWidthMm'] as num?)?.toDouble(),
  labelHeightMm: (json['labelHeightMm'] as num?)?.toDouble(),
  connected: json['connected'] as bool? ?? false,
);

Map<String, dynamic> _$$BluetoothPrinterImplToJson(
  _$BluetoothPrinterImpl instance,
) => <String, dynamic>{
  'address': instance.address,
  'name': instance.name,
  'serviceUuid': instance.serviceUuid,
  'characteristicUuid': instance.characteristicUuid,
  'profileSlug': instance.profileSlug,
  'labelWidthMm': instance.labelWidthMm,
  'labelHeightMm': instance.labelHeightMm,
  'connected': instance.connected,
};
