import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../state/providers.dart';

/// Opens [url] in the browser; tells the user if it could not.
Future<void> openLink(BuildContext context, WidgetRef ref, Uri url) async {
  bool opened;
  try {
    opened = await ref.read(openLinkProvider)(url);
  } on PlatformException {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $url')));
  }
}

/// Opens [url] once the user agrees, having seen the address: for links that
/// do not show it, like a link card, which says what the sender's app made of
/// the link and so need not match where it leads.
Future<void> confirmOpenLink(BuildContext context, WidgetRef ref, Uri url) async {
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('open-link-dialog'),
      title: const Text('Open this link?'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(linkHost('$url'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text(
              '$url',
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          key: const Key('open-link-confirm'),
          autofocus: true,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if ((open ?? false) && context.mounted) await openLink(context, ref, url);
}

/// The host of [url] as people say it: without "www.".
String linkHost(String url) {
  final host = Uri.tryParse(url)?.host ?? url;
  return host.startsWith('www.') ? host.substring(4) : host;
}
