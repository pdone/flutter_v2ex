import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ex/utils/proxy.dart';
import 'package:flutter_v2ex/utils/storage.dart';
import 'package:flutter_v2ex/http/init.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class SetProxyPage extends StatefulWidget {
  const SetProxyPage({super.key});

  @override
  State<SetProxyPage> createState() => _SetProxyPageState();
}

class _SetProxyPageState extends State<SetProxyPage> {
  late bool proxyEnable = false;
  late String proxyType = 'http';
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final List<String> _proxyTypes = ['http', 'socks5'];

  @override
  void initState() {
    super.initState();
    _loadProxyConfig();
  }

  void _loadProxyConfig() {
    proxyEnable = GStorage().getProxyEnable();
    proxyType = GStorage().getProxyType();
    _hostController.text = GStorage().getProxyHost();
    _portController.text = GStorage().getProxyPort();
    _usernameController.text = GStorage().getProxyUsername();
    _passwordController.text = GStorage().getProxyPassword();
  }

  Future<void> _saveProxyConfig() async {
    final host = _hostController.text.trim();
    final port = _portController.text.trim();

    if (proxyEnable) {
      if (host.isEmpty) {
        SmartDialog.showToast('请输入代理地址');
        return;
      }
      if (port.isEmpty) {
        SmartDialog.showToast('请输入代理端口');
        return;
      }
      final portNum = int.tryParse(port);
      if (portNum == null || portNum <= 0 || portNum > 65535) {
        SmartDialog.showToast('端口格式不正确');
        return;
      }
    }

    GStorage().setProxyEnable(proxyEnable);
    GStorage().setProxyType(proxyType);
    GStorage().setProxyHost(host);
    GStorage().setProxyPort(port);
    GStorage().setProxyUsername(_usernameController.text.trim());
    GStorage().setProxyPassword(_passwordController.text.trim());

    CustomProxy.currentConfig = ProxyConfig.fromStorage();
    Request.updateProxy();

    if (mounted) {
      SmartDialog.showToast(proxyEnable ? '代理已开启 ✅' : '代理已关闭');
    }
  }

  Future<void> _testProxy() async {
    final host = _hostController.text.trim();
    final port = _portController.text.trim();

    if (host.isEmpty || port.isEmpty) {
      SmartDialog.showToast('请先填写代理信息');
      return;
    }

    SmartDialog.showLoading(msg: '测试中...');

    try {
      final stopwatch = Stopwatch()..start();
      final uri = Uri.parse('https://www.v2ex.com');

      if (proxyType == 'http') {
        final client = HttpClient();
        client.findProxy = (uri) {
          return 'PROXY $host:$port;';
        };
        client.badCertificateCallback = (cert, host, port) => true;
        final request = await client.getUrl(uri).timeout(
              const Duration(seconds: 10),
            );
        final response = await request.close().timeout(
              const Duration(seconds: 10),
            );
        stopwatch.stop();
        if (response.statusCode == 200 || response.statusCode == 302) {
          SmartDialog.showToast(
            '连接成功 ⏱ ${stopwatch.elapsedMilliseconds}ms',
          );
        } else {
          SmartDialog.showToast('连接失败，状态码: ${response.statusCode}');
        }
        client.close();
      } else {
        SmartDialog.showToast('SOCKS5 测试请保存后直接使用');
      }
    } catch (e) {
      SmartDialog.showToast('连接失败: ${e.toString().substring(0, e.toString().length > 50 ? 50 : e.toString().length)}');
    } finally {
      SmartDialog.dismiss();
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    TextStyle subTitleStyle = Theme.of(context).textTheme.labelMedium!;
    TextStyle groupTitleStyle = Theme.of(context)
        .textTheme
        .titleSmall!
        .copyWith(color: Theme.of(context).colorScheme.primary);

    return Scaffold(
      appBar: AppBar(
        title: const Text('代理设置'),
        actions: [
          TextButton(
            onPressed: _saveProxyConfig,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('开启代理'),
            subtitle: Text(
              proxyEnable ? '代理已开启' : '代理已关闭',
              style: subTitleStyle,
            ),
            value: proxyEnable,
            onChanged: (value) {
              setState(() {
                proxyEnable = value;
              });
            },
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 25, 20, 5),
            child: Text('代理配置', style: groupTitleStyle),
          ),
          ListTile(
            title: const Text('代理类型'),
            trailing: DropdownButton<String>(
              value: proxyType,
              onChanged: proxyEnable
                  ? (String? newValue) {
                      setState(() {
                        proxyType = newValue!;
                      });
                    }
                  : null,
              items: _proxyTypes.map<DropdownMenuItem<String>>((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value.toUpperCase()),
                );
              }).toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _hostController,
              enabled: proxyEnable,
              decoration: const InputDecoration(
                labelText: '代理地址',
                hintText: '例如：127.0.0.1',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _portController,
              enabled: proxyEnable,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: const InputDecoration(
                labelText: '代理端口',
                hintText: '例如：7890',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 25, 20, 5),
            child: Text('认证配置（可选）', style: groupTitleStyle),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _usernameController,
              enabled: proxyEnable,
              decoration: const InputDecoration(
                labelText: '用户名',
                hintText: '无需认证请留空',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _passwordController,
              enabled: proxyEnable,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密码',
                hintText: '无需认证请留空',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ElevatedButton.icon(
              onPressed: proxyEnable ? _testProxy : null,
              icon: const Icon(Icons.network_check),
              label: const Text('测试连接'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '提示：修改代理设置后，建议重启应用以确保所有网络请求生效。\n\n支持的代理类型：\n• HTTP 代理\n• SOCKS5 代理',
              style: TextStyle(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}
