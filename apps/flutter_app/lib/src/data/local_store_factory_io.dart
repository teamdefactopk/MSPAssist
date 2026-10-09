import 'local_store.dart';
import 'sqlite_local_store.dart';

LocalStore createLocalStore() => SqliteLocalStore();
