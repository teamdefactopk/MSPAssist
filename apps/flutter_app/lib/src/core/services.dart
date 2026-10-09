import '../data/local_store.dart';
import '../data/local_store_factory.dart';
import '../data/repository.dart';
import '../sync/sync_service.dart';
import 'api_client.dart';
import 'auth_controller.dart';
import 'config.dart';
import 'token_store.dart';

/// Object graph shared by the whole app.
class AppServices {
  AppServices._(this.api, this.store, this.repo, this.sync, this.auth);

  factory AppServices.create({AppConfig? config, LocalStore? store, TokenStore? tokens, ApiClient? api}) {
    final client = api ?? ApiClient(config ?? AppConfig.resolve());
    final local = store ?? createLocalStore();
    final sync = SyncService(client, local);
    final auth = AuthController(api: client, tokens: tokens ?? TokenStore(), store: local, sync: sync);
    return AppServices._(client, local, Repository(client, local), sync, auth);
  }

  final ApiClient api;
  final LocalStore store;
  final Repository repo;
  final SyncService sync;
  final AuthController auth;
}
