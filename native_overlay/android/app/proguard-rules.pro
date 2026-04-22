# Keep Flutter entry points and method channel bridge names.
-keep class io.flutter.** { *; }
-keep class com.awmanager.** { *; }
-keep class * extends android.app.Service
-keep class * extends android.app.Activity

# Keep JNI exports used by xrayjni.
-keepclasseswithmembers class * {
    native <methods>;
}

# Obfuscate aggressively while preserving runtime stability.
-allowaccessmodification
-overloadaggressively
-repackageclasses ''

# Remove logs in release builds.
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
}
