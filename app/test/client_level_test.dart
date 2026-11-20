import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hanashi/data/remote/api_client.dart';
import 'package:hanashi_protocol/hanashi_protocol.dart';

void main() {
  test('every request says the client level, signed in or not', () async {
    final seen = <String?>[];
    final client = MockClient((request) async {
      seen.add(request.headers[clientLevelHeader]);
      return http.Response('{"host":"a.example","version":"1","registration":"open","maxUploadBytes":1}', 200);
    });
    await ApiClient('http://server', client: client).serverInfo();
    await ApiClient('http://server', token: 't', client: client).serverInfo();
    expect(seen, ['$clientLevel', '$clientLevel']);
  });

  test('a refusal for being too old can be retried after updating', () async {
    final client = MockClient(
      (_) async => http.Response('{"error":"client_too_old","message":"Update the app"}', 426),
    );
    final error = await ApiClient('http://server', client: client)
        .serverInfo()
        .then<ApiException>((_) => fail('not refused'), onError: (Object e) => e as ApiException);
    expect(error.isClientTooOld, isTrue);
    expect(error.isPermanent, isFalse, reason: 'permanent would mark waiting messages as failed');
    expect(error.isUnauthorized, isFalse);
    expect(error.toString(), 'Update the app');
  });
}
