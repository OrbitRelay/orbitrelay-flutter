import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:orbitrelay_client_flutter/ui/connection_page.dart';

void main() {
  testWidgets('connection page renders Development descriptor form', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectionPage()));
    expect(find.text('Development session'), findsOneWidget);
    expect(find.byKey(const Key('server-url-field')), findsOneWidget);
    expect(find.byKey(const Key('connect-button')), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('connection page validates URL and descriptor IDs', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectionPage()));
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'http://127.0.0.1',
    );
    await tester.enterText(find.byKey(const Key('session-id-field')), 'bad');
    await tester.enterText(find.byKey(const Key('canvas-id-field')), 'bad');
    await tester.enterText(find.byKey(const Key('layer-id-field')), 'bad');
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pump();
    expect(find.text('Enter a valid ws:// or wss:// URL.'), findsOneWidget);
    expect(
      find.text('Session ID must be a canonical lowercase UUID.'),
      findsOneWidget,
    );
    expect(
      find.text('Canvas ID must be a canonical lowercase UUID.'),
      findsOneWidget,
    );
    expect(
      find.text('Layer ID must be a canonical lowercase UUID.'),
      findsOneWidget,
    );
  });
}
