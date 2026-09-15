import 'package:flutter/material.dart';

import 'demo_controller.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xff10243e);
    const cream = Color(0xfffffbf2);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Dawn Dock companion',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: navy,
          brightness: Brightness.light,
          surface: cream,
        ),
        scaffoldBackgroundColor: cream,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        visualDensity: VisualDensity.standard,
        textTheme: const TextTheme(
          headlineSmall: TextStyle(fontWeight: FontWeight.w700, color: navy),
          titleMedium: TextStyle(fontWeight: FontWeight.w700, color: navy),
          bodyMedium: TextStyle(color: Color(0xff26384e)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
      ),
      home: const DemoHomePage(),
    );
  }
}

class DemoHomePage extends StatefulWidget {
  const DemoHomePage({super.key});

  @override
  State<DemoHomePage> createState() => _DemoHomePageState();
}

class _DemoHomePageState extends State<DemoHomePage> {
  final DemoController _controller = DemoController();
  bool _reviewing = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dawn Dock companion')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Offline demo • Fake device',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('No real clock is connected.'),
                  const Text('No alarms are executed by this demo.'),
                  const SizedBox(height: 20),
                  const _InfoCard(
                    title: 'Fake device status',
                    semanticsLabel: 'Fake device status: simulated offline',
                    lines: ['Connection: Simulated offline'],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 12),
                    child: Text('Schedule revision: ${_controller.revision}'),
                  ),
                  const SizedBox(height: 12),
                  _InfoCard(
                    title: 'Next alarm sample',
                    semanticsLabel:
                        'Next alarm sample: ${_controller.schedule.replaceFirst('Weekdays', 'weekdays')}, illustrative only',
                    lines: [
                      _controller.schedule,
                      'Illustrative sample — not the current time',
                    ],
                  ),
                  const SizedBox(height: 20),
                  FocusTraversalGroup(
                    key: const ValueKey('demo-actions'),
                    policy: OrderedTraversalPolicy(),
                    child: AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      child: _controller.hasReceipt
                          ? Column(
                              key: const ValueKey('receipt'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _InfoCard(
                                  title: 'Demo-only revision receipt',
                                  lines: [
                                    'Applied fake revision ${_controller.revision}',
                                    'Nothing was sent to real hardware.',
                                  ],
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: () => setState(() {
                                    _controller.reset();
                                    _reviewing = false;
                                  }),
                                  icon: const Icon(Icons.restart_alt),
                                  label: const Text('Reset demo'),
                                ),
                              ],
                            )
                          : _reviewing
                          ? Column(
                              key: const ValueKey('review'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _InfoCard(
                                  title: 'Review illustrative change',
                                  lines: [
                                    'Current: ${_controller.schedule}',
                                    'Proposed: Weekdays at 7:30 AM',
                                    'This preview changes only in-memory fake state.',
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  alignment: WrapAlignment.end,
                                  children: [
                                    OutlinedButton(
                                      onPressed: () =>
                                          setState(() => _reviewing = false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () => setState(() {
                                        _controller.applySampleChange();
                                        _reviewing = false;
                                      }),
                                      child: const Text('Apply to fake device'),
                                    ),
                                  ],
                                ),
                              ],
                            )
                          : FilledButton.icon(
                              key: const ValueKey('idle'),
                              onPressed: () =>
                                  setState(() => _reviewing = true),
                              icon: const Icon(Icons.rate_review_outlined),
                              label: const Text('Review sample change'),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.lines,
    this.semanticsLabel,
  });

  final String title;
  final List<String> lines;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      container: semanticsLabel != null,
      excludeSemantics: semanticsLabel != null,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(line),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
