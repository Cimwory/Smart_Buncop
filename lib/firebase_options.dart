import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'DefaultFirebaseOptions have not been configured for web.',
      );
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for iOS yet.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCSrDBlpqRuxP8EQrDaUdYD871RwhC2rn8',
    appId: '1:263440755913:android:3ee4cec5fc60996d3d7118',
    messagingSenderId: '263440755913',
    projectId: 'smart-incubator-d53d4',
    storageBucket: 'smart-incubator-d53d4.firebasestorage.app',
    databaseURL:
        'https://smart-incubator-d53d4-default-rtdb.asia-southeast1.firebasedatabase.app',
  );
}
