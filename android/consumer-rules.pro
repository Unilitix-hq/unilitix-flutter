# Native crash capture (API 21-29): libunilitix-flutter-native.so binds these
# JNI methods by class and method name.
-keep class io.unilitix.flutter.nativecrash.NativeSignalHandler {
    native <methods>;
}
