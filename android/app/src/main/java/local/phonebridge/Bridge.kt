package local.phonebridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.bluetooth.BluetoothStatusCodes
import android.os.Build
import android.os.IBinder
import android.os.ParcelUuid
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONObject
import java.io.OutputStream
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * PhoneBridge 安卓端
 *
 * 两条直连通道，都不经过服务器：
 *   1. BLE：本机作为 GATT server 广播，Mac 端订阅后把通知推过去；
 *   2. TCP：连接 127.0.0.1:8765（配合 adb reverse，用于联调/无蓝牙时）。
 *
 * 通知读取需要用户在「设置 → 通知使用权」里授权。
 */

/** 应用层加密：与 Mac 端同一套派生规则（SHA-256(code + "|PhoneBridge|v1")）+ AES-256-GCM */
object Secure {
    fun normalize(s: String): String = s.uppercase().filter { it.isLetterOrDigit() }

    fun key(code: String): ByteArray? {
        val norm = normalize(code)
        if (norm.length < 8) return null
        val md = java.security.MessageDigest.getInstance("SHA-256")
        return md.digest("$norm|PhoneBridge|v1".toByteArray(Charsets.UTF_8))
    }

    /** 返回 "E1:" + base64(nonce(12) + ciphertext + tag) */
    fun encrypt(plain: ByteArray, code: String): String? {
        val k = key(code) ?: return null
        return try {
            val nonce = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
            val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                javax.crypto.Cipher.ENCRYPT_MODE,
                javax.crypto.spec.SecretKeySpec(k, "AES"),
                javax.crypto.spec.GCMParameterSpec(128, nonce)
            )
            val ct = cipher.doFinal(plain)
            "E1:" + android.util.Base64.encodeToString(nonce + ct, android.util.Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.e("PhoneBridge", "encrypt failed: ${e.message}")
            null
        }
    }
}

