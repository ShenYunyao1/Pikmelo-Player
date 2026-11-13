package top.shenyunyao.pikmelo_player

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.net.ConnectivityManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.android.apksig.ApkVerifier
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.zip.ZipFile

private const val UPDATE_PREFS = "pikmelo_updates"
private const val INSTALL_ACTION = "top.shenyunyao.pikmelo_player.INSTALL_RESULT"
private val supportedArchitectures = setOf("arm64-v8a", "armeabi-v7a", "x86_64")

private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
    .joinToString("") { "%02x".format(it.toInt() and 0xff) }

@Suppress("DEPRECATION")
private fun versionCode(info: PackageInfo): Long =
    if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

@Suppress("DEPRECATION")
private fun installedSigner(context: Context): String {
    val signatures = if (Build.VERSION.SDK_INT >= 28) {
        context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            .signingInfo!!.apkContentsSigners
    } else context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_SIGNATURES).signatures!!
    check(signatures.size == 1) { "Unexpected installed signing identity" }
    return digest(signatures.single().toByteArray())
}

private fun fileHash(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { stream ->
        val buffer = ByteArray(256 * 1024)
        while (true) {
            val read = stream.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

class UpdatePlugin : FlutterPlugin, ActivityAware {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "pikmelo/updates")
        channel.setMethodCallHandler(::handle)
    }

    @Suppress("DEPRECATION")
    private fun canInstall(): Boolean = if (Build.VERSION.SDK_INT >= 26) {
        context.packageManager.canRequestPackageInstalls()
    } else Settings.Secure.getInt(context.contentResolver, Settings.Secure.INSTALL_NON_MARKET_APPS, 0) == 1

    private fun information(): Map<String, Any?> {
        val current = context.packageManager.getPackageInfo(context.packageName, 0)
        val proxy = (context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).defaultProxy
        val preferences = context.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
        val expected = preferences.getLong("versionCode", 0)
        if (expected > 0 && versionCode(current) >= expected) {
            preferences.edit().putString("status", "installed").putString("message", "更新安装完成").apply()
        } else if (preferences.getString("status", null) == "installing" &&
            context.packageManager.packageInstaller.getSessionInfo(preferences.getInt("session", -1)) == null) {
            preferences.edit().putString("status", "failed").putString("message", "安装会话已结束，请重试").apply()
        }
        return mapOf("platform" to "android", "version" to current.versionName,
            "versionCode" to versionCode(current), "packageName" to context.packageName,
            "abis" to Build.SUPPORTED_ABIS.toList(), "sdk" to Build.VERSION.SDK_INT,
            "signerSha256" to installedSigner(context), "canInstall" to canInstall(),
            "proxy" to if (proxy?.host != null && proxy.port > 0) "PROXY ${proxy.host}:${proxy.port}" else null,
            "directory" to File(context.filesDir, "updates").path,
            "installStatus" to preferences.getString("status", "idle"),
            "installMessage" to preferences.getString("message", ""))
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "requestInstallPermission") {
            val host = activity
            if (host == null) { result.error("install", "应用窗口未就绪", null); return }
            val intent = if (Build.VERSION.SDK_INT >= 26) {
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
            } else Intent(Settings.ACTION_SECURITY_SETTINGS)
            try { host.startActivity(intent); result.success(null) }
            catch (error: Exception) { result.error("install", error.message, null) }
            return
        }
        worker.execute {
            try {
                val value: Any? = when (call.method) {
                    "updateInfo" -> information()
                    "verifyUpdate" -> { verify(call); null }
                    "installUpdate" -> install(call)
                    "openRelease", "openRepository" -> {
                        val url = if (call.method == "openRepository") {
                            "https://github.com/ShenYunyao1/Pikmelo-Player"
                        } else {
                            call.argument<String>("url")!!
                        }
                        require(
                            call.method == "openRepository" ||
                                url.startsWith("https://github.com/ShenYunyao1/Pikmelo-Player/releases")
                        )
                        main.post {
                            try {
                                context.startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("update", error.message ?: "无法打开浏览器", null)
                            }
                        }
                        return@execute
                    }
                    else -> throw IllegalArgumentException("Unknown update operation")
                }
                main.post { result.success(value) }
            } catch (error: Exception) {
                main.post { result.error("update", error.message ?: "更新操作失败", null) }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun verify(call: MethodCall): File {
        val root = File(context.filesDir, "updates").canonicalFile
        val apk = File(call.argument<String>("path")!!).canonicalFile
        require(apk.parentFile == root && apk.isFile && apk.name.endsWith(".apk")) { "安装包位置无效" }
        require(apk.length() == call.argument<Number>("size")!!.toLong()) { "安装包大小不符" }
        require(fileHash(apk) == call.argument<String>("sha256")) { "安装包完整性校验失败" }
        val certificate = BuildConfig.RELEASE_CERT_SHA256
        check(installedSigner(context) == certificate) { "请先安装正式签名版本，再使用自动更新" }
        val verification = ApkVerifier.Builder(apk).setMinCheckedPlatformVersion(Build.VERSION.SDK_INT)
            .setMaxCheckedPlatformVersion(Build.VERSION.SDK_INT).build().verify()
        require(verification.isVerified) { "APK 签名验证失败" }
        require(verification.signerCertificates.size == 1 && digest(verification.signerCertificates.single().encoded) == certificate) {
            "安装包签名与固定正式签名不一致"
        }
        val metadata = context.packageManager.getPackageArchiveInfo(apk.path, 0)
            ?: throw IllegalArgumentException("安装包无法解析")
        require(metadata.packageName == context.packageName) { "安装包名称不匹配" }
        val current = context.packageManager.getPackageInfo(context.packageName, 0)
        require(versionCode(metadata) > versionCode(current) && versionCode(metadata) == call.argument<Number>("versionCode")!!.toLong()) {
            "安装包版本不符或版本未递增"
        }
        require(metadata.versionName == call.argument<String>("version")) { "安装包版本名称不符" }
        require(metadata.applicationInfo!!.minSdkVersion <= Build.VERSION.SDK_INT) { "设备系统版本不兼容" }
        val abi = call.argument<String>("abi")
        require(abi in supportedArchitectures && Build.SUPPORTED_ABIS.contains(abi)) { "安装包架构不兼容" }
        ZipFile(apk).use { zip ->
            val architectures = zip.entries().asSequence().map { it.name }.filter { it.startsWith("lib/") && it.endsWith(".so") }
                .map { it.split('/')[1] }.toSet()
            require(architectures == setOf(abi)) { "APK 原生库架构不符" }
        }
        return apk
    }

    private fun install(call: MethodCall): Int {
        val apk = verify(call)
        check(canInstall()) { "请先允许此应用安装更新" }
        val installer = context.packageManager.packageInstaller
        val preferences = context.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
        val previous = preferences.getInt("session", -1)
        if (installer.mySessions.any { it.sessionId == previous }) installer.abandonSession(previous)
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
            if (Build.VERSION.SDK_INT >= 31) {
                // Release instrumentation exercises the system-confirmation fallback with the same APK.
                setRequireUserAction(if (call.argument<Boolean>("requireUserAction") == true)
                    PackageInstaller.SessionParams.USER_ACTION_REQUIRED else PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val sessionId = installer.createSession(params)
        try {
            installer.openSession(sessionId).use { session ->
                val digest = MessageDigest.getInstance("SHA-256")
                apk.inputStream().use { source ->
                    session.openWrite("base.apk", 0, apk.length()).use { target ->
                        val buffer = ByteArray(256 * 1024)
                        while (true) {
                            val size = source.read(buffer)
                            if (size < 0) break
                            target.write(buffer, 0, size)
                            digest.update(buffer, 0, size)
                        }
                        session.fsync(target)
                    }
                }
                check(digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) } == call.argument<String>("sha256")) { "写入安装会话时校验失败" }
                preferences.edit().putInt("session", sessionId).putString("status", "installing")
                    .putLong("versionCode", call.argument<Number>("versionCode")!!.toLong()).putString("message", "系统正在安装更新").commit()
                val intent = Intent(context, InstallResultReceiver::class.java).setAction(INSTALL_ACTION)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                val callback = PendingIntent.getBroadcast(context, sessionId, intent, flags)
                session.commit(callback.intentSender)
            }
        } catch (error: Exception) {
            installer.abandonSession(sessionId)
            preferences.edit().putString("status", "failed").putString("message", error.message).apply()
            throw error
        }
        return sessionId
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}

class InstallResultReceiver : BroadcastReceiver() {
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != INSTALL_ACTION) return
        val preferences = context.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE)
        if (intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -2) != preferences.getInt("session", -1)) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            preferences.edit().putString("status", "confirmation").putString("message", "请在系统界面确认安装").apply()
            val confirmation = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                else intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            try {
                check(confirmation != null) { "系统安装界面不可用，请重试" }
                context.startActivity(confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (error: Exception) {
                preferences.edit().putString("status", "failed").putString("message", error.message).apply()
            }
        } else {
            preferences.edit().putString("status", if (status == PackageInstaller.STATUS_SUCCESS) "installed" else "failed")
                .putString("message", if (status == PackageInstaller.STATUS_SUCCESS) "更新安装完成" else
                    "安装失败或已取消（$status）：${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "请重试"}").apply()
        }
    }
}
