package top.shenyunyao.pikmelo_player

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(MediaStoragePlugin::class.java)) {
            flutterEngine.plugins.add(MediaStoragePlugin())
        }
    }
}
