# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Bluetooth serial
-keep class io.github.edufolly.flutterbluetoothserial.** { *; }

# Dart/Flutter secure storage
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# Square Mobile Payments SDK (Tap to Pay). Uses reflection/native bindings;
# release builds run R8 (isMinifyEnabled = true), so keep its classes.
-keep class com.squareup.** { *; }
-dontwarn com.squareup.**

# Flutter's deferred-components manager references Play Core, which isn't on the
# classpath unless the app actually uses deferred components. This app doesn't,
# so silence the missing-class warnings R8 would otherwise fail on.
-dontwarn com.google.android.play.core.**
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }

# Square's mobile-payments-sdk-internals 2.6.0 declares SQLDelight's *JVM*
# driver (app.cash.sqldelight:sqlite-driver -> org.xerial:sqlite-jdbc) at
# compile scope beside the Android one, so a desktop JDBC library lands on an
# Android classpath. It references java.sql.JDBCType (Android's java.sql has no
# JDBCType) and slf4j (an optional logging backend that isn't here), and R8
# treats missing classes as an error, not a warning:
#   Missing class java.sql.JDBCType (referenced from ... JDBC3PreparedStatement)
#   Missing class org.slf4j.Logger / org.slf4j.LoggerFactory
# None of it is reachable on Android — Square drives SQLDelight through
# android-driver — so suppress the warnings and let R8 shrink the dead code
# away. Appeared with the 2.5.0 -> 2.6.0 SDK bump; drop this if Square fixes
# the POM.
-dontwarn java.sql.**
-dontwarn org.sqlite.**
-dontwarn org.slf4j.**

# WorkManager (pulled in transitively, likely by a plugin) instantiates its
# Room-generated WorkDatabase_Impl reflectively via getDeclaredConstructor(),
# which R8 can't trace. Without this keep, release builds crash on startup:
# "NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []"
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep class androidx.work.impl.** { *; }
-keep class * extends androidx.room.RoomDatabase { *; }
-dontwarn androidx.work.**
