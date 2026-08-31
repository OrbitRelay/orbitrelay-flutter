import 'dart:io';

import 'package:pdfrx/pdfrx.dart' as pdfrx;

Future<void> initializePdfrxForTest() =>
    pdfrx.pdfrxInitialize(tmpPath: Directory.systemTemp.path);
