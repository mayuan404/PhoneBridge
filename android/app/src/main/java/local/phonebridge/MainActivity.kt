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

        val map = LinkedHashMap<String, String>()

        // 1) 有启动图标的 App：这才是用户真正认识的那批
        try {
            val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            pm.queryIntentActivities(launcher, 0).forEach { ri ->
                map[ri.activityInfo.packageName] = ri.loadLabel(pm).toString()
            }
        } catch (e: Exception) {
            Link.log("queryIntentActivities 失败：${e.message}")
        }
        val launcherCount = map.size

        // 2) 启动图标太少时，补上系统全部应用
        if (map.size < 10) {
            try {
                pm.getInstalledApplications(PackageManager.GET_META_DATA).forEach {
                    map.putIfAbsent(it.packageName, pm.getApplicationLabel(it).toString())
                }
            } catch (e: Exception) {
                Link.log("getInstalledApplications 失败：${e.message}")
            }
        }
        // 3) 兜底：收到过通知的
        val seen = prefs.getStringSet("seen", emptySet()) ?: emptySet()
        for (pkg in seen) map.putIfAbsent(pkg, prefs.getString("label_$pkg", pkg) ?: pkg)
        map.remove(packageName)

        val apps = map.entries.map { it.key to it.value }.sortedBy { it.second.lowercase() }
        Link.log("应用列表：启动图标 $launcherCount / 合计 ${apps.size} / 已选 ${saved.size}")
        if (apps.isEmpty()) {
            MaterialAlertDialogBuilder(this)
                .setTitle("还没有可选的 App")
                .setMessage("系统拒绝提供应用列表。\n让手机先收到几条通知再回来，这里会自动列出它们。")
                .setPositiveButton("知道了", null)
                .show()
            return
        }

        // 自定义视图：搜索框 + 可多选列表（AlertDialog 的 message 和列表互斥，不能用 setMultiChoiceItems）
        val root = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(dp(4), dp(4), dp(4), 0)
        }
        val search = android.widget.EditText(this).apply {
            hint = "搜索 App"
            setSingleLine(true)
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 14f)
        }
        root.addView(search)
        val list = android.widget.ListView(this)
        root.addView(list, android.widget.LinearLayout.LayoutParams(
            android.widget.LinearLayout.LayoutParams.MATCH_PARENT, dp(360)))

        val chosen = HashSet<String>(saved)
        var filtered = apps

        fun bind() {
            list.adapter = android.widget.ArrayAdapter(
                this,
                android.R.layout.simple_list_item_multiple_choice,
                filtered.map { it.second }
            )
            list.choiceMode = android.widget.ListView.CHOICE_MODE_MULTIPLE
            filtered.forEachIndexed { i, pair ->
                list.setItemChecked(i, chosen.contains(pair.first))
            }
        }
        list.setOnItemClickListener { _, _, pos, _ ->
            val pkg = filtered[pos].first
            if (!chosen.add(pkg)) chosen.remove(pkg)
        }
        search.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) {
                val q = s?.toString()?.trim()?.lowercase().orEmpty()
                filtered = if (q.isEmpty()) apps else apps.filter { it.second.lowercase().contains(q) }
                bind()
            }
        })
        bind()

        MaterialAlertDialogBuilder(this)
            .setTitle("只转发这些 App")
            .setView(root)
            .setNeutralButton("全不选") { _, _ ->
                prefs.edit().putStringSet("packages", emptySet()).apply()
                Link.log("已清空白名单（全部转发）")
                refresh()
            }
            .setNegativeButton("取消", null)
            .setPositiveButton("保存") { _, _ ->
                prefs.edit().putStringSet("packages", chosen).apply()
                Link.log("白名单已保存：\n" + chosen.mapNotNull { pkg ->
                    prefs.getString("label_$pkg", null) ?: apps.firstOrNull { it.first == pkg }?.second ?: pkg
                }.sorted().joinToString("、"))
                refresh()
            }
            .show()
    }

    private fun dp(v: Int): Int =
        resources.displayMetrics.density.let { (v * it).toInt() }

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
