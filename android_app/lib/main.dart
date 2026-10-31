import 'package:flutter/material.dart';

import 'home_screen.dart';

void main() {
  runApp(const IdriciApp());
}

class IdriciApp extends StatelessWidget {
  const IdriciApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Idrici AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF10131A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF54D6B0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
