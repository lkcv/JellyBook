import 'package:flutter/material.dart';

/// A selectable action in the shared series/volume bottom sheet.
///
/// The caller decides which actions are available. For example, a downloaded
/// volume can expose Delete download instead of Download volume.
class ItemSheetAction<T> {
  const ItemSheetAction({
    required this.value,
    required this.label,
    required this.icon,
    this.subtitle,
    this.destructive = false,
  });

  final T value;
  final String label;
  final IconData icon;
  final String? subtitle;
  final bool destructive;
}

/// Present series or volume actions using the same bottom-sheet layout.
///
/// Returns the selected value after the sheet closes. The caller owns the
/// operation (including any confirmation, DownloadQueue work, or database
/// updates), so no asynchronous work runs inside the sheet itself.
Future<T?> showItemActionSheet<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<ItemSheetAction<T>> actions,
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.75,
    ),
    builder: (sheetContext) => _ItemActionSheet<T>(
      title: title,
      subtitle: subtitle,
      actions: actions,
    ),
  );
}

class _ItemActionSheet<T> extends StatelessWidget {
  const _ItemActionSheet({
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  final String title;
  final String? subtitle;
  final List<ItemSheetAction<T>> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleMedium,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            for (final action in actions)
              ListTile(
                leading: Icon(
                  action.icon,
                  color: action.destructive
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
                title: Text(
                  action.label,
                  style: action.destructive
                      ? TextStyle(color: scheme.error)
                      : null,
                ),
                subtitle: action.subtitle == null
                    ? null
                    : Text(action.subtitle!),
                onTap: () => Navigator.of(context).pop<T>(action.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
