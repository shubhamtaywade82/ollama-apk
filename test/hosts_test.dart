import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ollama_app/worker/hosts.dart';
import 'package:shared_preferences/shared_preferences.dart';

const local = OllamaHost(name: 'laptop', url: 'http://192.168.1.5:11434');
const router = OllamaHost(name: 'router', url: 'http://192.168.1.5:8080');
const cloud = OllamaHost(name: 'cloud', url: 'https://ollama.com');

MockClient fakeServers(Map<String, http.Response> byUrl) =>
    MockClient((req) async =>
        byUrl[req.url.toString()] ?? (throw http.ClientException('refused')));

void main() {
  test('should migrate legacy single host when no host list saved', () async {
    SharedPreferences.setMockInitialValues({'host': 'http://10.0.0.2:11434'});
    final prefs = await SharedPreferences.getInstance();
    final hosts = loadHosts(prefs);
    expect(hosts.single.url, 'http://10.0.0.2:11434');
  });

  test('should replace host with same url when upserting', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await upsertHost(prefs, local);
    await upsertHost(prefs, router);
    final hosts = await upsertHost(prefs,
        const OllamaHost(name: 'renamed', url: 'http://192.168.1.5:11434'));
    expect(hosts.map((h) => h.name), ['renamed', 'router']);
    expect((await removeHost(prefs, router.url)).length, 1);
  });

  test('should report up for running local and authorized cloud', () async {
    final client = fakeServers({
      'http://192.168.1.5:11434': http.Response('Ollama is running', 200),
      'https://ollama.com/api/tags': http.Response('{"models":[]}', 200),
    });
    expect((await pingHost(local, client)).isUp, isTrue);
    expect((await pingHost(cloud, client)).isUp, isTrue);
  });

  test('should report down when unreachable or unauthorized', () async {
    final client =
        fakeServers({'https://ollama.com/api/tags': http.Response('no', 401)});
    expect((await pingHost(local, client)).isUp, isFalse);
    expect((await pingHost(cloud, client)).error, 'unauthorized');
  });

  test('should fail over to next healthy host and activate it', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await saveHosts(prefs, [local, router, cloud]);
    final client = fakeServers({
      'https://ollama.com/api/tags': http.Response('{"models":[]}', 200),
    });
    final next = await failoverFrom(prefs, client, local.url);
    expect(next?.name, 'cloud');
    expect(prefs.getString('host'), 'https://ollama.com');
  });

  test('should return null when every host is down', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await saveHosts(prefs, [local, router]);
    expect(await failoverFrom(prefs, fakeServers({}), local.url), isNull);
  });
}
