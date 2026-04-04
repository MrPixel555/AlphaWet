import 'dart:convert';

import '../models/aw_profile_models.dart';
import '../models/aw_xray_models.dart';
import '../models/runtime_settings.dart';
import 'app_logger.dart';
import 'aw_xray_builder_exception.dart';

class AwXrayConfigBuilder {
  AwXrayConfigBuilder({AppLogger? logger}) : _logger = logger ?? AppLogger.instance;

  final AppLogger _logger;
  static const String _tag = 'AwXrayConfigBuilder';

  AwXrayBuildResult build(
    AwConnectionProfile profile, {
    RuntimeSettings runtimeSettings = RuntimeSettings.defaults,
  }) {
    _logger.info(
      _tag,
      'Building Xray config. protocol=${profile.protocol}, security=${profile.security}, network=${profile.network}',
    );

    _validateProfile(profile);

    final String outboundTag = _sanitizeTag(profile.displayName);
    final Map<String, dynamic> outbound = _buildPrimaryOutbound(
      profile: profile,
      outboundTag: outboundTag,
    );

    final List<Object> inbounds = <Object>[
      if (runtimeSettings.enableDeviceVpn)
        <String, dynamic>{
          'tag': 'tun-in',
          'port': 0,
          'protocol': 'tun',
          'settings': <String, dynamic>{
            'name': 'alphawet',
            'MTU': 1500,
          },
          'sniffing': <String, dynamic>{
            'enabled': true,
            'destOverride': <String>['http', 'tls', 'quic'],
          },
        },
      <String, dynamic>{
        'tag': 'socks-in',
        'listen': '127.0.0.1',
        'port': runtimeSettings.socksPort,
        'protocol': 'socks',
        'settings': <String, dynamic>{
          'udp': true,
          'auth': 'noauth',
        },
        'sniffing': <String, dynamic>{
          'enabled': true,
          'destOverride': <String>['http', 'tls', 'quic'],
        },
      },
      <String, dynamic>{
        'tag': 'http-in',
        'listen': '127.0.0.1',
        'port': runtimeSettings.httpPort,
        'protocol': 'http',
        'settings': <String, dynamic>{},
        'sniffing': <String, dynamic>{
          'enabled': true,
          'destOverride': <String>['http', 'tls'],
        },
      },
    ];

    final List<Object> routingRules = <Object>[
      <String, dynamic>{
        'type': 'field',
        'protocol': <String>['bittorrent'],
        'outboundTag': 'block',
      },
      if (runtimeSettings.enableDeviceVpn)
        <String, dynamic>{
          'type': 'field',
          'ip': <String>['geoip:private'],
          'outboundTag': 'direct',
        },
    ];

    final Map<String, dynamic> config = <String, dynamic>{
      'awManagerRuntime': <String, dynamic>{
        'httpPort': runtimeSettings.httpPort,
        'socksPort': runtimeSettings.socksPort,
        'deviceVpnRequested': runtimeSettings.enableDeviceVpn,
      },
      'log': <String, dynamic>{
        'loglevel': 'warning',
      },
      'dns': <String, dynamic>{
        'servers': <Object>[
          '1.1.1.1',
          '8.8.8.8',
          'localhost',
        ],
        'queryStrategy': 'UseIP',
      },
      'inbounds': inbounds,
      'outbounds': <Object>[
        outbound,
        <String, dynamic>{
          'tag': 'direct',
          'protocol': 'freedom',
          'settings': <String, dynamic>{},
        },
        <String, dynamic>{
          'tag': 'block',
          'protocol': 'blackhole',
          'settings': <String, dynamic>{},
        },
      ],
      'policy': <String, dynamic>{
        'levels': <String, dynamic>{
          '0': <String, dynamic>{
            'handshake': 4,
            'connIdle': 300,
            'uplinkOnly': 2,
            'downlinkOnly': 5,
          },
        },
      },
      'routing': <String, dynamic>{
        'domainStrategy': 'IPIfNonMatch',
        'rules': routingRules,
      },
    };

    final JsonEncoder encoder = const JsonEncoder.withIndent('  ');
    final String prettyJson = encoder.convert(config);

    _logger.info(
      _tag,
      'Xray config ready. outboundTag=$outboundTag, bytes=${prettyJson.length}',
    );

    return AwXrayBuildResult(
      config: config,
      prettyJson: prettyJson,
      primaryOutboundTag: outboundTag,
    );
  }

