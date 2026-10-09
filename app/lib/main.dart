import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/home_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The grid and the camera geometry both assume an upright phone.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const DistanceBitsApp());
}

class DistanceBitsApp extends StatelessWidget {
  const DistanceBitsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Distance Bits',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: const HomeScreen(),
    );
  }
}
