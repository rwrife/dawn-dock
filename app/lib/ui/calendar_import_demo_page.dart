import 'package:flutter/material.dart';

import '../domain/alarm_draft.dart';
import '../domain/ics_import.dart';

/// Local-only review of pasted calendar text. No device schedule or file access.
class CalendarImportDemoPage extends StatefulWidget {
  const CalendarImportDemoPage({super.key});

  @override
  State<CalendarImportDemoPage> createState() => _CalendarImportDemoPageState();
}

class _CalendarImportDemoPageState extends State<CalendarImportDemoPage> {
  final _input = TextEditingController();
  IcsImportResult? _result;
  String? _error;
  bool _acknowledged = false;
  List<AlarmDraft> _saved = const [];

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _invalidate() {
    if (_result != null || _error != null) {
      setState(() {
        _result = null;
        _error = null;
        _acknowledged = false;
      });
    }
  }

  void _review() {
    setState(() {
      _result = null;
      _error = null;
      _acknowledged = false;
      try {
        _result = importIcsSuggestions(_input.text);
      } on IcsImportException catch (e) {
        // Import exceptions contain only static limit/format descriptions.
        _error = e.message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar import demo')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Local calendar review',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Paste calendar text for this demo. No file picker or calendar permission. Nothing is sent to a device. No alarm was scheduled.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('calendar-input'),
              controller: _input,
              onChanged: (_) => _invalidate(),
              maxLines: 5,
              minLines: 3,
              decoration: const InputDecoration(
                labelText: 'Calendar text for local review',
                border: OutlineInputBorder(),
                helperText: 'Only UID, summary, start time and supported recurrence are retained in suggestions. Limit: 1 MiB.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _review,
              child: const Text('Review calendar suggestions'),
            ),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  'Import rejected: $_error',
                  key: const ValueKey('import-error'),
                ),
              ),
            if (result != null) ...[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  '${result.suggestions.length} suggestion${result.suggestions.length == 1 ? '' : 's'} for review. ${result.notices.length} notice${result.notices.length == 1 ? '' : 's'}. Nothing saved yet.',
                ),
              ),
              for (final suggestion in result.suggestions) ...[
                const Divider(),
                Text(
                  suggestion.label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '${suggestion.localTime} • ${_days(suggestion.days)} • ${suggestion.timezone}',
                ),
                const Text(
                  'Repeats indefinitely until edited. Calendar date/end limits are not carried into this alarm.',
                ),
              ],
              if (result.notices.isNotEmpty) ...[
                const Divider(),
                Text(
                  'Review every import notice',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final notice in result.notices)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${notice.eventNumber == null ? 'Import' : 'Event ${notice.eventNumber}'}: ${_noticeText[notice.code] ?? 'Unsupported calendar detail; inspect source before accepting.'}',
                    ),
                  ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Times are literal wall times, not converted. Check zone, daylight-saving gaps/folds, recurrence, and each suggestion before confirming. Confirmation saves only in memory; no device or alarm is changed.',
              ),
              CheckboxListTile(
                key: const ValueKey('acknowledge-import'),
                value: _acknowledged,
                onChanged: result.suggestions.isEmpty
                    ? null
                    : (value) => setState(() => _acknowledged = value ?? false),
                title: const Text(
                  'I reviewed all suggestions and notices, including time zone and recurrence changes',
                ),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton(
                    key: const ValueKey('cancel-import'),
                    onPressed: () => setState(() {
                      _result = null;
                      _acknowledged = false;
                    }),
                    child: const Text('Cancel review'),
                  ),
                  FilledButton(
                    key: const ValueKey('confirm-import'),
                    onPressed: _acknowledged && result.suggestions.isNotEmpty
                        ? () => setState(() {
                            _saved = List.unmodifiable(result.suggestions);
                            _input.clear();
                            _result = null;
                            _acknowledged = false;
                          })
                        : null,
                    child: const Text('Confirm in-memory suggestions'),
                  ),
                ],
              ),
            ],
            if (_saved.isNotEmpty) ...[
              const Divider(),
              Text(
                '${_saved.length} suggestion${_saved.length == 1 ? '' : 's'} saved in memory for this demo session. No alarm was scheduled or sent to a device.',
                key: const ValueKey('saved-notice'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _days(Set<int> days) {
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return (days.toList()..sort()).map((day) => names[day - 1]).join(', ');
}

const _noticeText = <String, String>{
  kIcsNoticeFloatingLocalTime:
      'Floating time: assumed Etc/UTC; confirm intended zone.',
  kIcsNoticeUtcWallTime:
      'UTC time kept as literal wall time; confirm zone before scheduling.',
  kIcsNoticeAllDayDefaultTime: 'All-day event defaulted to midnight.',
  kIcsNoticeIntervalNotRepresentable:
      'Unsupported recurrence interval; event dropped.',
  kIcsNoticeRecurrenceEndDropped:
      'Recurrence end was dropped; suggestion repeats indefinitely.',
  kIcsNoticeSingleOccurrenceWeekly:
      'Single occurrence expanded to repeat weekly.',
  kIcsNoticeLabelDefaulted: 'Missing title replaced with generic label.',
  kIcsNoticeLabelTruncated: 'Title shortened to fit alarm label.',
  kIcsNoticeMissingUid: 'Missing event ID; event dropped.',
  kIcsNoticeDuplicateUid: 'Duplicate event ID; suggestion ID changed.',
  kIcsNoticeOversizedUid: 'Event ID too long; event dropped.',
  kIcsNoticeInvalidDtstart: 'Invalid start time; event dropped.',
  kIcsNoticeMalformedEvent: 'Malformed event; event dropped.',
  kIcsNoticeCapacityTruncated:
      'Suggestion limit reached; later events dropped.',
  kIcsNoticeUnsupportedRecurrence: 'Unsupported recurrence; event dropped.',
  kIcsNoticeMissingTzid: 'Empty timezone; event dropped.',
  kIcsNoticeUtcTimezoneId: 'UTC timezone designator; verify local intent.',
};
