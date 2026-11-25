import 'package:flutter/material.dart';

import 'release_info.dart';
import 'translations.dart';

class ReleaseNotesButton extends StatelessWidget {
  const ReleaseNotesButton({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appLanguage,
    builder: (context, _) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: TextButton(
        key: const ValueKey('workspace-release-notes'),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const ReleaseNotesDialog(),
        ),
        child: Text(
          '${applicationVersion == 'development' ? tr('Development build') : 'v$applicationVersion'} · ${tr('Recent updates')}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
  );
}

class ReleaseNotesDialog extends StatelessWidget {
  const ReleaseNotesDialog({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: appLanguage,
    builder: (context, _) => AlertDialog(
      title: const LText('Recent updates'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              trf('Current version: {version}', {
                'version': applicationVersion == 'development'
                    ? tr('Development build')
                    : applicationVersion,
              }),
            ),
            for (final release in recentReleases) ...[
              const SizedBox(height: 20),
              Text(
                'v${release.version}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final change
                  in appLanguage.value == 'zh_CN'
                      ? release.chinese
                      : release.english)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('• $change'),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const LText('Close'),
        ),
      ],
    ),
  );
}
