// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'login_history.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LoginHistory _$LoginHistoryFromJson(Map<String, dynamic> json) => LoginHistory(
      host: json['host'] as String,
      port: (json['port'] as num).toInt(),
      username: json['username'] as String,
      password: json['password'] as String?,
      passwordEncrypted: json['passwordEncrypted'] as bool? ?? false,
      isHttps: json['isHttps'] as bool,
      rememberPassword: json['rememberPassword'] as bool,
      isNasLogin: json['isNasLogin'] as bool? ?? false,
      fnConnectUrl: json['fnConnectUrl'] as String? ?? "",
      fnId: json['fnId'] as String? ?? "",
      lastLoginTimestamp: (json['lastLoginTimestamp'] as num?)?.toInt(),
      displayHost: json['displayHost'] as String? ?? "",
      displayPort: (json['displayPort'] as num?)?.toInt(),
      serverKind: $enumDecodeNullable(
              _$MediaServerKindEnumMap, json['serverKind']) ??
          MediaServerKind.fnos,
    );

Map<String, dynamic> _$LoginHistoryToJson(LoginHistory instance) =>
    <String, dynamic>{
      'host': instance.host,
      'port': instance.port,
      'username': instance.username,
      'password': instance.password,
      'passwordEncrypted': instance.passwordEncrypted,
      'isHttps': instance.isHttps,
      'rememberPassword': instance.rememberPassword,
      'isNasLogin': instance.isNasLogin,
      'fnConnectUrl': instance.fnConnectUrl,
      'fnId': instance.fnId,
      'lastLoginTimestamp': instance.lastLoginTimestamp,
      'displayHost': instance.displayHost,
      'displayPort': instance.displayPort,
      'serverKind': _$MediaServerKindEnumMap[instance.serverKind]!,
    };

const _$MediaServerKindEnumMap = <MediaServerKind, String>{
  MediaServerKind.fnos: 'fnos',
  MediaServerKind.emby: 'emby',
  MediaServerKind.jellyfin: 'jellyfin',
};
