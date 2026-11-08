# androidx.security:security-crypto (used by com.unilitix:unilitix-android for
# encrypted storage) brings in Tink, which refers to compile-only annotations.
# Without these rules R8 stops the host app's minified release build with
# "Missing class com.google.errorprone.annotations.*". unilitix-android 1.11.2
# ships the same rules; kept here so 1.11.1 works too.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
