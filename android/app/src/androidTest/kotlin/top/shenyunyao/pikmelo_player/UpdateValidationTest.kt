package top.shenyunyao.pikmelo_player

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.flutter.plugin.common.MethodCall
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.ExecutorService

@RunWith(AndroidJUnit4::class)
class UpdateValidationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val target = instrumentation.targetContext

    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun verifyAsset(name: String, failure: String?) {
        val file = File(target.filesDir, "updates/$name")
        file.parentFile!!.mkdirs()
        instrumentation.context.assets.open(name).use { source -> file.outputStream().use { source.copyTo(it) } }
        val plugin = UpdatePlugin()
        val context = UpdatePlugin::class.java.getDeclaredField("context").apply { isAccessible = true }
        context.set(plugin, target)
        val method = UpdatePlugin::class.java.getDeclaredMethod("verify", MethodCall::class.java).apply { isAccessible = true }
        val arguments = mapOf("path" to file.path, "size" to file.length(), "sha256" to hash(file.readBytes()),
            "version" to "1.0.1", "versionCode" to 101, "abi" to "x86_64")
        try {
            method.invoke(plugin, MethodCall("verifyUpdate", arguments))
            if (failure != null) fail("Expected rejection for $name")
        } catch (error: InvocationTargetException) {
            if (failure == null) throw error.targetException
            assertTrue("Unexpected rejection for $name: ${error.targetException}", error.targetException.message!!.contains(failure))
        } finally {
            val worker = UpdatePlugin::class.java.getDeclaredField("worker").apply { isAccessible = true }.get(plugin) as ExecutorService
            worker.shutdown()
            file.delete()
        }
    }

    @Test fun validOfficialApk() = verifyAsset("valid.apk", null)
    @Test fun debugSignatureRejected() = verifyAsset("wrong-signature.apk", "签名")
    @Test fun wrongPackageRejected() = verifyAsset("wrong-package.apk", "名称")
    @Test fun wrongArchitectureRejected() = verifyAsset("wrong-abi.apk", "架构")
    @Test fun oldVersionRejected() = verifyAsset("old-version.apk", "版本")
    @Test fun damagedSignatureRejected() = verifyAsset("damaged-signature.apk", "签名")

    @Test fun requestSystemConfirmation() {
        val file = File(target.filesDir, "updates/valid.apk")
        file.parentFile!!.mkdirs()
        instrumentation.context.assets.open("valid.apk").use { source -> file.outputStream().use { source.copyTo(it) } }
        val plugin = UpdatePlugin()
        UpdatePlugin::class.java.getDeclaredField("context").apply { isAccessible = true }.set(plugin, target)
        val launch = target.packageManager.getLaunchIntentForPackage(target.packageName)!!
            .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        target.startActivity(launch)
        Thread.sleep(1500)
        try {
            val method = UpdatePlugin::class.java.getDeclaredMethod("install", MethodCall::class.java).apply { isAccessible = true }
            method.invoke(plugin, MethodCall("installUpdate", mapOf("path" to file.path, "size" to file.length(),
                "sha256" to hash(file.readBytes()), "version" to "1.0.1", "versionCode" to 101, "abi" to "x86_64",
                "requireUserAction" to true)))
            val preferences = target.getSharedPreferences("pikmelo_updates", Context.MODE_PRIVATE)
            for (attempt in 0 until 100) {
                if (preferences.getString("status", "") == "confirmation") break
                Thread.sleep(100)
            }
            assertEquals("confirmation", preferences.getString("status", ""))
            println("PackageInstaller requested user confirmation; cancel the system dialog before the automatic-update scenario")
        } finally {
            (UpdatePlugin::class.java.getDeclaredField("worker").apply { isAccessible = true }.get(plugin) as ExecutorService).shutdown()
        }
    }

    private fun snapshot(): JSONObject {
        val result = JSONObject()
        val database = SQLiteDatabase.openDatabase(File(target.filesDir, "PikmeloPlayer/library.sqlite").path, null, SQLiteDatabase.OPEN_READONLY)
        database.use { db ->
            for (key in listOf("selected_server", "media_directory", "mobile_download_policy", "playback_cache_limit", "automatic_updates")) {
                db.rawQuery("SELECT value FROM app_settings WHERE key = ?", arrayOf(key)).use {
                    assertTrue("Missing setting $key", it.moveToFirst())
                    result.put(key, it.getString(0))
                }
            }
            db.rawQuery("SELECT file_path FROM offline_media WHERE track_id = 'upgrade-track'", null).use {
                assertTrue("Missing offline media", it.moveToFirst())
                val path = it.getString(0)
                result.put("mediaPath", path)
                val bytes = if (path.startsWith("content://")) target.contentResolver.openInputStream(Uri.parse(path))!!.use { input -> input.readBytes() }
                    else File(path).readBytes()
                result.put("mediaHash", hash(bytes))
                assertTrue(bytes.size > 44)
            }
        }
        val permissions = target.contentResolver.persistedUriPermissions.filter { it.isReadPermission && it.isWritePermission }.map { it.uri.toString() }.sorted()
        assertTrue("Custom directory permission missing", permissions.isNotEmpty())
        result.put("permissions", JSONArray(permissions))
        val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val aliases = Collections.list(keystore.aliases()).sorted()
        assertTrue("Secure storage key missing", aliases.isNotEmpty())
        result.put("keyAliases", JSONArray(aliases))
        val prefsRoot = File(target.applicationInfo.dataDir, "shared_prefs")
        val secure = JSONObject()
        prefsRoot.listFiles()?.filter { it.name.contains("secure", ignoreCase = true) || it.name.contains("FlutterSecureStorage", ignoreCase = true) }
            ?.sortedBy { it.name }?.forEach { secure.put(it.name, hash(it.readBytes())) }
        assertTrue("Encrypted credential storage missing", secure.length() > 0)
        result.put("encryptedCredentials", secure)
        return result
    }

    @Test fun snapshotBeforeUpgrade() {
        val value = snapshot()
        target.getSharedPreferences("upgrade_retention_snapshot", Context.MODE_PRIVATE).edit()
            .putString("snapshot", value.toString()).commit()
        println("Upgrade baseline saved with media hash ${value.getString("mediaHash")}")
    }

    @Test fun retentionAfterUpgrade() {
        val before = target.getSharedPreferences("upgrade_retention_snapshot", Context.MODE_PRIVATE).getString("snapshot", null)
        assertNotNull("Upgrade baseline missing", before)
        val expected = JSONObject(before!!)
        val after = snapshot()
        for (key in expected.keys()) {
            assertEquals("Changed after upgrade: $key", expected.get(key).toString(), after.get(key).toString())
        }
        assertTrue(target.packageManager.getPackageInfo(target.packageName, 0).longVersionCode >= 101)
        println("Upgrade retained settings, media bytes, encrypted credentials, keystore aliases and directory grants")
    }
}
