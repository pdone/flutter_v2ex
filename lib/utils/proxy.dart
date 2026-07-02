import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_v2ex/utils/storage.dart';

class ProxyConfig {
  bool enable;
  String type;
  String host;
  String port;
  String username;
  String password;

  ProxyConfig({
    this.enable = false,
    this.type = 'http',
    this.host = '',
    this.port = '',
    this.username = '',
    this.password = '',
  });

  bool get isValid {
    return enable && host.isNotEmpty && port.isNotEmpty;
  }

  String get proxyUrl {
    if (!isValid) return '';
    if (username.isNotEmpty && password.isNotEmpty) {
      return '$type://$username:$password@$host:$port';
    }
    return '$type://$host:$port';
  }

  factory ProxyConfig.fromStorage() {
    return ProxyConfig(
      enable: GStorage().getProxyEnable(),
      type: GStorage().getProxyType(),
      host: GStorage().getProxyHost(),
      port: GStorage().getProxyPort(),
      username: GStorage().getProxyUsername(),
      password: GStorage().getProxyPassword(),
    );
  }

  void saveToStorage() {
    GStorage().setProxyEnable(enable);
    GStorage().setProxyType(type);
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

  static HttpClientAdapter createDioAdapter() {
    if (!currentConfig.isValid) {
      return HttpClientAdapter();
    }
    if (currentConfig.type == 'socks5') {
      return Socks5HttpClientAdapter(currentConfig);
    }
    return HttpClientAdapter();
  }

  static void setupHttpClient(HttpClient client) {
    if (!currentConfig.isValid) return;
    if (currentConfig.type == 'http') {
      client.findProxy = (uri) {
        if (currentConfig.username.isNotEmpty &&
            currentConfig.password.isNotEmpty) {
          client.addCredentials(
            Uri.parse('${currentConfig.type}://${currentConfig.host}:${currentConfig.port}'),
            '',
            HttpClientBasicCredentials(
              currentConfig.username,
              currentConfig.password,
            ),
          );
        }
        return 'PROXY ${currentConfig.host}:${currentConfig.port};';
      };
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    }
  }
}

class Socks5HttpClientAdapter implements HttpClientAdapter {
  final ProxyConfig config;
  final HttpClientAdapter _defaultAdapter = HttpClientAdapter();

  Socks5HttpClientAdapter(this.config);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!_isSocks5Available()) {
      return _defaultAdapter.fetch(options, requestStream, cancelFuture);
    }

    final uri = options.uri;
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

    final socksSocket = await _connectSocks5(
      config.host,
      int.tryParse(config.port) ?? 1080,
      host,
      port,
      username: config.username.isNotEmpty ? config.username : null,
      password: config.password.isNotEmpty ? config.password : null,
    );

