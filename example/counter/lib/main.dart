import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_pilot counter',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const MyHomePage(title: 'flutter_pilot demo'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  String _name = '';

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: Theme.of(context).colorScheme.inversePrimary, title: Text(widget.title)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text('$_counter', key: const Key('counter_text'), style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 32),
            TextField(
              key: const Key('name_field'),
              decoration: const InputDecoration(labelText: 'Your name'),
              onChanged: (String v) => setState(() => _name = v),
            ),
            const SizedBox(height: 12),
            Text(_name.isEmpty ? 'Hello, stranger' : 'Hello, $_name', key: const Key('greeting')),
            const SizedBox(height: 32),
            const TextField(
              key: Key('secret_field'),
              obscureText: true,
              decoration: InputDecoration(labelText: 'Secret (driver must refuse)'),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              key: const Key('open_sheet'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (BuildContext sheetContext) => SizedBox(
                  height: 160,
                  child: Center(
                    child: ElevatedButton(
                      // Tapping this unmounts it: the sheet route pops and the
                      // driver has no element left to describe afterwards.
                      key: const Key('sheet_confirm'),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _incrementCounter();
                      },
                      child: const Text('Confirm and close'),
                    ),
                  ),
                ),
              ),
              child: const Text('Open sheet'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              key: const Key('open_details'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: '/details'),
                  builder: (_) => const DetailsPage(),
                ),
              ),
              child: const Text('Open details'),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('increment'),
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class DetailsPage extends StatelessWidget {
  const DetailsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Details')),
      body: const Center(child: Text('Details page', key: Key('details_text'))),
    );
  }
}
