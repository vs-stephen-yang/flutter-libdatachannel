import 'package:flutter/material.dart';

import 'modes/receive_dump_page.dart';
import 'modes/playback_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_libdatachannel Example',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const MainShell(),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _receiveDumpKey = GlobalKey<ReceiveDumpPageState>();
  final _playbackKey = GlobalKey<PlaybackPageState>();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) return;
    // Reset the tab we're leaving
    switch (_tabController.previousIndex) {
      case 0:
        _receiveDumpKey.currentState?.reset();
        break;
      case 1:
        _playbackKey.currentState?.reset();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('flutter_libdatachannel'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.fiber_manual_record), text: 'Receive & Dump'),
            Tab(icon: Icon(Icons.play_circle), text: 'Playback'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          ReceiveDumpPage(key: _receiveDumpKey),
          PlaybackPage(key: _playbackKey),
        ],
      ),
    );
  }
}
