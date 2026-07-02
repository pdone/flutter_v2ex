import 'dart:io';
import 'dart:async';
import 'dart:convert';
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

/// Buffered socket reader that accumulates incoming bytes and exposes
/// helpers for reading exact-length or until a delimiter.
class _SocketReader {
  final Socket socket;
  final List<int> _buffer = [];
  StreamSubscription<Uint8List>? _subscription;
  Completer<void>? _waiter = Completer<void>();
  bool _done = false;
  Object? _error;

  _SocketReader(this.socket) {
    _subscription = socket.listen(
      (data) {
        _buffer.addAll(data);
        _notify();
      },
      onDone: () {
        _done = true;
        _notify();
      },
      onError: (Object e) {
        _error = e;
        _done = true;
        _notify();
      },
    );
  }

  void _notify() {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      w.complete();
    }
  }

  /// Reads exactly [count] bytes from the socket.
  Future<Uint8List> read(int count, {Duration? timeout}) async {
    final t = timeout ?? const Duration(seconds: 15);
    while (_buffer.length < count) {
      if (_done) {
        if (_error != null) {
          throw _error!;
        }
        throw Exception(
            'Socket closed while reading: expected $count bytes, got ${_buffer.length}');
      }
      final w = _waiter!;
      if (w.isCompleted) {
        _waiter = Completer<void>();
        continue;
      }
      await w.future.timeout(t);
      if (w.isCompleted) {
        _waiter = Completer<void>();
      }
    }
    final result = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer.removeRange(0, count);
    return result;
  }

  /// Reads until [delimiter] is found, returning bytes including the delimiter.
  Future<Uint8List> readUntil(List<int> delimiter, {Duration? timeout}) async {
    final t = timeout ?? const Duration(seconds: 15);
    while (true) {
      final idx = _search(delimiter);
      if (idx != -1) {
        final end = idx + delimiter.length;
        final result = Uint8List.fromList(_buffer.sublist(0, end));
        _buffer.removeRange(0, end);
        return result;
      }
      if (_done) {
        if (_error != null) throw _error!;
        throw Exception('Socket closed before delimiter found');
      }
      final w = _waiter!;
      if (w.isCompleted) {
        _waiter = Completer<void>();
        continue;
      }
      await w.future.timeout(t);
      if (w.isCompleted) {
        _waiter = Completer<void>();
      }
    }
  }

  /// Reads all remaining data until the socket is closed.
  Future<Uint8List> readUntilClose({Duration? timeout}) async {
    final t = timeout ?? const Duration(seconds: 30);
    while (!_done) {
      final w = _waiter!;
      if (w.isCompleted) {
        _waiter = Completer<void>();
        continue;
      }
      try {
        await w.future.timeout(t);
      } on TimeoutException {
        // Give up waiting and return whatever we have.
        break;
      }
      if (w.isCompleted) {
        _waiter = Completer<void>();
      }
    }
    final result = Uint8List.fromList(_buffer);
    _buffer.clear();
    return result;
  }

  int _search(List<int> needle) {
    if (_buffer.length < needle.length) return -1;
    for (int i = 0; i <= _buffer.length - needle.length; i++) {
      bool found = true;
      for (int j = 0; j < needle.length; j++) {
        if (_buffer[i + j] != needle[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
  }

  void cancel() {
    _subscription?.cancel();
    _subscription = null;
  }

  void destroy() {
    _subscription?.cancel();
    _subscription = null;
    socket.destroy();
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

    // Collect request body into memory so we can set Content-Length.
    List<int>? bodyBytes;
    if (requestStream != null) {
      bodyBytes = <int>[];
      await for (final chunk in requestStream) {
        bodyBytes.addAll(chunk);
      }
    } else if (options.data != null &&
        options.method.toUpperCase() != 'GET' &&
        options.method.toUpperCase() != 'HEAD') {
      bodyBytes = utf8.encode(options.data.toString());
    }

    final rawSocket = await Socket.connect(
      config.host,
      int.tryParse(config.port) ?? 1080,
      timeout: const Duration(seconds: 10),
    );

    _SocketReader? reader = _SocketReader(rawSocket);
    Socket activeSocket = rawSocket;

    try {
      // SOCKS5 handshake.
      await _socks5Handshake(
        activeSocket,
        reader,
        host,
        port,
        username: config.username.isNotEmpty ? config.username : null,
        password: config.password.isNotEmpty ? config.password : null,
      );

      // For HTTPS, wrap the tunnel with TLS.
      if (uri.scheme == 'https') {
        reader.cancel();
        reader = null;
        final secureSocket = await SecureSocket.secure(
          rawSocket,
          host: host,
          onBadCertificate: (_) => true,
        );
        activeSocket = secureSocket;
        reader = _SocketReader(secureSocket);
      }

      // Send HTTP request.
      await _sendHttpRequest(activeSocket, options, uri, bodyBytes);

      // Read HTTP response.
      return await _readHttpResponse(reader!, cancelFuture);
    } catch (e) {
      reader?.destroy();
      if (!identical(activeSocket, rawSocket)) {
        rawSocket.destroy();
      }
      activeSocket.destroy();
      rethrow;
    }
  }

  bool _isSocks5Available() {
    return config.isValid && config.type == 'socks5';
  }

  Future<void> _socks5Handshake(
    Socket socket,
    _SocketReader reader,
    String targetHost,
    int targetPort, {
    String? username,
    String? password,
  }) async {
    final bool haveAuth = username != null && password != null;

    // Method selection greeting.
    final greeting = <int>[0x05];
    if (haveAuth) {
      greeting.addAll([0x02, 0x00, 0x02]);
    } else {
      greeting.addAll([0x01, 0x00]);
    }
    socket.add(greeting);
    await socket.flush();

    final greetingResponse = await reader.read(2);
    if (greetingResponse[0] != 0x05) {
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

      final authResponse = await reader.read(2);
      if (authResponse[0] != 0x01 || authResponse[1] != 0x00) {
        throw Exception('SOCKS5: authentication failed');
      }
    } else if (authMethod != 0x00) {
      throw Exception('SOCKS5: unsupported auth method: $authMethod');
    }

    // CONNECT request. Prefer numeric address types when possible because
    // some SOCKS5 servers do not implement the DOMAINNAME type.
    final connectRequest = <int>[0x05, 0x01, 0x00];
    if (_isIPv4(targetHost)) {
      connectRequest.add(0x01);
      for (final part in targetHost.split('.')) {
        connectRequest.add(int.parse(part));
      }
    } else if (_isIPv6(targetHost)) {
      connectRequest.add(0x04);
      connectRequest.addAll(InternetAddress(targetHost).rawAddress);
    } else {
      final hostBytes = targetHost.codeUnits;
      if (hostBytes.length > 255) {
        throw Exception('SOCKS5: target host too long');
      }
      connectRequest.add(0x03);
      connectRequest.add(hostBytes.length);
      connectRequest.addAll(hostBytes);
    }
    connectRequest.add((targetPort >> 8) & 0xFF);
    connectRequest.add(targetPort & 0xFF);

    socket.add(connectRequest);
    await socket.flush();

    // Read connect response header (VER, REP, RSV, ATYP).
    final connectResponse = await reader.read(4);
    if (connectResponse[0] != 0x05) {
      throw Exception('SOCKS5: invalid connect response');
    }

    final reply = connectResponse[1];
    if (reply != 0x00) {
      const errors = {
        0x01: 'general SOCKS server failure',
        0x02: 'connection not allowed by ruleset',
        0x03: 'Network unreachable',
        0x04: 'Host unreachable',
        0x05: 'Connection refused',
        0x06: 'TTL expired',
        0x07: 'Command not supported',
        0x08: 'Address type not supported',
      };
      throw Exception(
          'SOCKS5: connection failed - ${errors[reply] ?? 'unknown error ($reply)'}');
    }

    // Drain BND.ADDR + BND.PORT so the socket is positioned at the tunnel.
    final atyp = connectResponse[3];
    int addrLen;
    switch (atyp) {
      case 0x01:
        addrLen = 4;
        break;
      case 0x03:
        final lenByte = await reader.read(1);
        addrLen = lenByte[0];
        break;
      case 0x04:
        addrLen = 16;
        break;
      default:
        addrLen = 0;
    }
    await reader.read(addrLen + 2);
  }

  Future<void> _sendHttpRequest(
    Socket socket,
    RequestOptions options,
    Uri uri,
    List<int>? bodyBytes,
  ) async {
    final path = uri.path.isEmpty ? '/' : uri.path;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    final buffer = StringBuffer()
      ..writeln('${options.method} $path$query HTTP/1.1');

    // Host header should include non-default port.
    final hostHeader =
        uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    buffer.writeln('Host: $hostHeader');
    buffer.writeln('Connection: close');

    final userAgent = options.headers['user-agent'];
    if (userAgent != null) {
      buffer.writeln('User-Agent: $userAgent');
    }

    if (bodyBytes != null && bodyBytes.isNotEmpty) {
      buffer.writeln('Content-Length: ${bodyBytes.length}');
    }

    final reservedKeys = <String>{
      'host',
      'connection',
      'user-agent',
      'content-length',
    };
    options.headers.forEach((key, value) {
      if (reservedKeys.contains(key.toLowerCase())) return;
      if (value is List) {
        for (final v in value) {
          buffer.writeln('$key: $v');
        }
      } else {
        buffer.writeln('$key: $value');
      }
    });

    buffer.writeln('');
    socket.write(buffer.toString());

    if (bodyBytes != null && bodyBytes.isNotEmpty) {
      socket.add(bodyBytes);
    }

    await socket.flush();
  }

  Future<ResponseBody> _readHttpResponse(
    _SocketReader reader,
    Future<void>? cancelFuture,
  ) async {
    final cancelCompleter = Completer<void>();
    cancelFuture?.whenComplete(() {
      if (!cancelCompleter.isCompleted) {
        cancelCompleter.complete();
      }
      reader.destroy();
    });

    // Read header block until CRLFCRLF.
    final headerBytes = await reader
        .readUntil([13, 10, 13, 10])
        .timeout(const Duration(seconds: 30));
    final headerStr =
        latin1.decode(headerBytes.sublist(0, headerBytes.length - 4));

    final lines = headerStr.split('\r\n');
    final statusLine = lines.first;
    final statusMatch =
        RegExp(r'HTTP/\d\.\d (\d+)').firstMatch(statusLine);
    final statusCode =
        statusMatch != null ? int.parse(statusMatch.group(1)!) : 200;

    final headers = <String, List<String>>{};
    String? transferEncoding;
    String? contentEncoding;
    int? contentLength;

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      final colonIndex = line.indexOf(':');
      if (colonIndex > 0) {
        final key = line.substring(0, colonIndex).trim();
        final value = line.substring(colonIndex + 1).trim();
        final lowerKey = key.toLowerCase();
        headers.putIfAbsent(lowerKey, () => []).add(value);
        if (lowerKey == 'transfer-encoding') {
          transferEncoding = value.toLowerCase();
        } else if (lowerKey == 'content-encoding') {
          contentEncoding = value.toLowerCase();
        } else if (lowerKey == 'content-length') {
          contentLength = int.tryParse(value);
        }
      }
    }

    // Read body based on framing.
    List<int> body;
    if (transferEncoding != null && transferEncoding.contains('chunked')) {
      body = await _readChunkedBody(reader);
    } else if (contentLength != null) {
      body = (await reader.read(contentLength)).toList();
    } else {
      body = (await reader.readUntilClose()).toList();
    }

    // Apply Content-Encoding decompression so Dio sees plain bytes.
    if (contentEncoding != null) {
      if (contentEncoding.contains('gzip') || contentEncoding.contains('x-gzip')) {
        body = gzip.decode(body);
        headers.remove('content-encoding');
        headers.remove('content-length');
      } else if (contentEncoding.contains('deflate')) {
        body = zlib.decode(body);
        headers.remove('content-encoding');
        headers.remove('content-length');
      }
    }

    // Remove Transfer-Encoding because we already de-chunked.
    if (transferEncoding != null) {
      headers.remove('transfer-encoding');
    }

    return ResponseBody(
      Stream.value(Uint8List.fromList(body)),
      statusCode,
      headers: headers,
      isRedirect: statusCode >= 300 && statusCode < 400,
    );
  }

  Future<List<int>> _readChunkedBody(_SocketReader reader) async {
    final body = <int>[];
    while (true) {
      // Read chunk size line (hex, optional extensions), terminated by CRLF.
      final sizeLine = await reader.readUntil([13, 10]);
      final sizeStr =
          latin1.decode(sizeLine.sublist(0, sizeLine.length - 2));
      final chunkSize =
          int.parse(sizeStr.split(';').first.trim(), radix: 16);

      if (chunkSize == 0) {
        // Trailer section ends with CRLF (empty) or trailer headers + CRLF.
        await reader.readUntil([13, 10]);
        break;
      }

      final chunkData = await reader.read(chunkSize);
      body.addAll(chunkData);
      // Trailing CRLF after chunk data.
      await reader.read(2);
    }
    return body;
  }

  bool _isIPv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  bool _isIPv6(String host) {
    return host.contains(':');
  }

  @override
  void close({bool force = false}) {
    _defaultAdapter.close(force: force);
  }
}
