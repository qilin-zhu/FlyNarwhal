import 'package:json_annotation/json_annotation.dart';

import '../backends/media_server_kind.dart';

part 'login_history.g.dart';

@JsonSerializable()
class LoginHistory {
  final String host;
  final int port;
  final String username;
  final String? password;

  @JsonKey(defaultValue: false)
  final bool passwordEncrypted;
  final bool isHttps;
  final bool rememberPassword;
  final bool isNasLogin;
  final String fnConnectUrl;
  final String fnId;
  final int lastLoginTimestamp;
  final String displayHost;
  final int? displayPort;

  /// Which server family this entry signs in to. Defaults to fnOS so entries
  /// written before the key existed still parse and still log in.
  final MediaServerKind serverKind;

  LoginHistory({
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.passwordEncrypted = false,
    required this.isHttps,
    required this.rememberPassword,
    this.isNasLogin = false,
    this.fnConnectUrl = "",
    this.fnId = "",
    int? lastLoginTimestamp,
    this.displayHost = "",
    this.displayPort,
    this.serverKind = MediaServerKind.fnos,
  }) : lastLoginTimestamp =
            lastLoginTimestamp ?? DateTime.now().millisecondsSinceEpoch;

  factory LoginHistory.fromJson(Map<String, dynamic> json) =>
      _$LoginHistoryFromJson(json);
  Map<String, dynamic> toJson() => _$LoginHistoryToJson(this);

  /// Whether this entry points at an Emby-family server.
  bool get isEmbyFamily => serverKind.isEmbyFamily;

  String getEndpoint() {
    if (isNasLogin) {
      return fnId.isEmpty ? "FN Connect" : fnId;
    }
    final dHost = displayHost.isEmpty ? host : displayHost;
    final dPort = displayPort ?? port;
    if (dPort != 0) {
      return "$dHost:$dPort";
    } else {
      return dHost;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! LoginHistory) return false;

    if (isNasLogin != other.isNasLogin) return false;
    // fnOS and Emby can live on the same host:port and use the same username,
    // so the server kind has to take part in the identity.
    if (serverKind != other.serverKind) return false;

    if (isNasLogin) {
      return fnId == other.fnId &&
          username == other.username &&
          isHttps == other.isHttps;
    } else {
      return displayHost == other.displayHost &&
          displayPort == other.displayPort &&
          username == other.username &&
          isHttps == other.isHttps;
    }
  }

  @override
  int get hashCode {
    var result = isNasLogin.hashCode;
    result = 31 * result + serverKind.hashCode;
    if (isNasLogin) {
      result = 31 * result + fnId.hashCode;
    } else {
      result = 31 * result + displayHost.hashCode;
      if (displayPort != null) result = 31 * result + displayPort!;
    }
    result = 31 * result + username.hashCode;
    result = 31 * result + isHttps.hashCode;
    return result;
  }
}
