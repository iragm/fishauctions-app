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
  connected: json['connected'] as bool? ?? false,
);

Map<String, dynamic> _$$BluetoothPrinterImplToJson(
  _$BluetoothPrinterImpl instance,
) => <String, dynamic>{
  'address': instance.address,
  'name': instance.name,
  'serviceUuid': instance.serviceUuid,
  'characteristicUuid': instance.characteristicUuid,
  'connected': instance.connected,
};
