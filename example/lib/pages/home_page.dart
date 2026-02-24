import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v2ray_box/v2ray_box.dart';

import 'config_editor_page.dart';

class HomePage extends StatefulWidget {
  final V2rayBox v2rayBox;
  const HomePage({super.key, required this.v2rayBox});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  VpnStatus _status = VpnStatus.stopped;
  VpnStats _stats = const VpnStats();
  VpnMode _mode = VpnMode.vpn;
  String _coreEngine = 'xray';
  TotalTraffic _totalTraffic = const TotalTraffic();

  List<VpnConfig> _configs = [];
  VpnConfig? _selectedConfig;

  StreamSubscription<VpnStatus>? _statusSub;
  StreamSubscription<VpnStats>? _statsSub;
  StreamSubscription<Map<String, dynamic>>? _pingResultsSub;
  Timer? _trafficTimer;
  int _pingRunId = 0;
  bool _pingAllInProgress = false;
  bool _proxyProbeInProgress = false;
  Map<String, bool?> _proxyEndpointStatus = {};

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pulseCtrl = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _load();
  }

  Future<void> _load() async {
    await _loadConfigs();
    await _refreshRuntimeState();
    _startWatching();
    if (mounted) setState(() {});
  }

  Future<void> _refreshRuntimeState() async {
    final mode = await widget.v2rayBox.getServiceMode();
    final core = await widget.v2rayBox.getCoreEngine();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _coreEngine = core;
    });
  }

  List<_LocalProxyEndpoint> _proxyEndpointsForCurrentCore() {
    final core = _coreEngine.toLowerCase();
    if (core == 'singbox') {
      return const [
        _LocalProxyEndpoint(
          label: 'SOCKS5',
          uri: 'socks5://127.0.0.1:10808',
          note: 'sing-box mixed inbound',
        ),
        _LocalProxyEndpoint(
          label: 'HTTP',
          uri: 'http://127.0.0.1:10808',
          note: 'sing-box mixed inbound',
        ),
      ];
    }
    return const [
      _LocalProxyEndpoint(
        label: 'SOCKS5',
        uri: 'socks5://127.0.0.1:10808',
        note: 'xray socks inbound',
      ),
      _LocalProxyEndpoint(
        label: 'HTTP',
        uri: 'http://127.0.0.1:10809',
        note: 'xray http inbound',
      ),
    ];
  }

  Future<bool> _isLocalPortReady(int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 800),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _probeLocalProxyEndpoints() async {
    if (_proxyProbeInProgress) return;
    await _refreshRuntimeState();
    final endpoints = _proxyEndpointsForCurrentCore();

    setState(() {
      _proxyProbeInProgress = true;
      _proxyEndpointStatus = {};
    });

    try {
      final result = <String, bool?>{};
      for (final endpoint in endpoints) {
        final uri = Uri.parse(endpoint.uri);
        result[endpoint.uri] = await _isLocalPortReady(uri.port);
      }
      if (!mounted) return;
      setState(() => _proxyEndpointStatus = result);
    } finally {
      if (mounted) {
        setState(() => _proxyProbeInProgress = false);
      }
    }
  }

  Future<void> _copyProxyEndpoint(String uri) async {
    await Clipboard.setData(ClipboardData(text: uri));
    _snack('$uri copied');
  }

  Future<void> _loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('vpn_configs');
    var hadTransientPing = false;
    if (json != null) {
      final List<dynamic> list = jsonDecode(json);
      _configs = list.map((e) => VpnConfig.fromJson(e)).toList();
      for (final c in _configs) {
        if (c.ping == -2) {
          c.ping = -1;
          hadTransientPing = true;
        }
      }
      for (var c in _configs) {
        if (c.isSelected) {
          _selectedConfig = c;
          break;
        }
      }
    }
    if (hadTransientPing) {
      await _saveConfigs();
    }
  }

  Future<void> _saveConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final persistable = _configs
        .map((e) => e.copyWith(ping: e.ping == -2 ? -1 : e.ping))
        .map((e) => e.toJson())
        .toList();
    await prefs.setString('vpn_configs', jsonEncode(persistable));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshRuntimeState());
      if (_mode == VpnMode.proxy && _status == VpnStatus.started) {
        unawaited(_probeLocalProxyEndpoints());
      }
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_cancelPingOperations(resetLoading: true, persist: true));
    }
  }

  Future<void> _cancelPingOperations({
    bool resetLoading = true,
    bool persist = false,
  }) async {
    _pingRunId++;
    _pingAllInProgress = false;
    await _pingResultsSub?.cancel();
    _pingResultsSub = null;

    if (!resetLoading) return;
    var changed = false;
    for (final c in _configs) {
      if (c.ping == -2) {
        c.ping = -1;
        changed = true;
      }
    }
    if (changed && mounted) {
      setState(() {});
    }
    if (changed && persist) {
      await _saveConfigs();
    }
  }

  void _startWatching() {
    _statusSub = widget.v2rayBox.watchStatus().listen((s) {
      if (!mounted) return;
      setState(() => _status = s);
      if (_mode == VpnMode.proxy && s == VpnStatus.started) {
        unawaited(_probeLocalProxyEndpoints());
      } else if (s != VpnStatus.started && _proxyEndpointStatus.isNotEmpty) {
        setState(() => _proxyEndpointStatus = {});
      }
    });
    _statsSub = widget.v2rayBox.watchStats().listen((s) {
      if (mounted) setState(() => _stats = s);
    });
    _loadTraffic();
    _trafficTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _loadTraffic(),
    );
  }

  Future<void> _loadTraffic() async {
    final t = await widget.v2rayBox.getTotalTraffic();
    if (mounted) setState(() => _totalTraffic = t);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_cancelPingOperations(resetLoading: true, persist: false));
    _statusSub?.cancel();
    _statsSub?.cancel();
    _trafficTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _addFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _snack('Clipboard is empty');
      return;
    }

    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    int added = 0;

    for (final line in lines) {
      final link = line.trim();
      if (!widget.v2rayBox.isValidConfigLink(link)) continue;
      if (_configs.any((c) => c.link == link)) continue;
      final config = widget.v2rayBox.parseConfigLink(link);
      _configs.add(config);
      added++;
    }

    if (added > 0) {
      await _saveConfigs();
      setState(() {});
      _snack('$added config(s) added');
    } else {
      _snack('No valid new configs found');
    }
  }

  Future<void> _addFromQrScan() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerPage()),
    );
    if (result == null || result.isEmpty) return;

    final lines = result.split('\n').where((l) => l.trim().isNotEmpty).toList();
    int added = 0;
    for (final line in lines) {
      final link = line.trim();
      if (!widget.v2rayBox.isValidConfigLink(link)) continue;
      if (_configs.any((c) => c.link == link)) continue;
      _configs.add(widget.v2rayBox.parseConfigLink(link));
      added++;
    }

    if (added > 0) {
      await _saveConfigs();
      setState(() {});
      _snack('$added config(s) added from QR');
    } else {
      _snack('No valid config found in QR code');
    }
  }

  Future<void> _addFromTextInput() async {
    final ctrl = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Config Link'),
        content: TextField(
          controller: ctrl,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'vless://... or vmess://...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (link == null || link.isEmpty) return;

    final lines = link.split('\n').where((l) => l.trim().isNotEmpty).toList();
    int added = 0;
    for (final line in lines) {
      final l = line.trim();
      if (!widget.v2rayBox.isValidConfigLink(l)) continue;
      if (_configs.any((c) => c.link == l)) continue;
      _configs.add(widget.v2rayBox.parseConfigLink(l));
      added++;
    }

    if (added > 0) {
      await _saveConfigs();
      setState(() {});
      _snack('$added config(s) added');
    } else {
      _snack('No valid config link found');
    }
  }

  Future<void> _pingConfig(VpnConfig config) async {
    await _cancelPingOperations(resetLoading: false, persist: false);
    final i = _configs.indexOf(config);
    if (i < 0) return;
    final runId = ++_pingRunId;
    setState(() => _configs[i].ping = -2);
    try {
      final latency = await widget.v2rayBox.ping(config.link);
      if (!mounted || runId != _pingRunId) return;
      setState(() => _configs[i].ping = latency);
    } finally {
      if (mounted && runId == _pingRunId) {
        await _saveConfigs();
      }
    }
  }

  Future<void> _pingAll() async {
    if (_configs.isEmpty) return;
    if (_pingAllInProgress) return;
    await _cancelPingOperations(resetLoading: false, persist: false);
    final runId = ++_pingRunId;
    _pingAllInProgress = true;

    setState(() {
      for (var c in _configs) {
        c.ping = -2;
      }
    });

    _pingResultsSub = widget.v2rayBox.watchPingResults().listen((r) {
      if (runId != _pingRunId) return;
      final link = r['link'] as String?;
      final latency = (r['latency'] as num?)?.toInt() ?? -1;
      if (link != null && mounted) {
        setState(() {
          var updated = false;
          for (final cfg in _configs) {
            if (cfg.link == link) {
              cfg.ping = latency;
              updated = true;
            }
          }
          if (!updated) {
            final idx = _configs.indexWhere((c) => c.link == link);
            if (idx >= 0) _configs[idx].ping = latency;
          }
        });
      }
    });

    try {
      await widget.v2rayBox.pingAll(_configs.map((c) => c.link).toList());
    } finally {
      await _pingResultsSub?.cancel();
      _pingResultsSub = null;
      if (runId == _pingRunId) {
        _pingAllInProgress = false;
        var changed = false;
        for (final c in _configs) {
          if (c.ping == -2) {
            c.ping = -1;
            changed = true;
          }
        }
        if (changed && mounted) {
          setState(() {});
        }
        await _saveConfigs();
      }
    }
  }

  void _selectConfig(VpnConfig config) {
    setState(() {
      for (var c in _configs) {
        c.isSelected = false;
      }
      config.isSelected = true;
      _selectedConfig = config;
    });
    _saveConfigs();
  }

  Future<void> _deleteConfig(VpnConfig config) async {
    setState(() {
      _configs.remove(config);
      if (_selectedConfig == config) _selectedConfig = null;
    });
    await _saveConfigs();
  }

  Future<void> _toggleConnection() async {
    if (_status == VpnStatus.starting || _status == VpnStatus.stopping) return;
    await _refreshRuntimeState();

    if (_status == VpnStatus.started) {
      await widget.v2rayBox.disconnect();
    } else {
      if (_selectedConfig == null) {
        _snack('Please select a config first');
        return;
      }
      try {
        if (_mode == VpnMode.vpn) {
          final has = await widget.v2rayBox.checkVpnPermission();
          if (!has) {
            final granted = await widget.v2rayBox.requestVpnPermission();
            if (!granted) {
              _snack('VPN permission required');
              return;
            }
          }
        }
        final err = await widget.v2rayBox.parseConfig(_selectedConfig!.link);
        if (err.isNotEmpty) {
          _snack('Config error: $err');
          return;
        }
        await widget.v2rayBox.connect(
          _selectedConfig!.link,
          name: _selectedConfig!.name,
        );
      } catch (e) {
        _snack('Connection failed: $e');
      }
    }
  }

  Future<void> _viewConfigJson(VpnConfig config) async {
    try {
      final json = await widget.v2rayBox.generateConfig(config.link);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ConfigEditorPage(
            v2rayBox: widget.v2rayBox,
            configJson: json,
            configName: config.name,
          ),
        ),
      );
    } catch (e) {
      _snack('Error: $e');
    }
  }

  void _showQrCode(VpnConfig config) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(config.name, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 280,
          height: 280,
          child: Center(
            child: QrImageView(
              data: config.link,
              version: QrVersions.auto,
              size: 260,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                color: Colors.black,
                eyeShape: QrEyeShape.square,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                color: Colors.black,
                dataModuleShape: QrDataModuleShape.square,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _shareConfig(VpnConfig config) {
    SharePlus.instance.share(ShareParams(text: config.link));
  }

  void _copyLink(VpnConfig config) {
    Clipboard.setData(ClipboardData(text: config.link));
    _snack('Link copied');
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2D2D44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildConnectionCard(),
                  if (_mode == VpnMode.proxy) _buildProxyModeCard(),
                  _buildStatsRow(),
                  _buildTotalTrafficCard(),
                  _buildConfigSection(),
                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'V2Ray Box',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Text(
                _mode == VpnMode.vpn ? 'VPN Mode' : 'Proxy Mode',
                style: TextStyle(color: Colors.grey[400], fontSize: 14),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _pingAll,
                tooltip: 'Ping All',
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.add),
                tooltip: 'Add Config',
                onSelected: (v) {
                  switch (v) {
                    case 'clipboard':
                      _addFromClipboard();
                    case 'qr':
                      _addFromQrScan();
                    case 'text':
                      _addFromTextInput();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'clipboard',
                    child: ListTile(
                      leading: Icon(Icons.content_paste),
                      title: Text('From Clipboard'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'qr',
                    child: ListTile(
                      leading: Icon(Icons.qr_code_scanner),
                      title: Text('Scan QR Code'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'text',
                    child: ListTile(
                      leading: Icon(Icons.edit),
                      title: Text('Enter Manually'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionCard() {
    final isConnected = _status == VpnStatus.started;
    final isTransitioning =
        _status == VpnStatus.starting || _status == VpnStatus.stopping;

    String statusText = 'Disconnected';
    Color statusColor = Colors.grey;
    IconData statusIcon = Icons.shield_outlined;

    if (isConnected) {
      statusText = 'Connected';
      statusColor = const Color(0xFF00D9FF);
      statusIcon = Icons.shield;
    } else if (_status == VpnStatus.starting) {
      statusText = 'Connecting...';
      statusColor = const Color(0xFFFFA502);
    } else if (_status == VpnStatus.stopping) {
      statusText = 'Disconnecting...';
      statusColor = const Color(0xFFFFA502);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GestureDetector(
        onTap: _toggleConnection,
        child: Card(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: isConnected
                  ? LinearGradient(
                      colors: [
                        const Color(0xFF6C5CE7).withOpacity(0.3),
                        const Color(0xFF00D9FF).withOpacity(0.1),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
            ),
            child: Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: isTransitioning ? _pulseAnim.value : 1.0,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: statusColor.withOpacity(0.2),
                        ),
                        child: isTransitioning
                            ? SizedBox(
                                width: 32,
                                height: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  valueColor: AlwaysStoppedAnimation(
                                    statusColor,
                                  ),
                                ),
                              )
                            : Icon(statusIcon, color: statusColor, size: 32),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: statusColor,
                        ),
                      ),
                      if (_selectedConfig != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _selectedConfig!.name,
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 14,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  isConnected
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline,
                  color: statusColor,
                  size: 40,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _proxyStatusColor(bool? ready, bool connected) {
    if (!connected) return Colors.grey;
    if (ready == null) return const Color(0xFFFFA502);
    return ready ? const Color(0xFF2ED573) : const Color(0xFFFF4757);
  }

  String _proxyStatusText(bool? ready, bool connected) {
    if (!connected) return 'Connect first';
    if (ready == null) return 'Not tested';
    return ready ? 'Ready' : 'Not listening';
  }

  Widget _buildProxyModeCard() {
    final endpoints = _proxyEndpointsForCurrentCore();
    final connected = _status == VpnStatus.started;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFA502).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.settings_ethernet,
                      color: Color(0xFFFFA502),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Proxy Mode Endpoints',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Core: ${_coreEngine == 'singbox' ? 'sing-box' : 'xray'}',
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'In Proxy mode, Android apps do not route traffic automatically. '
                'Set proxy manually in app/system settings using these local endpoints.',
                style: TextStyle(
                  color: Colors.grey[350],
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              ...endpoints.map((endpoint) {
                final ready = _proxyEndpointStatus[endpoint.uri];
                final statusColor = _proxyStatusColor(ready, connected);
                final statusText = _proxyStatusText(ready, connected);
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  endpoint.label,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    endpoint.note,
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 11,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              endpoint.uri,
                              style: TextStyle(
                                color: Colors.grey[300],
                                fontSize: 12,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: statusColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                statusText,
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            tooltip: 'Copy endpoint',
                            onPressed: () => _copyProxyEndpoint(endpoint.uri),
                            color: const Color(0xFF00D9FF),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: connected && !_proxyProbeInProgress
                        ? _probeLocalProxyEndpoints
                        : null,
                    icon: _proxyProbeInProgress
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_find, size: 16),
                    label: Text(
                      _proxyProbeInProgress ? 'Testing...' : 'Test Local Proxy',
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _refreshRuntimeState,
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsRow() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: _StatTile(
              icon: Icons.arrow_upward,
              label: 'Upload',
              value: _stats.formattedUplink,
              total: _stats.formattedUplinkTotal,
              color: const Color(0xFF6C5CE7),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatTile(
              icon: Icons.arrow_downward,
              label: 'Download',
              value: _stats.formattedDownlink,
              total: _stats.formattedDownlinkTotal,
              color: const Color(0xFF00D9FF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTotalTrafficCard() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF2ED573).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.data_usage,
                  color: Color(0xFF2ED573),
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Traffic',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _totalTraffic.formattedTotal,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF2ED573),
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.arrow_upward,
                        size: 12,
                        color: Color(0xFF6C5CE7),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _totalTraffic.formattedUpload,
                        style: TextStyle(color: Colors.grey[400], fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.arrow_downward,
                        size: 12,
                        color: Color(0xFF00D9FF),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _totalTraffic.formattedDownload,
                        style: TextStyle(color: Colors.grey[400], fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.grey),
                onPressed: () async {
                  await widget.v2rayBox.resetTotalTraffic();
                  await _loadTraffic();
                  _snack('Total traffic reset');
                },
                tooltip: 'Reset',
                iconSize: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConfigSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Configs',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              Text(
                '${_configs.length} items',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_configs.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(Icons.cloud_off, size: 64, color: Colors.grey[600]),
                    const SizedBox(height: 16),
                    Text(
                      'No configs added',
                      style: TextStyle(color: Colors.grey[400], fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _addFromClipboard,
                      icon: const Icon(Icons.add),
                      label: const Text('Add from clipboard'),
                    ),
                  ],
                ),
              ),
            )
          else
            ...List.generate(_configs.length, (i) {
              final config = _configs[i];
              return _ConfigTile(
                config: config,
                onTap: () => _selectConfig(config),
                onPing: () => _pingConfig(config),
                onDelete: () => _deleteConfig(config),
                onViewJson: () => _viewConfigJson(config),
                onShowQr: () => _showQrCode(config),
                onShare: () => _shareConfig(config),
                onCopyLink: () => _copyLink(config),
              );
            }),
        ],
      ),
    );
  }
}

class _LocalProxyEndpoint {
  final String label;
  final String uri;
  final String note;

  const _LocalProxyEndpoint({
    required this.label,
    required this.uri,
    required this.note,
  });
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label, value, total;
  final Color color;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              'Total: $total',
              style: TextStyle(color: Colors.grey[500], fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfigTile extends StatelessWidget {
  final VpnConfig config;
  final VoidCallback onTap,
      onPing,
      onDelete,
      onViewJson,
      onShowQr,
      onShare,
      onCopyLink;

  const _ConfigTile({
    required this.config,
    required this.onTap,
    required this.onPing,
    required this.onDelete,
    required this.onViewJson,
    required this.onShowQr,
    required this.onShare,
    required this.onCopyLink,
  });

  @override
  Widget build(BuildContext context) {
    final isPinging = config.ping == -2;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: config.isSelected
                ? Border.all(color: const Color(0xFF6C5CE7), width: 2)
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _protocolColor(config.protocol).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    config.protocol.substring(0, 1).toUpperCase(),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _protocolColor(config.protocol),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      config.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      config.protocolDisplayName,
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (isPinging)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _pingColor(config.ping).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    config.pingDisplay,
                    style: TextStyle(
                      color: _pingColor(config.ping),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: Colors.grey[400]),
                onSelected: (v) {
                  switch (v) {
                    case 'ping':
                      onPing();
                    case 'json':
                      onViewJson();
                    case 'qr':
                      onShowQr();
                    case 'share':
                      onShare();
                    case 'copy':
                      onCopyLink();
                    case 'delete':
                      onDelete();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'ping',
                    child: ListTile(
                      leading: Icon(Icons.speed),
                      title: Text('Ping'),
                      dense: true,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'json',
                    child: ListTile(
                      leading: Icon(Icons.code),
                      title: Text('View / Edit JSON'),
                      dense: true,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'qr',
                    child: ListTile(
                      leading: Icon(Icons.qr_code),
                      title: Text('Show QR Code'),
                      dense: true,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'share',
                    child: ListTile(
                      leading: Icon(Icons.share),
                      title: Text('Share'),
                      dense: true,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'copy',
                    child: ListTile(
                      leading: Icon(Icons.copy),
                      title: Text('Copy Link'),
                      dense: true,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete, color: Colors.red),
                      title: Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                      dense: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _protocolColor(String p) {
    switch (p.toLowerCase()) {
      case 'vmess':
        return const Color(0xFF6C5CE7);
      case 'vless':
        return const Color(0xFF00D9FF);
      case 'trojan':
        return const Color(0xFFFFA502);
      case 'ss':
        return const Color(0xFF2ED573);
      case 'hysteria2':
        return const Color(0xFFE84393);
      case 'tuic':
        return const Color(0xFFFD79A8);
      case 'wireguard':
        return const Color(0xFF00B894);
      default:
        return Colors.grey;
    }
  }

  Color _pingColor(int ping) {
    if (ping < 0) return Colors.grey;
    if (ping < 100) return const Color(0xFF2ED573);
    if (ping < 300) return const Color(0xFFFFA502);
    return const Color(0xFFE74C3C);
  }
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code'),
        backgroundColor: Colors.transparent,
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_scanned) return;
          final barcode = capture.barcodes.firstOrNull;
          if (barcode?.rawValue != null) {
            _scanned = true;
            Navigator.pop(context, barcode!.rawValue);
          }
        },
      ),
    );
  }
}
