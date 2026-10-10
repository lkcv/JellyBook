import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jellybook/providers/readerPageCache.dart';
import 'package:jellybook/widgets/jellybookImageCache.dart';

/// Storage controls for the durable, seven-page snapshots retained by the
/// reader. This intentionally does not count or delete downloaded volumes.
class ReaderCacheSettings extends StatefulWidget {
  const ReaderCacheSettings({super.key});

  @override
  State<ReaderCacheSettings> createState() => _ReaderCacheSettingsState();
}

class _ReaderCacheSettingsState extends State<ReaderCacheSettings> {
  int _usageBytes = 0;
  int _coverUsageBytes = 0;
  int _limitMb = ReaderPageCache.defaultLimitMb;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final limit = await ReaderPageCache.getLimitMb();
      final usage = await ReaderPageCache.getUsageBytes();
      final coverUsage = await JellyBookCacheManager.getUsageBytes();
      if (!mounted) return;
      setState(() {
        _limitMb = limit;
        _usageBytes = usage;
        _coverUsageBytes = coverUsage;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read cache usage: $error';
      });
    }
  }

  String _displayMb(int bytes) {
    final mb = bytes / (1024 * 1024);
    return mb < 10 ? mb.toStringAsFixed(1) : mb.toStringAsFixed(0);
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm({
    required String title,
    required String description,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(description),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Clear'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _clearReaderCache() async {
    if (_busy ||
        !await _confirm(
          title: 'Clear reader page cache?',
          description: 'Remove cached pages from previously opened volumes. '
              'Downloaded volumes and covers will not be deleted.',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await ReaderPageCache.clearCache();
      await _refresh();
      _notify('Reader page cache cleared');
    } catch (error) {
      _notify('Could not clear reader cache: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearCovers() async {
    if (_busy ||
        !await _confirm(
          title: 'Clear cover cache?',
          description: 'Remove downloaded covers and cached profile images. '
              'These images will be fetched again when needed.',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await JellyBookCacheManager.instance.emptyCache();
      await _refresh();
      _notify('Cover cache cleared');
    } catch (error) {
      _notify('Could not clear cover cache: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editLimit() async {
    if (_busy) return;
    final selectedLimit = await showDialog<int>(
      context: context,
      builder: (context) => _CacheLimitDialog(initialLimitMb: _limitMb),
    );
    if (!mounted || selectedLimit == null || selectedLimit == _limitMb) return;
    setState(() => _busy = true);
    try {
      await ReaderPageCache.setLimitMb(selectedLimit);
      await _refresh();
      _notify('Reader cache limit updated');
    } catch (error) {
      _notify('Could not update reader cache limit: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maximumBytes = _limitMb * 1024 * 1024;
    final usageFraction = maximumBytes > 0
        ? (_usageBytes / maximumBytes).clamp(0.0, 1.0).toDouble()
        : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Storage & cache',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 14),
            Text('Reader page cache',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              'Seven nearby pages per recently opened volume',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_loading)
              const LinearProgressIndicator()
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('${_displayMb(_usageBytes)} MB of'),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _editLimit,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: Text('$_limitMb MB'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: usageFraction),
                ],
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : _clearReaderCache,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear reader cache'),
              ),
            ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text('Cover image cache',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (!_loading)
                  Text('${_displayMb(_coverUsageBytes)} MB used',
                      style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
            Text(
              'Covers and profile images are stored separately',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : _clearCovers,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear covers'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Owns its input controller for the entire dialog route lifetime, including
/// the dismissal animation. The custom number remains visible in default mode.
class _CacheLimitDialog extends StatefulWidget {
  final int initialLimitMb;

  const _CacheLimitDialog({required this.initialLimitMb});

  @override
  State<_CacheLimitDialog> createState() => _CacheLimitDialogState();
}

class _CacheLimitDialogState extends State<_CacheLimitDialog> {
  late final TextEditingController _controller;
  final FocusNode _numberFocus = FocusNode();
  late bool _custom;

  @override
  void initState() {
    super.initState();
    _custom = widget.initialLimitMb != ReaderPageCache.defaultLimitMb;
    _controller = TextEditingController(
      text: widget.initialLimitMb.toString(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _numberFocus.dispose();
    super.dispose();
  }

  void _selectCustom({bool focusNumber = true}) {
    if (!_custom) setState(() => _custom = true);
    if (focusNumber) {
      _numberFocus.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final customMb = int.tryParse(_controller.text);
    final validCustom = customMb != null &&
        customMb > 0 &&
        customMb <= ReaderPageCache.maxCustomLimitMb;
    return AlertDialog(
      scrollable: true,
      title: const Text('Maximum reader cache size'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _custom = false),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Radio<bool>(
                    value: false,
                    groupValue: _custom,
                    onChanged: (_) => setState(() => _custom = false),
                  ),
                  const Expanded(child: Text('300 MB (default)')),
                ],
              ),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _selectCustom(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Radio<bool>(
                    value: true,
                    groupValue: _custom,
                    onChanged: (_) => _selectCustom(),
                  ),
                  const Text('Custom'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _numberFocus,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 10,
                        ),
                      ),
                      onTap: () => _selectCustom(focusNumber: false),
                      onChanged: (_) => setState(() => _custom = true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('MB'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Reducing the limit evicts the least recently used '
            'cached volumes. Downloads are unaffected.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_custom && !validCustom)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Enter a positive whole number of MB.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _custom && !validCustom
              ? null
              : () => Navigator.pop(
                    context,
                    _custom ? customMb : ReaderPageCache.defaultLimitMb,
                  ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
