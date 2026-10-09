import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'src/app.dart';
import 'src/core/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Clean URLs on the web (/app/tickets/12); the server rewrites unknown
  // paths to index.html (see docs/deployment-cpanel.md).
  usePathUrlStrategy();
  final services = AppServices.create();
  runApp(MspAssistApp(services: services));
  services.auth.restore();
}
