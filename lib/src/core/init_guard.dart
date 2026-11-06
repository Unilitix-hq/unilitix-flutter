/// Runs an initialisation body at most once per process and never lets it
/// throw.
///
/// Every caller of [run] gets the same future: a second `Unilitix.init()`
/// made while the first is still awaiting platform channels waits for that
/// one instead of starting a second setup (two databases, two timers, two
/// crash handlers). An exception from the body is passed to [onError] and the
/// future completes normally, so nothing reaches the app's `main()`.
class InitGuard {
  InitGuard({required this.onError});

  /// Receives an error thrown by the body.
  final void Function(Object error, StackTrace stack) onError;

  Future<void>? _future;
  bool _succeeded = false;

  /// True while the body is running.
  bool get inFlight => _future != null && !_done;
  bool _done = false;

  /// True once the body completed without throwing.
  bool get succeeded => _succeeded;

  /// True once [run] has been called (whatever the outcome).
  bool get started => _future != null;

  /// The running or finished initialisation, or null before [run].
  Future<void>? get future => _future;

  /// Starts [body] on the first call; later calls return the same future and
  /// do not run their body.
  Future<void> run(Future<void> Function() body) {
    return _future ??= _guard(body);
  }

  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
      _succeeded = true;
    } catch (e, st) {
      try {
        onError(e, st);
      } catch (_) {}
    } finally {
      _done = true;
    }
  }
}