    if (uri.scheme == 'https') {
      final secureSocket = await SecureSocket.secure(
        socksSocket,
        host: host,
        onBadCertificate: (_) => true,
      );
      return _fetchOverSocket(options, requestStream, cancelFuture, secureSocket, uri);
    } else {
      return _fetchOverSocket(options, requestStream, cancelFuture, socksSocket, uri);
    }
  }

  bool _isSocks5Available() {
    return config.isValid && config.type == 'socks5';
  }

  Future<Socket> _connectSocks5(
    String proxyHost,
    int proxyPort,
    String targetHost,
    int targetPort, {
    String? username,
    String? password,
  }) async {
    final socket = await Socket.connect(
      proxyHost,
      proxyPort,
      timeout: const Duration(seconds: 10),
    );

    try {
      final bool haveAuth = username != null && password != null;

      List<int> greeting = [0x05];
      if (haveAuth) {
        greeting.addAll([0x02, 0x00, 0x02]);
      } else {
        greeting.addAll([0x01, 0x00]);
      }
      socket.add(greeting);
      await socket.flush();

      final greetingResponse = await socket.first.timeout(
        const Duration(seconds: 5),
      );
      if (greetingResponse.length < 2 || greetingResponse[0] != 0x05) {
        throw Exception('SOCKS5: invalid greeting response');
      }

      final authMethod = greetingResponse[1];
      if (authMethod == 0x02 && haveAuth) {
        final authRequest = <int>[0x01];
        authRequest.add(username!.length);
        authRequest.addAll(username.codeUnits);
        authRequest.add(password!.length);
        authRequest.addAll(password.codeUnits);
        socket.add(authRequest);
        await socket.flush();

        final authResponse = await socket.first.timeout(
          const Duration(seconds: 5),
        );
        if (authResponse.length < 2 ||
            authResponse[0] != 0x01 ||
            authResponse[1] != 0x00) {
          throw Exception('SOCKS5: authentication failed');
        }
      } else if (authMethod != 0x00) {
        throw Exception('SOCKS5: unsupported auth method: $authMethod');
      }

      final connectRequest = <int>[0x05, 0x01, 0x00];

      final hostBytes = targetHost.codeUnits;
      if (hostBytes.length > 255) {
        throw Exception('SOCKS5: target host too long');
      }
      connectRequest.add(0x03);
      connectRequest.add(hostBytes.length);
      connectRequest.addAll(hostBytes);

      connectRequest.add((targetPort >> 8) & 0xFF);
      connectRequest.add(targetPort & 0xFF);

      socket.add(connectRequest);
      await socket.flush();

      final connectResponse = await socket.first.timeout(
        const Duration(seconds: 10),
      );
      if (connectResponse.length < 4 || connectResponse[0] != 0x05) {
        throw Exception('SOCKS5: invalid connect response');
      }

      final reply = connectResponse[1];
      if (reply != 0x00) {
        final errors = {
          0x01: 'general SOCKS server failure',
          0x02: 'connection not allowed by ruleset',
          0x03: 'Network unreachable',
          0x04: 'Host unreachable',
          0x05: 'Connection refused',
          0x06: 'TTL expired',
          0x07: 'Command not supported',
          0x08: 'Address type not supported',
        };
        throw Exception('SOCKS5: connection failed - ${errors[reply] ?? 'unknown error ($reply)'}');
      }

      return socket;
    } catch (e) {
      socket.destroy();
      rethrow;
    }
  }

  Future<ResponseBody> _fetchOverSocket(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
    Socket socket,
    Uri uri,
  ) async {
    final buffer = StringBuffer();
    buffer.writeln('${options.method} ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''} HTTP/1.1');
    buffer.writeln('Host: ${uri.host}');
    buffer.writeln('User-Agent: ${options.headers['user-agent'] ?? 'Dart/3.0'}');
    buffer.writeln('Connection: close');

    options.headers.forEach((key, value) {
      if (key.toLowerCase() != 'host' && key.toLowerCase() != 'user-agent') {
        if (value is List) {
          for (var v in value) {
            buffer.writeln('$key: $v');
          }
        } else {
          buffer.writeln('$key: $value');
        }
      }
    });

    if (requestStream == null && options.data != null) {
      final dataStr = options.data.toString();
      buffer.writeln('Content-Length: ${dataStr.length}');
    }

    buffer.writeln('');

    socket.write(buffer.toString());

    if (requestStream != null) {
      await requestStream.forEach((data) {
        socket.add(data as List<int>);
      });
    } else if (options.data != null && options.method.toUpperCase() != 'GET') {
      socket.write(options.data.toString());
    }

    await socket.flush();

    final completer = Completer<List<int>>();
    final bytes = <int>[];

    socket.listen(
      (data) {
        bytes.addAll(data);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(bytes);
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );

    cancelFuture?.whenComplete(() {
      socket.destroy();
      if (!completer.isCompleted) {
        completer.completeError(Exception('Request cancelled'));
      }
    });

    final responseBytes = await completer.future;
    socket.destroy();

    final responseStr = String.fromCharCodes(responseBytes);
    final headerEnd = responseStr.indexOf('\r\n\r\n');
    if (headerEnd == -1) {
      throw Exception('Invalid HTTP response');
    }

    final headerSection = responseStr.substring(0, headerEnd);
    final bodySection = responseBytes.sublist(headerEnd + 4);

    final headers = <String, List<String>>{};
    final lines = headerSection.split('\r\n');
    final statusLine = lines.first;
    final statusMatch = RegExp(r'HTTP/\d\.\d (\d+) (.+)').firstMatch(statusLine);
    final statusCode = statusMatch != null ? int.parse(statusMatch.group(1)!) : 200;

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      final colonIndex = line.indexOf(':');
      if (colonIndex > 0) {
        final key = line.substring(0, colonIndex).trim().toLowerCase();
        final value = line.substring(colonIndex + 1).trim();
        headers.putIfAbsent(key, () => []).add(value);
      }
    }

    return ResponseBody(
      Stream.value(Uint8List.fromList(bodySection)),
      statusCode,
      headers: headers,
      isRedirect: false,
    );
  }

  @override
  void close({bool force = false}) {
    _defaultAdapter.close(force: force);
  }
}
