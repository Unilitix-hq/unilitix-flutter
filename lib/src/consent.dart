/// The user's consent to analytics and replay collection (SDK contract:
/// `granted | pending | denied`, default `granted`).
///
/// * [granted] — collect and upload (the default for apps that do not ask).
/// * [pending] — collect to the on-device queue but upload nothing, until the
///   app calls `Unilitix.setConsent(granted)` (then everything held is sent)
///   or `denied` (then everything held is deleted). This is the state to
///   start in for NDPR/GDPR apps that show a consent screen after launch.
/// * [denied] — collect nothing, upload nothing, and purge what is stored.
///   Equivalent to `optOut()`.
///
/// Since 3.0.0 the decision is kept by the native SDK (Android
/// `unilitix-android`, iOS UnilitixCore): it is persisted there and wins over
/// the `consent` passed to later `init` calls.
enum UnilitixConsent { pending, granted, denied }

/// Parses a contract wire name; null for anything else.
UnilitixConsent? consentFromWireName(Object? value) {
  if (value is! String) return null;
  for (final c in UnilitixConsent.values) {
    if (c.name == value.trim().toLowerCase()) return c;
  }
  return null;
}
