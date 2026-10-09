import 'package:flutter/material.dart';

const Color kAccent = Color(0xFFFFCC33);
const Color kBg = Color(0xFF0B0B0C);
const Color kCard = Color(0xFF151518);
const Color kMuted = Color(0xFF8A8A92);
const Color kOk = Color(0xFF4ADE80);
const Color kBad = Color(0xFFF87171);

ThemeData appTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: kBg,
    colorScheme: base.colorScheme.copyWith(primary: kAccent, secondary: kAccent, surface: kCard),
    appBarTheme: const AppBarTheme(backgroundColor: kBg, elevation: 0, centerTitle: false),
    cardTheme: const CardThemeData(color: kCard, margin: EdgeInsets.symmetric(vertical: 6)),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: Colors.black,
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(filled: true, fillColor: kCard, border: OutlineInputBorder()),
  );
}