  void _validateProfile(AwConnectionProfile profile) {
    if (profile.protocol.toLowerCase() != 'vless') {
      throw AwXrayBuilderException(
        'Unsupported protocol "${profile.protocol}". This build currently supports VLESS only.',
      );
    }

    if (profile.host.trim().isEmpty || profile.host.trim() == '-') {
      throw const AwXrayBuilderException('Profile host is missing.');
    }

    if (profile.port == null || profile.port! <= 0 || profile.port! > 65535) {
      throw const AwXrayBuilderException('Profile port is invalid.');
    }

    if (!_hasText(profile.userId)) {
      throw const AwXrayBuilderException('VLESS profile requires a user UUID/id.');
    }

    final String security = profile.security.toLowerCase();
    if (!_supportedSecurity.contains(security)) {
      throw AwXrayBuilderException(
        'Unsupported security "$security". Supported: ${_supportedSecurity.join(', ')}.',
      );
    }

    final String network = profile.network.toLowerCase();
    if (!_supportedNetworks.contains(network)) {
      throw AwXrayBuilderException(
        'Unsupported network "$network". Supported: ${_supportedNetworks.join(', ')}.',
      );
    }

    if (security == 'reality') {
      final AwRealitySettings? reality = profile.reality;
      if (reality == null) {
        throw const AwXrayBuilderException('REALITY security selected but no reality settings exist.');
      }
      if (!_hasText(reality.serverName)) {
        throw const AwXrayBuilderException('REALITY requires serverName/SNI.');
      }
      if (!_hasText(reality.publicKey)) {
        throw const AwXrayBuilderException('REALITY requires publicKey/pbk.');
      }
    }
  }

  Map<String, dynamic> _buildPrimaryOutbound({
    required AwConnectionProfile profile,
    required String outboundTag,
  }) {
    final Map<String, dynamic> user = <String, dynamic>{
      'id': profile.userId,
      'encryption': _normalizeOrDefault(profile.encryption, 'none'),
    };
    if (_hasText(profile.flow)) {
      user['flow'] = profile.flow;
    }

    return <String, dynamic>{
      'tag': outboundTag,
      'protocol': 'vless',
      'settings': <String, dynamic>{
        'vnext': <Object>[
          <String, dynamic>{
            'address': profile.host,
            'port': profile.port,
            'users': <Object>[user],
          },
        ],
      },
      'streamSettings': _buildStreamSettings(profile),
      'mux': <String, dynamic>{
        'enabled': false,
        'concurrency': -1,
      },
    };
  }

  Map<String, dynamic> _buildStreamSettings(AwConnectionProfile profile) {
    final String network = profile.network.toLowerCase();
    final String security = profile.security.toLowerCase();
    final Map<String, dynamic> streamSettings = <String, dynamic>{
      'network': network,
      'security': security == 'none' ? 'none' : security,
    };

    switch (network) {
      case 'ws':
        streamSettings['wsSettings'] = <String, dynamic>{
          'path': _normalizeOrDefault(profile.transport.path, '/'),
          if (_hasText(profile.transport.host))
            'headers': <String, dynamic>{
              'Host': profile.transport.host,
            },
        };
        break;
      case 'grpc':
        streamSettings['grpcSettings'] = <String, dynamic>{
          'serviceName': _normalizeOrDefault(profile.transport.serviceName, 'grpc'),
          if (_hasText(profile.transport.authority)) 'authority': profile.transport.authority,
          if (_hasText(profile.transport.mode)) 'multiMode': profile.transport.mode == 'multi',
        };
        break;
      case 'http':
        streamSettings['httpSettings'] = <String, dynamic>{
          'path': _normalizeOrDefault(profile.transport.path, '/'),
          if (_hasText(profile.transport.host)) 'host': <String>[profile.transport.host!],
        };
        break;
      case 'tcp':
      default:
        if (_hasText(profile.transport.headerType) && profile.transport.headerType != 'none') {
          streamSettings['tcpSettings'] = <String, dynamic>{
            'header': <String, dynamic>{
              'type': profile.transport.headerType,
            },
          };
        }
        break;
    }

    switch (security) {
      case 'reality':
        final AwRealitySettings reality = profile.reality!;
        streamSettings['realitySettings'] = <String, dynamic>{
          'show': false,
          'serverName': reality.serverName,
          'fingerprint': _normalizeOrDefault(reality.fingerprint, 'chrome'),
          'publicKey': reality.publicKey,
          if (_hasText(reality.shortId)) 'shortId': reality.shortId,
          if (_hasText(reality.spiderX)) 'spiderX': reality.spiderX else 'spiderX': '/',
        };
        break;
      case 'tls':
        final AwTlsSettings? tls = profile.tls;
        streamSettings['tlsSettings'] = <String, dynamic>{
          if (_hasText(tls?.serverName)) 'serverName': tls!.serverName,
          'allowInsecure': tls?.allowInsecure ?? false,
        };
        break;
      case 'none':
      default:
        break;
    }

    return streamSettings;
  }

  String _sanitizeTag(String value) {
    final String normalized = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    if (normalized.isEmpty) {
      return 'proxy-main';
    }
    return normalized.toLowerCase();
  }

  String _normalizeOrDefault(String? value, String fallback) {
    if (!_hasText(value)) {
      return fallback;
    }
    return value!.trim();
  }

  bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

  static const Set<String> _supportedSecurity = <String>{
    'none',
    'tls',
    'reality',
  };

  static const Set<String> _supportedNetworks = <String>{
    'tcp',
    'ws',
    'grpc',
    'http',
  };
}