object Link {
    /** 手机端配对码（空 = 不加密，仅联调用） */
    @Volatile var pairCode: String = ""
    val serviceUUID: UUID = UUID.fromString("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    val rxUUID: UUID = UUID.fromString("6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    val txUUID: UUID = UUID.fromString("6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    @Volatile var server: BluetoothGattServer? = null
    @Volatile var txChar: BluetoothGattCharacteristic? = null
    @Volatile var central: BluetoothDevice? = null
    @Volatile var connected = false

    private val queue = ConcurrentLinkedQueue<String>()

    /** 断链时最多攒这么多条：再多就丢最旧的，避免恢复后一次性刷屏 */
    private const val MAX_QUEUE = 50

    /** 最近事件，App 界面里直接显示，方便没有 adb 时排查 */
    private val events = ArrayDeque<String>()

    fun log(msg: String) {
        val t = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date())
        synchronized(events) {
            events.addLast("$t  $msg")
            while (events.size > 40) events.removeFirst()
        }
        Log.i("PhoneBridge", msg)
    }

    fun recentEvents(): List<String> = synchronized(events) { events.toList() }

    private var hbStarted = false

    /** 心跳：长时间没有真实通知时，也要能发现链路已死 */
    fun startHeartbeat() {
        if (hbStarted) return
        hbStarted = true
        handler.postDelayed(object : Runnable {
            override fun run() {
                // 积压时不要用心跳继续污染队列
                if (connected && queue.size < 20) push("__hb", "heartbeat", "", "")
                handler.postDelayed(this, 20_000)
            }
        }, 20_000)
    }

    /** 把一条通知编码成 JSON 行发出去 */
    fun push(pkg: String, app: String, title: String, text: String) {
        val id = "${System.currentTimeMillis()}-${seq++}"
        val json = JSONObject()
            .put("id", id)
            .put("pkg", pkg)
            .put("app", app)
            .put("title", title)
            .put("text", text)
            .put("time", System.currentTimeMillis() / 1000.0)
            .toString()
        log("收到通知 pkg=$pkg title=${title.take(20)}")
        val line = if (pairCode.isEmpty()) {
            json + "\n"
        } else {
            val enc = Secure.encrypt(json.toByteArray(Charsets.UTF_8), pairCode)
            if (enc == null) {
                log("加密失败，本条丢弃")
                return
            }
            enc + "\n"
        }
        pending[id] = Pending(line, 0)
        while (queue.size >= MAX_QUEUE) {
            val dropped = queue.poll()
            if (dropped == null) break
            log("队列已满（$MAX_QUEUE），丢弃最旧一条")
        }
        queue.add(line)
        flush()
        retryLater(id)
    }

    /** 发送必须串行：多条通知同时到时分片会交错，粘成一行 */
    private val sendLock = Any()

    /** 最近一次「发送」与「通知已发出确认」的时间，用来发现死连接 */
    @Volatile private var lastSendAt = 0L
    @Volatile private var lastAckAt = 0L

    private data class Pending(var line: String, var tries: Int)
    private val pending = java.util.concurrent.ConcurrentHashMap<String, Pending>()
    private val acked = java.util.Collections.newSetFromMap(java.util.concurrent.ConcurrentHashMap<String, Boolean>())
    private var seq = 0
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    /** Mac 回执：收到 "ACK <id>" 就认为这条已送达 */
    fun onAck(id: String) {
        acked.add(id)
        pending.remove(id)
        log("Mac 已确认 #$id")
    }

    private fun retryLater(id: String) {
        handler.postDelayed({
            val p = pending[id] ?: return@postDelayed
            if (acked.contains(id)) return@postDelayed
            if (p.tries >= 3) {
                pending.remove(id)
                log("重发 3 次仍无回执，放弃 #$id，重建连接")
                dropStaleLink()
                return@postDelayed
            }
            p.tries += 1
            log("未收到回执，第 ${p.tries} 次重发 #$id")
            queue.add(p.line)
            flush()
        }, 4000)
    }

    fun markAck() {
        lastAckAt = System.currentTimeMillis()
    }

    /** BLE notify 不需要对方确认：如果发了很久一次 onNotificationSent 都没回来，说明链路已死 */
    private fun linkLooksDead(): Boolean {
        if (!connected) return false
        if (lastAckAt == 0L) return false
        val now = System.currentTimeMillis()
        return lastSendAt > lastAckAt && now - lastSendAt > 15_000
    }

    private fun dropStaleLink() {
        log("蓝牙链路疑似失效，主动断开等 Mac 重连")
        connected = false
        lastAckAt = 0
        lastSendAt = 0
        val dev = central
        central = null
        // 注意：这里**不能**清 txChar。它是 GATT 服务里的特征值，与「当前连接」无关；
        // 清掉之后即使 Mac 重连成功，sendBle 也会一直因为 ch == null 返回 false，
        // 表现就是「已连接但发不出去」，且只能重启 App 才能恢复。
        try { if (dev != null) server?.cancelConnection(dev) } catch (e: Exception) { }
    }

    fun flush() {
        synchronized(sendLock) {
            if (linkLooksDead()) {
                dropStaleLink()
                scheduleFlush()
                return
            }
            while (queue.isNotEmpty()) {
                val line = queue.peek() ?: break
                val viaBle = sendBle(line)
                val viaTcp = !viaBle && sendTcp(line)
                if (!viaBle && !viaTcp) {
                    log("发送失败：${bleStateText()}；${tcpStateText()}；队列 ${queue.size} 条，稍后重试")
                    scheduleFlush()
                    break
                }
                queue.poll()
                log(if (viaBle) "已通过蓝牙发送（队列剩 ${queue.size}）" else "已通过 TCP 发送（队列剩 ${queue.size}）")
            }
        }
    }

    /** 失败原因：说清楚到底卡在哪一环，别再一律报「蓝牙未连接」 */
    private fun bleStateText(): String = when {
        server == null -> "BLE 服务未就绪"
        txChar == null -> "BLE 特征值丢失"
        central == null -> "BLE 无设备连接"
        !connected -> "BLE 未连接"
        else -> "BLE 已连接但发送被拒"
    }

    private fun tcpStateText(): String =
        if (tcp?.isConnected == true) "TCP 已连但写入失败" else "TCP 未连接"

    @Volatile private var flushScheduled = false

    /** 失败后自动重试一次，而不是干等下一条通知来触发 */
    private fun scheduleFlush(delayMs: Long = 3_000) {
        if (flushScheduled) return
        flushScheduled = true
        handler.postDelayed({
            flushScheduled = false
            flush()
        }, delayMs)
    }

    private fun sendBle(line: String): Boolean {
        val srv = server ?: return false
        val ch = txChar ?: return false
        val dev = central ?: return false
        if (!connected) return false
        lastSendAt = System.currentTimeMillis()
        val bytes = line.toByteArray(Charsets.UTF_8)
        // 20 字节一片：不依赖 MTU 协商结果，最保守也最稳
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + 20, bytes.size)
            val chunk = bytes.copyOfRange(offset, end)
            ch.value = chunk
            val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                srv.notifyCharacteristicChanged(dev, ch, false, chunk) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                srv.notifyCharacteristicChanged(dev, ch, false)
                true
            }
            if (!ok) {
                log("蓝牙分片发送失败，停止本条")
                return false
            }
            offset = end
            // 给控制器一点时间，避免拥塞丢包
            try { Thread.sleep(8) } catch (e: InterruptedException) { }
        }
        return true
    }

    private var tcp: Socket? = null
    private var tcpOut: OutputStream? = null

    private fun sendTcp(line: String): Boolean {
        try {
            if (tcp?.isConnected != true) {
                val s = Socket("127.0.0.1", 8765)
                s.tcpNoDelay = true
                tcp = s
                tcpOut = s.getOutputStream()
            }
            tcpOut?.write(line.toByteArray(Charsets.UTF_8))
            tcpOut?.flush()
            return true
        } catch (e: Exception) {
            try { tcp?.close() } catch (e: Exception) { }
            tcp = null
            tcpOut = null
            return false
        }
    }
}

