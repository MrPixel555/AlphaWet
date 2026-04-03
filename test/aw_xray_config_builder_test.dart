import 'package:aw_manager_ui/models/runtime_settings.dart';
import 'package:aw_manager_ui/services/aw_payload_parser.dart';
import 'package:aw_manager_ui/services/aw_xray_builder_exception.dart';
import 'package:aw_manager_ui/services/aw_xray_config_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AwXrayConfigBuilder', () {
    test('builds full Xray JSON from VLESS REALITY URI profile', () {
      final AwPayloadParser parser = AwPayloadParser();
      final AwXrayConfigBuilder builder = AwXrayConfigBuilder();
      const String uri = 'vless://c8c96485-e6b4-4f23-99ca-c632428a4de2@94.183.175.126:443?security=reality&encryption=none&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com&pbk=test-public-key&sid=6ba85179&fp=chrome#Main-Out';

      final parsed = parser.parse(uri, isSecureEnvelope: false);
      final built = builder.build(parsed.profile);
      final outbound = (built.config['outbounds'] as List<Object>).first as Map<String, dynamic>;
      final streamSettings = outbound['streamSettings'] as Map<String, dynamic>;
      final realitySettings = streamSettings['realitySettings'] as Map<String, dynamic>;
      final settings = outbound['settings'] as Map<String, dynamic>;
      final vnext = (settings['vnext'] as List<Object>).first as Map<String, dynamic>;
      final users = (vnext['users'] as List<Object>).first as Map<String, dynamic>;

      expect(outbound['protocol'], 'vless');
      expect(vnext['address'], '94.183.175.126');
      expect(vnext['port'], 443);
      expect(users['id'], 'c8c96485-e6b4-4f23-99ca-c632428a4de2');
      expect(users['flow'], 'xtls-rprx-vision');
      expect(streamSettings['network'], 'tcp');
      expect(streamSettings['security'], 'reality');
      expect(realitySettings['serverName'], 'www.cloudflare.com');
      expect(realitySettings['publicKey'], 'test-public-key');
      expect(realitySettings['shortId'], '6ba85179');
      expect(built.prettyJson, contains('"outbounds"'));
    });

    test('uses configured local HTTP and SOCKS ports', () {
      final AwPayloadParser parser = AwPayloadParser();
      final AwXrayConfigBuilder builder = AwXrayConfigBuilder();
      const String json = '{"protocol":"vless","settings":{"vnext":[{"address":"example.com","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}]}]},"streamSettings":{"security":"tls","network":"ws","tlsSettings":{"serverName":"cdn.example.com","allowInsecure":false},"wsSettings":{"path":"/ws"}}}';

      final parsed = parser.parse(json, isSecureEnvelope: false);
      final built = builder.build(
        parsed.profile,
        runtimeSettings: const RuntimeSettings(httpPort: 18080, socksPort: 19090),
      );
      final inbounds = built.config['inbounds'] as List<Object>;
      final socksInbound = inbounds.first as Map<String, dynamic>;
      final httpInbound = inbounds[1] as Map<String, dynamic>;

      expect(socksInbound['port'], 19090);
      expect(httpInbound['port'], 18080);
    });

    test('builds tlsSettings from dedicated tls fields', () {
      final AwPayloadParser parser = AwPayloadParser();
      final AwXrayConfigBuilder builder = AwXrayConfigBuilder();
      const String json = '{"protocol":"vless","settings":{"vnext":[{"address":"example.com","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}]}]},"streamSettings":{"security":"tls","network":"ws","tlsSettings":{"serverName":"cdn.example.com","allowInsecure":false},"wsSettings":{"path":"/ws"}}}';

      final parsed = parser.parse(json, isSecureEnvelope: false);
      final built = builder.build(parsed.profile);
      final outbound = (built.config['outbounds'] as List<Object>).first as Map<String, dynamic>;
      final streamSettings = outbound['streamSettings'] as Map<String, dynamic>;
      final tlsSettings = streamSettings['tlsSettings'] as Map<String, dynamic>;

      expect(streamSettings['security'], 'tls');
      expect(tlsSettings['serverName'], 'cdn.example.com');
      expect(tlsSettings['allowInsecure'], isFalse);
    });

    test('throws when REALITY publicKey is missing', () {
      final AwPayloadParser parser = AwPayloadParser();
      final AwXrayConfigBuilder builder = AwXrayConfigBuilder();
      const String uri = 'vless://c8c96485-e6b4-4f23-99ca-c632428a4de2@94.183.175.126:443?security=reality&encryption=none&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com&sid=6ba85179#Main-Out';

      final parsed = parser.parse(uri, isSecureEnvelope: false);

      expect(
        () => builder.build(parsed.profile),
        throwsA(isA<AwXrayBuilderException>()),
      );
    });
  });
}
