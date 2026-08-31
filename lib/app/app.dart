import 'package:flutter/material.dart';

import '../ui/connection_page.dart';

final class OrbitRelayApp extends StatelessWidget {
  const OrbitRelayApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF1E2523);
    const rust = Color(0xFFB94728);
    const teal = Color(0xFF1F7169);
    final scheme = ColorScheme.fromSeed(
      seedColor: rust,
      brightness: Brightness.light,
      primary: rust,
      secondary: teal,
      surface: const Color(0xFFFFFFFF),
      onSurface: ink,
      outline: const Color(0xFFB9BFBA),
    );
    return MaterialApp(
      title: 'OrbitRelay Canvas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF2F4F1),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFFFFF),
          foregroundColor: ink,
          elevation: 0,
          centerTitle: false,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFFFFFFF),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFFCDD1CD)),
          ),
        ),
      ),
      home: const ConnectionPage(),
    );
  }
}
