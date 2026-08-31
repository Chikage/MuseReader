import 'package:flutter/material.dart';

import 'src/ui/library_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MuseReaderApp());
}

class MuseReaderApp extends StatelessWidget {
  const MuseReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xffb54d35);
    const secondary = Color(0xff2f7067);
    return MaterialApp(
      title: 'MuseReader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: primary,
              brightness: Brightness.light,
            ).copyWith(
              primary: primary,
              secondary: secondary,
              surface: const Color(0xfff8f6f1),
            ),
        scaffoldBackgroundColor: const Color(0xfff8f6f1),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xfff8f6f1),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: Color(0xffffffff),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      home: const LibraryPage(),
    );
  }
}
