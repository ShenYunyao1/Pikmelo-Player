# Keep the test-only runtime independent of the optimized target application's classes.
-keep class kotlin.** { *; }
-keep class top.shenyunyao.pikmelo_player.UpdateValidationTest** { *; }
-dontoptimize
-dontobfuscate
