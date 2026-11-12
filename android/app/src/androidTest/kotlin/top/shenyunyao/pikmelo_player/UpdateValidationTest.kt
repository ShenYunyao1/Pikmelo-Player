package top.shenyunyao.pikmelo_player

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.provider.DocumentsContract
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.ExecutorService

@RunWith(AndroidJUnit4::class)
class UpdateValidationTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val target = instrumentation.targetContext

    private fun hash(bytes: ByteArray): String {
        // SDK primitives avoid dependency on the target's obfuscated Kotlin lambda interfaces.
        val result = StringBuilder()
        for (value in MessageDigest.getInstance("SHA-256").digest(bytes)) {
            result.append(String.format("%02x", value.toInt() and 0xff))
        }
        return result.toString()
    }

    private fun arguments(file: File): MutableMap<String, Any> {
        val candidate = instrumentation.context.assets.open("candidate.json").use { JSONObject(String(it.readBytes())) }
        val result = java.util.HashMap<String, Any>()
        result["path"] = file.path
        result["size"] = file.length()
        result["sha256"] = hash(file.readBytes())
        result["version"] = candidate.getString("version")
        result["versionCode"] = candidate.getInt("versionCode")
        result["abi"] = candidate.getString("abi")
        return result
    }

    private fun request(method: Method, operation: String, values: Map<String, Any>): Any {
        val constructor = method.parameterTypes[0].declaredConstructors.first {
            it.parameterTypes.size == 2 && it.parameterTypes.contains(String::class.java) && it.parameterTypes.contains(Any::class.java)
        }.apply { isAccessible = true }
        return if (constructor.parameterTypes[0] == String::class.java) constructor.newInstance(operation, values)
            else constructor.newInstance(values, operation)
    }

    private fun verifyAsset(name: String, failure: String?) {
        val file = File(target.filesDir, "updates/$name")
        file.parentFile!!.mkdirs()
        instrumentation.context.assets.open(name).use { source -> file.outputStream().use { source.copyTo(it) } }
        val plugin = UpdatePlugin()
        val context = UpdatePlugin::class.java.getDeclaredField("context").apply { isAccessible = true }
        context.set(plugin, target)
        val method = UpdatePlugin::class.java.declaredMethods.first { it.name == "verify" }.apply { isAccessible = true }
        try {
            method.invoke(plugin, request(method, "verifyUpdate", arguments(file)))
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
        // Exercise the receiver without loading Flutter into the instrumented runtime.
        instrumentation.uiAutomation.adoptShellPermissionIdentity("android.permission.START_ACTIVITIES_FROM_BACKGROUND")
        try {
            val method = UpdatePlugin::class.java.declaredMethods.first { it.name == "install" }.apply { isAccessible = true }
            val values = arguments(file)
            values["requireUserAction"] = true
            method.invoke(plugin, request(method, "installUpdate", values))
            val preferences = target.getSharedPreferences("pikmelo_updates", Context.MODE_PRIVATE)
            for (attempt in 0 until 100) {
                if (preferences.getString("status", "") == "confirmation") break
                Thread.sleep(100)
            }
            assertEquals("confirmation", preferences.getString("status", ""))
            println("PackageInstaller requested user confirmation; cancel the system dialog before the automatic-update scenario")
        } finally {
            instrumentation.uiAutomation.dropShellPermissionIdentity()
            (UpdatePlugin::class.java.getDeclaredField("worker").apply { isAccessible = true }.get(plugin) as ExecutorService).shutdown()
        }
    }

    private fun snapshot(): JSONObject {
        val result = JSONObject()
        val database = SQLiteDatabase.openDatabase(File(target.filesDir, "PikmeloPlayer/library.sqlite").path, null, SQLiteDatabase.OPEN_READONLY)
        database.use { db ->
            for (key in arrayOf("selected_server", "media_directory", "mobile_download_policy", "playback_cache_limit", "automatic_updates")) {
                db.rawQuery("SELECT value FROM app_settings WHERE key = ?", arrayOf(key)).use {
                    assertTrue("Missing setting $key", it.moveToFirst())
                    result.put(key, it.getString(0))
                }
            }
            db.rawQuery("SELECT file_path, authorized FROM offline_media WHERE track_id = 'upgrade-track'", null).use {
                assertTrue("Missing offline media", it.moveToFirst())
                assertEquals("Offline authorization was revoked", 1, it.getInt(1))
                val path = it.getString(0)
                result.put("mediaPath", path)
                val bytes = if (path.startsWith("content://")) target.contentResolver.openInputStream(Uri.parse(path))!!.use { input -> input.readBytes() }
                    else File(path).readBytes()
                result.put("mediaHash", hash(bytes))
                assertTrue(bytes.size > 44)
            }
        }
        val permissions = java.util.ArrayList<String>()
        for (permission in target.contentResolver.persistedUriPermissions) {
            if (permission.isReadPermission && permission.isWritePermission) permissions.add(permission.uri.toString())
        }
        Collections.sort(permissions)
        assertTrue("Custom directory permission missing", !permissions.isEmpty())
        result.put("permissions", JSONArray(permissions))
        val tree = Uri.parse(result.getString("media_directory"))
        val document = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val probe = DocumentsContract.createDocument(target.contentResolver, document, "text/plain", ".pikmelo-upgrade-probe")!!
        try {
            target.contentResolver.openOutputStream(probe)!!.use { it.write("retained".toByteArray()) }
            assertEquals("retained", target.contentResolver.openInputStream(probe)!!.use { String(it.readBytes()) })
        } finally { assertTrue(DocumentsContract.deleteDocument(target.contentResolver, probe)) }
        result.put("installPermission", target.packageManager.canRequestPackageInstalls())
        val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val aliases = Collections.list(keystore.aliases()).apply { Collections.sort(this) }
        assertTrue("Secure storage key missing", !aliases.isEmpty())
        result.put("keyAliases", JSONArray(aliases))
        val prefsRoot = File(target.applicationInfo.dataDir, "shared_prefs")
        val secure = JSONObject()
        for (file in prefsRoot.listFiles()!!) {
            if (file.name.contains("secure") || file.name.contains("FlutterSecureStorage")) {
                secure.put(file.name, hash(file.readBytes()))
            }
        }
        assertTrue("Encrypted credential storage missing", secure.length() > 0)
        result.put("encryptedCredentials", secure)
        return result
    }

    @Test fun snapshotBeforeUpgrade() {
        val value = snapshot()
        target.getSharedPreferences("upgrade_retention_snapshot", Context.MODE_PRIVATE).edit()
            .putLong("versionCode", target.packageManager.getPackageInfo(target.packageName, 0).longVersionCode)
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
        val previousCode = target.getSharedPreferences("upgrade_retention_snapshot", Context.MODE_PRIVATE).getLong("versionCode", 0)
        assertTrue(target.packageManager.getPackageInfo(target.packageName, 0).longVersionCode > previousCode)
        println("Upgrade retained settings, media bytes, encrypted credentials, keystore aliases and directory grants")
    }
}
