# Release shrinking (R8) keeps only what these rules and the libraries' own
# rules name. Flutter's Gradle plugin adds this file to the release build
# when it exists (FlutterPlugin.kt, next to proguard-android-optimize.txt).

# WorkManager opens its Room database by calling the generated
# WorkDatabase_Impl's no-argument constructor through reflection. Room 2.6.1
# keeps the class but not the constructor, so without this rule every start
# crashed in androidx.startup (seen in the expense tracker).
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# WorkManager creates the worker by class name with this constructor.
-keep class io.github.santhoshunt.drift.UsageBufferWorker {
    <init>(android.content.Context, androidx.work.WorkerParameters);
}

# Keep the channel handlers' names readable in crash traces and in the
# release dex check (drift_apkcheck.bat). Shrinking still applies.
-keepnames class io.github.santhoshunt.drift.UsageBridge
-keepnames class io.github.santhoshunt.drift.IconSwitcher
-keepnames class io.github.santhoshunt.drift.UpdateInstaller
-keepnames class io.github.santhoshunt.drift.NudgeBridge

# NudgeDecider and NudgeOverlay are objects called from one place, so R8
# inlines them and drops the classes. Keep the classes (not their members)
# so crash traces name them and the release dex check finds them.
-keep class io.github.santhoshunt.drift.NudgeDecider
-keep class io.github.santhoshunt.drift.NudgeOverlay
