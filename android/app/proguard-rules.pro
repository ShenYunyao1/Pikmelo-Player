# Keep the native verification entry point available to release instrumentation.
-keep class top.shenyunyao.pikmelo_player.UpdatePlugin { *; }
# AndroidJUnitRunner accesses tracing when instrumenting the signed release.
-keep class androidx.tracing.** { *; }