class BridgeService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Link.pairCode = getSharedPreferences("phonebridge", MODE_PRIVATE)
            .getString("pairCode", "") ?: ""
        startForegroundWithChannel()
        Link.startHeartbeat()
        startBle()
    }

    private fun startForegroundWithChannel() {
        val id = "phonebridge"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(id) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(id, "PhoneBridge", NotificationManager.IMPORTANCE_MIN)
                )
            }
            val n = Notification.Builder(this, id)
                .setContentTitle("PhoneBridge 运行中")
                .setContentText("通知会转发到 Mac，不上传任何服务器")
                .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .build()
            startForeground(1, n)
        }
    }

    private fun startBle() {
        val mgr = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter: BluetoothAdapter = mgr.adapter ?: return
        if (!adapter.isEnabled) return

        // callback 里要引用 server 本身（sendResponse），初始化表达式里不能直接引用自己，
        // 所以先用一个数组占位，openGattServer 返回后再填。
        val holder = arrayOfNulls<BluetoothGattServer>(1)

        val server = mgr.openGattServer(this, object : BluetoothGattServerCallback() {
            override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
                val isBonded = device?.bondState == BluetoothDevice.BOND_BONDED
                Link.connected = newState == BluetoothGatt.STATE_CONNECTED && device != null
                Link.central = if (newState == BluetoothGatt.STATE_CONNECTED) device else null
                if (newState == BluetoothGatt.STATE_CONNECTED && Link.txChar == null) {
                    // 兜底：特征值属于服务，理论上不该为空；万一被清掉，连上时补回来
                    Link.txChar = holder[0]?.getService(Link.serviceUUID)?.getCharacteristic(Link.txUUID)
                }
                // status 很关键：133 = GATT 栈内部错误（常见于配对信息不一致），
                // 8 = 连接超时，19 = 对端主动断开。只打 newState 会让这类问题无法定位。
                Link.log("BLE 连接状态 newState=$newState status=$status 已配对=$isBonded")
                if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                    // 关键修复：不少机型（含小米/HyperOS）在建立连接后会停掉广播，
                    // 断开时不重新广播，Mac 就永远扫不到这台手机——表现为「不会自动重连」。
                    handler.postDelayed({ startAdvertise("断开后恢复广播") }, 800)
                }
                if (newState == BluetoothGatt.STATE_CONNECTED && device != null && !isBonded) {
                    // 安全：连上但没配对，主动发起绑定；配对完成前不接收任何数据
                    Link.log("发起蓝牙配对（需要两端确认）…")
                    try {
                        device.createBond()
                    } catch (e: Exception) {
                        Link.log("发起配对失败：${e.message}")
                    }
                }
                Link.flush()
            }

            override fun onDescriptorWriteRequest(
                device: BluetoothDevice?,
                requestId: Int,
                descriptor: BluetoothGattDescriptor?,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray?
            ) {
                if (device == null) return
                if (responseNeeded) {
                    holder[0]?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
                Link.connected = true
                Link.central = device
                Link.log("Mac 已订阅，通道就绪（配对=${device.bondState == BluetoothDevice.BOND_BONDED}）")
                Link.flush()
            }

            override fun onCharacteristicWriteRequest(
                device: BluetoothDevice?,
                requestId: Int,
                characteristic: BluetoothGattCharacteristic?,
                preparedWrite: Boolean,
                responseNeeded: Boolean,
                offset: Int,
                value: ByteArray?
            ) {
                if (responseNeeded && device != null) {
                    holder[0]?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                }
                if (characteristic?.uuid == Link.rxUUID && value != null) {
                    val text = String(value, Charsets.UTF_8).trim()
                    if (text.startsWith("ACK ")) Link.onAck(text.removePrefix("ACK ").trim())
                }
            }

            override fun onNotificationSent(device: BluetoothDevice?, status: Int) {
                Link.markAck()
                Link.flush()
            }
        }) ?: return

        holder[0] = server

        val service = BluetoothGattService(Link.serviceUUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val tx = BluetoothGattCharacteristic(
            Link.txUUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        tx.addDescriptor(
            BluetoothGattDescriptor(
                UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"),
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE
            )
        )
        service.addCharacteristic(tx)
        val rx = BluetoothGattCharacteristic(
            Link.rxUUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        service.addCharacteristic(rx)
        server.addService(service)

        Link.server = server
        Link.txChar = tx

        advertiser = adapter.bluetoothLeAdvertiser
        advSettings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .build()
        advData = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(Link.serviceUUID))
            .setIncludeDeviceName(true)
            .build()
        startAdvertise("启动广播")
    }

    private var advertiser: BluetoothLeAdvertiser? = null
    private var advSettings: AdvertiseSettings? = null
    private var advData: AdvertiseData? = null
    private var advRunning = false
    private var advRetries = 0
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    private val advCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            advRunning = true
            advRetries = 0
            Link.log("蓝牙广播已开启")
        }

        override fun onStartFailure(errorCode: Int) {
            advRunning = false
            Link.log("蓝牙广播失败 code=$errorCode（缺「附近的设备」权限、蓝牙被关，或已被系统停掉）")
            // 广播起不来就等于隐身：退避重试，最多 5 次
            if (advRetries < 5) {
                advRetries += 1
                handler.postDelayed({ startAdvertise("广播失败重试 #$advRetries") }, 2_000L * advRetries)
            }
        }
    }

    /** 幂等：先停再起，断开/失败/被系统停掉后都能把广播拉回来 */
    private fun startAdvertise(tag: String) {
        val adv = advertiser ?: return
        val settings = advSettings ?: return
        val data = advData ?: return
        try { if (advRunning) adv.stopAdvertising(advCallback) } catch (e: Exception) { }
        advRunning = false
        Link.log("$tag（重启广播）")
        try {
            adv.startAdvertising(settings, data, advCallback)
        } catch (e: Exception) {
            Link.log("广播启动异常：${e.message}")
        }
    }

    override fun onDestroy() {
        try { if (advRunning) advertiser?.stopAdvertising(advCallback) } catch (e: Exception) { }
        Link.server?.close()
        Link.server = null
        super.onDestroy()
    }
}

class NotifListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val n = sbn.notification
        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT))?.toString().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return

        // 只转发用户勾选的包，默认放行短信/微信/验证器类
        val prefs = getSharedPreferences("phonebridge", MODE_PRIVATE)
        val allowed = prefs.getStringSet("packages", null)
        if (allowed != null && allowed.isNotEmpty() && !allowed.contains(sbn.packageName)) return

        val app = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString()
        } catch (e: Exception) { sbn.packageName }

        // 记录见过的 App：小米可能不给「应用列表」权限，白名单就靠这份记录
        run {
            val seen = prefs.getStringSet("seen", null)?.toMutableSet() ?: mutableSetOf()
            if (seen.add(sbn.packageName)) {
                prefs.edit().putStringSet("seen", seen).apply()
            }
            prefs.edit().putString("label_" + sbn.packageName, app).apply()
        }

        Link.push(sbn.packageName, app, title, text)
    }
}
