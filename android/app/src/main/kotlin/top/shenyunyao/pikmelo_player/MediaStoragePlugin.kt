package top.shenyunyao.pikmelo_player

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class MediaStoragePlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var connectivity: ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var activity: Activity? = null
    private var picker: MethodChannel.Result? = null
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = notifyNetwork()
        override fun onLost(network: Network) = notifyNetwork()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = notifyNetwork()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        channel = MethodChannel(binding.binaryMessenger, "pikmelo/media_storage")
        channel.setMethodCallHandler(::handle)
        connectivity.registerDefaultNetworkCallback(callback)
    }

    private fun network(): Map<String, Boolean> {
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        return mapOf("connected" to (capabilities != null),
            "cellular" to (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true))
    }

    private fun notifyNetwork() {
        main.post { channel.invokeMethod("networkChanged", network()) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "chooseDirectory") {
            val host = activity
            if (host == null || picker != null) {
                result.error("directory", "Directory picker is unavailable", null)
                return
            }
            picker = result
            host.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
            }, 7301)
            return
        }
        if (call.method == "network") {
            result.success(network())
            return
        }
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "stat" -> call.argument<List<String>>("paths")!!.associateWith { path ->
                        try {
                            context.contentResolver.openAssetFileDescriptor(Uri.parse(path), "r")?.use { descriptor ->
                                descriptor.parcelFileDescriptor.statSize
                            } ?: -1L
                        } catch (_: Exception) { -1L }
                    }
                    "delete" -> {
                        val uri = Uri.parse(call.argument<String>("path")!!)
                        try {
                            if (!DocumentsContract.deleteDocument(context.contentResolver, uri)) {
                                throw java.io.IOException("Cannot delete media")
                            }
                        } catch (_: java.io.FileNotFoundException) { }
                        null
                    }
                    "copyTo" -> copy(call)
                    "create" -> create(call.argument<String>("directory")!!, call.argument<String>("name")!!)
                    else -> throw IllegalArgumentException("Unknown storage operation")
                }
                main.post { result.success(value) }
            } catch (error: Exception) {
                main.post { result.error("storage", error.message, null) }
            }
        }
    }

    private fun input(path: String) = if (path.startsWith("content://")) {
        context.contentResolver.openInputStream(Uri.parse(path))!!
    } else File(path).inputStream()

    private fun create(directory: String, name: String): String {
        require(!name.contains('/') && !name.contains('\\'))
        val resolver = context.contentResolver
        return if (directory.startsWith("content://")) {
            val tree = Uri.parse(directory)
            val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            DocumentsContract.createDocument(resolver, root, "application/octet-stream", name)!!.toString()
        } else {
            File(directory).mkdirs()
            File(directory, name).also { check(it.createNewFile()) }.path
        }
    }

    private fun copy(call: MethodCall): String {
        val source = call.argument<String>("source")!!
        val target = call.argument<String>("target")!!
        val expected = call.argument<Number>("size")!!.toLong()
        val resolver = context.contentResolver
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var count = 0L
            input(source).use { stream ->
                val output = if (target.startsWith("content://")) resolver.openOutputStream(Uri.parse(target), "w")!!
                    else File(target).outputStream()
                output.use { sink ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        val size = stream.read(buffer)
                        if (size < 0) break
                        digest.update(buffer, 0, size)
                        sink.write(buffer, 0, size)
                        count += size
                    }
                    sink.flush()
                }
            }
            check(count == expected) { "Media size changed during copy" }
            val copied = MessageDigest.getInstance("SHA-256")
            input(target).use { stream ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    val size = stream.read(buffer)
                    if (size < 0) break
                    copied.update(buffer, 0, size)
                }
            }
            check(digest.digest().contentEquals(copied.digest())) { "Media copy verification failed" }
            return target
        } catch (error: Exception) {
            if (target.startsWith("content://")) DocumentsContract.deleteDocument(resolver, Uri.parse(target))
            else File(target).delete()
            throw error
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != 7301) return false
        val result = picker ?: return true
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
        } else {
            try {
                val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                context.contentResolver.takePersistableUriPermission(uri, flags)
                result.success(uri.toString())
            } catch (error: Exception) { result.error("directory", error.message, null) }
        }
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivity() {
        picker?.success(null)
        picker = null
        activity = null
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        connectivity.unregisterNetworkCallback(callback)
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
