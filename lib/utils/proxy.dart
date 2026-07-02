import 'dart:io';
import 'package:flutter_v2ex/utils/storage.dart';

class ProxyConfig {
  bool enable;
  String host;
  String port;
  String username;
  String password;

  ProxyConfig({
    this.enable = false,
    this.host = '',
    this.port = '',
    this.username = '',
    this.password = '',
  });

  bool get isValid {
    return enable && host.isNotEmpty && port.isNotEmpty;
  }

  factory ProxyConfig.fromStorage() {
    return ProxyConfig(
      enable: GStorage().getProxyEnable(),
      host: GStorage().getProxyHost(),
      port: GStorage().getProxyPort(),
      username: GStorage().getProxyUsername(),
      password: GStorage().getProxyPassword(),
    );
  }

  void saveToStorage() {
    GStorage().setProxyEnable(enable);
    GStorage().setProxyHost(host);
    GStorage().setProxyPort(port);
    GStorage().setProxyUsername(username);
    GStorage().setProxyPassword(password);
  }
}

class CustomProxy {
  static ProxyConfig currentConfig = ProxyConfig();

  static Future<void> init() async {
    currentConfig = ProxyConfig.fromStorage();
  }

  static void setupHttpClient(HttpClient client) {
    if (!currentConfig.isValid) return;
    client.findProxy = (uri) {
      return 'PROXY ${currentConfig.host}:${currentConfig.port};';
    };
    if (currentConfig.username.isNotEmpty &&
        currentConfig.password.isNotEmpty) {
      client.addCredentials(
        Uri.parse('http://${currentConfig.host}:${currentConfig.port}'),
        '',
        HttpClientBasicCredentials(
          currentConfig.username,
          currentConfig.password,
        ),
      );
    }
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) => true;
  }
}
