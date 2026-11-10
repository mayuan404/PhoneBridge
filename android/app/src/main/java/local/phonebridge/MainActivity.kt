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

        // 两种来源合并：系统里的已安装应用 + 实际推送过通知的 App
        // （小米可能不给「获取应用列表」权限，那时只能靠后者）
        val map = LinkedHashMap<String, String>()
        var fromSystem = 0

        // 1) 有启动图标的 App（只声明了 <queries> 也能拿到，最稳）
        try {
            val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            pm.queryIntentActivities(launcher, 0).forEach { ri ->
                val pkg = ri.activityInfo.packageName
                if (map.containsKey(pkg)) return@forEach
                map[pkg] = ri.loadLabel(pm).toString()
                fromSystem++
            }
        } catch (e: Exception) {
            Link.log("queryIntentActivities 失败：${e.message}")
        }

        // 2) 系统全部应用（需要 QUERY_ALL_PACKAGES）
        try {
            pm.getInstalledApplications(PackageManager.GET_META_DATA).forEach {
                if (map.containsKey(it.packageName)) return@forEach
                map[it.packageName] = pm.getApplicationLabel(it).toString()
                fromSystem++
            }
        } catch (e: Exception) {
            Link.log("getInstalledApplications 失败：${e.message}")
        }

        // 3) 实际收到过通知的 App（前两者都拿不到时的兜底）
        val seen = prefs.getStringSet("seen", emptySet()) ?: emptySet()
        for (pkg in seen) {
            if (map.containsKey(pkg)) continue
            map[pkg] = prefs.getString("label_$pkg", pkg) ?: pkg
        }

        map.remove(packageName)

        val apps = map.entries.map { it.key to it.value }.sortedBy { it.second.lowercase() }
        Link.log("应用列表：系统 $fromSystem 个 / 收到过通知 ${seen.size} 个 / 合计 ${apps.size} 个")
        if (apps.isEmpty()) {
            MaterialAlertDialogBuilder(this)
                .setTitle("还没有可选的 App")
                .setMessage("系统拒绝提供应用列表。\n\n请到「设置 → 应用设置 → PhoneBridge → 权限管理 → 获取应用列表」允许；\n或者先让手机收到几条通知再回来，这里会自动列出它们。")
                .setPositiveButton("打开应用设置") { _, _ ->
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.parse("package:$packageName"))
                    )
                }
                .setNegativeButton("知道了", null)
                .show()
            return
        }

        val labels = apps.map { it.second }.toTypedArray()
        val checked = BooleanArray(apps.size) { apps[it].first in saved }

        MaterialAlertDialogBuilder(this)
            .setTitle("只转发这些 App（${apps.size} 个）")
            .setMessage("勾选后只转发它们；一个都不勾 = 全部转发")
            .setMultiChoiceItems(labels, checked) { _, which, isChecked -> checked[which] = isChecked }
            .setNeutralButton("全不选") { _, _ ->
                prefs.edit().putStringSet("packages", emptySet()).apply()
                Link.log("已清空白名单（全部转发）")
                refresh()
            }
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
