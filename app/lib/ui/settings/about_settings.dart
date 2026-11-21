import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../state/providers.dart';
import '../theme/hanashi_theme.dart';
import '../widgets/links.dart';

/// Hanashi's own repository: the app's source code.
final hanashiSource = Uri.parse('https://github.com/N1kO23/Hanashi');

const _copyright = 'Copyright © 2026 Niko Huuskonen';

/// This app's version, as its builds name it: "0.9.0 (123)".
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.buildNumber.isEmpty ? info.version : '${info.version} (${info.buildNumber})';
});

/// What the app is, under which license, and where its source code is; and
/// the same of the server: the notices the AGPL asks for, the server's
/// because the user reaches it only through the app.
class AboutSettings extends ConsumerWidget {
  const AboutSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider).value;
    final server = ref.watch(serverInfoProvider).value;
    final serverSource = server?.source;
    final secondary = context.palette.textSecondary;
    return Column(
      children: [
        ListTile(
          key: const Key('about-app'),
          leading: Icon(Icons.info_outline, color: secondary),
          title: Text(version == null ? context.appName : '${context.appName} $version'),
          subtitle: const Text(
            '$_copyright. Hanashi is free software: you may share and change it under the terms of the '
            'GNU Affero General Public License, version 3. It comes with no warranty.',
          ),
        ),
        ListTile(
          key: const Key('about-source'),
          leading: Icon(Icons.code, color: secondary),
          title: const Text('Source code'),
          subtitle: Text('$hanashiSource'),
          onTap: () => openLink(context, ref, hanashiSource),
        ),
        ListTile(
          key: const Key('about-licenses'),
          leading: Icon(Icons.gavel_outlined, color: secondary),
          title: const Text('Licenses'),
          subtitle: const Text("Hanashi's, and those of the software it is made with"),
          onTap: () => showLicenses(context, version: version),
        ),
        if (server != null)
          ListTile(
            key: const Key('about-server'),
            leading: Icon(Icons.dns_outlined, color: secondary),
            title: Text('Your server, ${server.host}'),
            subtitle: Text(
              serverSource == null
                  ? 'Hanashi server ${server.version}. It does not say where its source code is.'
                  : 'Hanashi server ${server.version}. Its source code: $serverSource',
            ),
            onTap: serverSource == null ? null : () => openLink(context, ref, serverSource),
          ),
      ],
    );
  }
}

/// Shows the licenses of the app and of what it is made with, Hanashi's
/// first.
void showLicenses(BuildContext context, {String? version}) {
  _addOwnLicense();
  showLicensePage(
    context: context,
    // The license page puts the package of this name first.
    applicationName: 'Hanashi',
    applicationVersion: version,
    applicationLegalese: '$_copyright\nGNU Affero General Public License, version 3',
  );
}

var _ownLicenseAdded = false;

/// Adds the app's own license (assets/LICENSE) to those Flutter collects
/// from the packages: the one copy of it that phones get.
void _addOwnLicense() {
  if (_ownLicenseAdded) return;
  _ownLicenseAdded = true;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const ['Hanashi'], await rootBundle.loadString('assets/LICENSE'));
  });
}
