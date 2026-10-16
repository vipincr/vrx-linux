/// The platform the device runs, for widget tests.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Linux, as the device runs. Flutter's widgets differ by platform, and the
/// test binding's default is Android: there a touch outside a text field
/// leaves its focus alone, on Linux it drops it. Tested as Android, every
/// key of the on-screen keyboard typed; on the board each key's tap took the
/// field's focus and the keyboard with it (0.1.0122). A test of anything a
/// person touches passes `variant: onDevice`.
final TargetPlatformVariant onDevice = TargetPlatformVariant.only(TargetPlatform.linux);
