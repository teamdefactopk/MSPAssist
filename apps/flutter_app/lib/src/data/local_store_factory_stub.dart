import 'local_store.dart';

/// Flutter Web: native SQLite is unavailable, and keeping client data out of
/// browser storage is safer on shared computers, so the cache lives in memory
/// for the lifetime of the tab.
LocalStore createLocalStore() => MemoryLocalStore();
