import 'package:alphawet/models/aw_profile_models.dart';
import 'package:alphawet/services/aw_payload_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AwPayloadParser', () {
    test('parses VLESS REALITY URI into normalized profile', () {
      final AwPayloadParser parser = AwPayloadParser();
      const String uri = 'vless://c8c96485-e6b4-4f23-99ca-c632428a4de2@94.183.175.126:443?security=reality&encryption=none&type=tcp&flow=xtls-rprx-vision&sni=www.cloudflare.com&pbk=test-public-key&sid=6ba85179&fp=chrome#Main-Out';

      final result = parser.parse(uri, isSecureEnvelope: false);

      expect(result.payloadKind, 'uri');
      expect(result.profile.protocol, 'vless');
      expect(result.profile.host, '94.183.175.126');
      expect(result.profile.port, 443);
      expect(result.profile.security, 'reality');
      expect(result.profile.network, 'tcp');
      expect(result.profile.flow, 'xtls-rprx-vision');
      expect(result.profile.reality, isA<AwRealitySettings>());
      expect(result.profile.reality?.serverName, 'www.cloudflare.com');
      expect(result.profile.reality?.publicKey, 'test-public-key');
      expect(result.profile.reality?.shortId, '6ba85179');
    });

    test('parses simplified JSON payload into normalized profile', () {
      final AwPayloadParser parser = AwPayloadParser();
      const String json = '{"type":"vless","address":"94.183.175.126","port":443,"uuid":"c8c96485-e6b4-4f23-99ca-c632428a4de2","flow":"xtls-rprx-vision","security":"reality","network":"tcp","reality":{"serverName":"www.cloudflare.com","publicKey":"test-public-key","shortId":"6ba85179","fingerprint":"chrome"}}';

      final result = parser.parse(json, isSecureEnvelope: true);

      expect(result.payloadKind, 'json');
      expect(result.profile.protocol, 'vless');
      expect(result.profile.host, '94.183.175.126');
      expect(result.profile.security, 'reality');
      expect(result.profile.network, 'tcp');
      expect(result.profile.reality?.serverName, 'www.cloudflare.com');
      expect(result.profile.reality?.shortId, '6ba85179');
    });

    test('parses tls serverName from tlsSettings instead of reality', () {
      final AwPayloadParser parser = AwPayloadParser();
      const String json = '{"protocol":"vless","settings":{"vnext":[{"address":"example.com","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}]}]},"streamSettings":{"security":"tls","network":"ws","tlsSettings":{"serverName":"cdn.example.com","allowInsecure":false},"wsSettings":{"path":"/ws"}}}';

      final result = parser.parse(json, isSecureEnvelope: false);

      expect(result.profile.security, 'tls');
      expect(result.profile.tls, isNotNull);
      expect(result.profile.tls?.serverName, 'cdn.example.com');
      expect(result.profile.reality, isNull);
    });
  });
}
