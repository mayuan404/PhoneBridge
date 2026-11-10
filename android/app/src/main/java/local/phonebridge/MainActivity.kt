package local.phonebridge

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputEditText
import android.widget.TextView
import android.graphics.Color

class MainActivity : AppCompatActivity() {
    private lateinit var tvNotify: TextView
    private lateinit var tvBle: TextView
    private lateinit var tvEnc: TextView
    private lateinit var tvEvents: TextView
    private lateinit var etPair: TextInputEditText

    private val handler = Handler(Looper.getMainLooper())
    private val ticker = object : Runnable {
        override fun run() {
            refresh()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvNotify = findViewById(R.id.tvNotify)
        tvBle = findViewById(R.id.tvBle)
        tvEnc = findViewById(R.id.tvEnc)
        tvEvents = findViewById(R.id.tvEvents)
        etPair = findViewById(R.id.etPair)

        etPair.setText(getSharedPreferences("phonebridge", MODE_PRIVATE).getString("pairCode", "") ?: "")

        findViewById<MaterialButton>(R.id.btnGrant).setOnClickListener {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }
        findViewById<MaterialButton>(R.id.btnStart).setOnClickListener {
            val i = Intent(this, BridgeService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
            refresh()
        }
        findViewById<MaterialButton>(R.id.btnStop).setOnClickListener {
            stopService(Intent(this, BridgeService::class.java))
            refresh()
        }
        findViewById<MaterialButton>(R.id.btnSavePair).setOnClickListener {
            val code = etPair.text.toString().trim()
            getSharedPreferences("phonebridge", MODE_PRIVATE).edit().putString("pairCode", code).apply()
            Link.pairCode = code
            Link.log(if (code.isEmpty()) "已清除配对码（将明文发送）" else "配对码已保存")
            refresh()
        }
        findViewById<MaterialButton>(R.id.btnPick).setOnClickListener { pickPackages() }
        findViewById<MaterialButton>(R.id.btnTest).setOnClickListener {
            Link.push("local.phonebridge.test", "测试", "PhoneBridge", "这是一条测试通知 123456")
            refresh()
        }

        ensureRuntimePermissions()
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
        handler.postDelayed(ticker, 1000)
    }

    override fun onPause() {
        super.onPause()
        handler.removeCallbacks(ticker)
    }

    private fun ensureRuntimePermissions() {
        val want = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 31) {
            want += Manifest.permission.BLUETOOTH_CONNECT
            want += Manifest.permission.BLUETOOTH_ADVERTISE
        }
        if (Build.VERSION.SDK_INT >= 33) want += Manifest.permission.POST_NOTIFICATIONS
        val missing = want.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 1)
    }

    private fun pickPackages() {
        val pm = packageManager
        val prefs = getSharedPreferences("phonebridge", MODE_PRIVATE)
        val saved = prefs.getStringSet("packages", emptySet()) ?: emptySet()
        val apps = try {
            pm.getInstalledApplications(PackageManager.GET_META_DATA)
                .filter { it.packageName != packageName }
                .map { it.packageName to pm.getApplicationLabel(it).toString() }
                .sortedBy { it.second.lowercase() }
        } catch (e: Exception) { emptyList() }
        if (apps.isEmpty()) {
            Link.log("读不到应用列表，请确认已授予「获取应用列表」权限")
            return
        }
        val labels = apps.map { it.second }.toTypedArray()
        val checked = BooleanArray(apps.size) { apps[it].first in saved }

        MaterialAlertDialogBuilder(this)
            .setTitle("只转发这些 App")
            .setMessage("不勾选 = 全部转发")
            .setMultiChoiceItems(labels, checked) { _, which, isChecked -> checked[which] = isChecked }
            .setNegativeButton("取消", null)
            .setPositiveButton("保存") { _, _ ->
                val set = apps.filterIndexed { i, _ -> checked[i] }.map { it.first }.toSet()
                prefs.edit().putStringSet("packages", set).apply()
                Link.log("已选择 ${set.size} 个 App" + if (set.isEmpty()) "（全部转发）" else "")
                refresh()
            }
            .show()
    }

    private fun refresh() {
        val enabled = try {
            Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
                ?.contains(packageName) == true
        } catch (e: Exception) { false }

        row(tvNotify, "通知读取", enabled, if (enabled) "已授权" else "未授权")
        row(tvBle, "蓝牙连接", Link.connected, if (Link.connected) "Mac 已连接" else "等待连接")
        val enc = Link.pairCode.isNotEmpty()
        row(tvEnc, "加密", enc, if (enc) "AES-GCM 已启用" else "未设置配对码（明文）")

        val ev = Link.recentEvents().takeLast(7)
        tvEvents.text = if (ev.isEmpty()) "暂无" else ev.joinToString("\n")
    }

    private fun row(tv: TextView, label: String, ok: Boolean, value: String) {
        val mark = if (ok) "●" else "○"
        tv.text = "$mark  $label · $value"
        tv.setTextColor(if (ok) Color.parseColor("#3DDC84") else Color.parseColor("#8A97A6"))
    }
}
