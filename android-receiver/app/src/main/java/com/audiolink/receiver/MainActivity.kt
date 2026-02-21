package com.audiolink.receiver

import android.Manifest
import android.app.ActivityManager
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.ArrayAdapter
import android.widget.AutoCompleteTextView
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.material.chip.Chip
import com.google.android.material.tabs.TabLayout

class MainActivity : AppCompatActivity() {
    private lateinit var tabLayout: TabLayout
    private lateinit var rxContainer: View
    private lateinit var txContainer: View

    private lateinit var rxPortInput: EditText
    private lateinit var rxJitterInput: EditText
    private lateinit var rxTransportInput: AutoCompleteTextView

    private lateinit var targetIpInput: EditText
    private lateinit var micPortInput: EditText
    private lateinit var micFrameInput: EditText
    private lateinit var micTransportInput: AutoCompleteTextView
    private lateinit var micSourceInput: AutoCompleteTextView
    private lateinit var rxToggleButton: Button
    private lateinit var txToggleButton: Button

    private lateinit var rxStatusChip: Chip
    private lateinit var rxStatusDetail: TextView
    private lateinit var txStatusChip: Chip
    private lateinit var txStatusDetail: TextView
    private lateinit var statusText: TextView

    private var pendingMicStart = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        bindViews()
        setupTabs()
        setupDropdowns()
        setupActions()
        refreshServiceStatus()
    }

    override fun onResume() {
        super.onResume()
        refreshServiceStatus()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_RECORD_AUDIO) return

        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        if (granted && pendingMicStart) {
            pendingMicStart = false
            startMicSender()
        } else {
            pendingMicStart = false
            setGlobalStatus(getString(R.string.status_mic_perm_needed))
            updateSenderIndicator(
                getString(R.string.status_tx_needs_permission),
                getString(R.string.status_tx_perm_detail),
                COLOR_WARNING
            )
        }
    }

    private fun bindViews() {
        tabLayout = findViewById(R.id.tabLayout)
        rxContainer = findViewById(R.id.rxContainer)
        txContainer = findViewById(R.id.txContainer)

        rxPortInput = findViewById(R.id.rxPortInput)
        rxJitterInput = findViewById(R.id.rxJitterInput)
        rxTransportInput = findViewById(R.id.rxTransportInput)

        targetIpInput = findViewById(R.id.targetIpInput)
        micPortInput = findViewById(R.id.micPortInput)
        micFrameInput = findViewById(R.id.micFrameInput)
        micTransportInput = findViewById(R.id.micTransportInput)
        micSourceInput = findViewById(R.id.micSourceInput)
        rxToggleButton = findViewById(R.id.rxToggleButton)
        txToggleButton = findViewById(R.id.txToggleButton)

        rxStatusChip = findViewById(R.id.rxStatusChip)
        rxStatusDetail = findViewById(R.id.rxStatusDetail)
        txStatusChip = findViewById(R.id.txStatusChip)
        txStatusDetail = findViewById(R.id.txStatusDetail)
        statusText = findViewById(R.id.statusText)
    }

    private fun setupTabs() {
        if (tabLayout.tabCount == 0) {
            tabLayout.addTab(tabLayout.newTab().setText(R.string.tab_receiver))
            tabLayout.addTab(tabLayout.newTab().setText(R.string.tab_sender))
        }
        showTab(0)
        tabLayout.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab) {
                showTab(tab.position)
            }

            override fun onTabUnselected(tab: TabLayout.Tab) = Unit
            override fun onTabReselected(tab: TabLayout.Tab) = Unit
        })
    }

    private fun setupDropdowns() {
        setDefaultIfEmpty(rxPortInput, "50000")
        setDefaultIfEmpty(rxJitterInput, "20")
        setupDropdown(rxTransportInput, listOf(UdpAudioService.TRANSPORT_UDP, UdpAudioService.TRANSPORT_TCP), UdpAudioService.TRANSPORT_UDP)

        setDefaultIfEmpty(micPortInput, "50010")
        setDefaultIfEmpty(micFrameInput, "5")
        setupDropdown(micTransportInput, listOf(MicSenderService.TRANSPORT_TCP, MicSenderService.TRANSPORT_UDP), MicSenderService.TRANSPORT_TCP)
        setupDropdown(
            micSourceInput,
            listOf(
                MicSenderService.INPUT_MODE_AUTO,
                MicSenderService.INPUT_MODE_PHONE,
                MicSenderService.INPUT_MODE_BLUETOOTH
            ),
            MicSenderService.INPUT_MODE_AUTO
        )
    }

    private fun setupActions() {
        rxToggleButton.setOnClickListener {
            if (isServiceRunning(UdpAudioService::class.java)) {
                stopReceiver()
            } else {
                startReceiver()
            }
        }
        txToggleButton.setOnClickListener {
            if (isServiceRunning(MicSenderService::class.java)) {
                stopMicSender()
            } else {
                startMicSenderWithPermission()
            }
        }
    }

    private fun startReceiver() {
        val port = rxPortInput.text.toString().toIntOrNull() ?: 50000
        val jitterMs = rxJitterInput.text.toString().toIntOrNull() ?: 20
        val transport = normalizeTransport(rxTransportInput.text.toString())

        val intent = Intent(this, UdpAudioService::class.java).apply {
            action = UdpAudioService.ACTION_START
            putExtra(UdpAudioService.EXTRA_PORT, port)
            putExtra(UdpAudioService.EXTRA_JITTER_MS, jitterMs)
            putExtra(UdpAudioService.EXTRA_TRANSPORT, transport)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }

        val detail = getString(R.string.status_rx_detail_fmt, port, jitterMs, transport)
        updateReceiverIndicator(getString(R.string.status_rx_running), detail, COLOR_OK)
        setGlobalStatus(getString(R.string.status_running))
        updateToggleButtons(receiverRunning = true, senderRunning = isServiceRunning(MicSenderService::class.java))
    }

    private fun stopReceiver() {
        val intent = Intent(this, UdpAudioService::class.java).apply {
            action = UdpAudioService.ACTION_STOP
        }
        startService(intent)

        updateReceiverIndicator(
            getString(R.string.status_rx_stopped),
            getString(R.string.status_rx_detail_idle),
            COLOR_STOPPED
        )
        setGlobalStatus(getString(R.string.status_idle))
        updateToggleButtons(receiverRunning = false, senderRunning = isServiceRunning(MicSenderService::class.java))
    }

    private fun startMicSenderWithPermission() {
        val inputMode = normalizeInputMode(micSourceInput.text.toString())
        if (!canStartMicForInputMode(inputMode)) {
            pendingMicStart = true
            val permissions = mutableListOf(Manifest.permission.RECORD_AUDIO)
            if (inputMode == MicSenderService.INPUT_MODE_BLUETOOTH && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                permissions += Manifest.permission.BLUETOOTH_CONNECT
            }
            ActivityCompat.requestPermissions(this, permissions.toTypedArray(), REQ_RECORD_AUDIO)
            setGlobalStatus(getString(R.string.status_mic_perm_needed))
            return
        }
        startMicSender()
    }

    private fun startMicSender() {
        val targetIp = targetIpInput.text.toString().trim()
        val port = micPortInput.text.toString().toIntOrNull() ?: 50010
        val frameMs = micFrameInput.text.toString().toIntOrNull() ?: 5
        val transport = normalizeTransport(micTransportInput.text.toString())
        val inputMode = normalizeInputMode(micSourceInput.text.toString())

        if (targetIp.isBlank()) {
            updateSenderIndicator(
                getString(R.string.status_tx_invalid_target),
                getString(R.string.status_tx_invalid_target_detail),
                COLOR_WARNING
            )
            setGlobalStatus(getString(R.string.status_tx_invalid_target))
            return
        }

        val intent = Intent(this, MicSenderService::class.java).apply {
            action = MicSenderService.ACTION_START
            putExtra(MicSenderService.EXTRA_TARGET_IP, targetIp)
            putExtra(MicSenderService.EXTRA_PORT, port)
            putExtra(MicSenderService.EXTRA_FRAME_MS, frameMs)
            putExtra(MicSenderService.EXTRA_TRANSPORT, transport)
            putExtra(MicSenderService.EXTRA_INPUT_MODE, inputMode)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }

        val detail = getString(R.string.status_tx_detail_fmt, targetIp, port, frameMs, transport, inputMode)
        updateSenderIndicator(getString(R.string.status_tx_running), detail, COLOR_OK)
        setGlobalStatus(getString(R.string.status_mic_running))
        updateToggleButtons(receiverRunning = isServiceRunning(UdpAudioService::class.java), senderRunning = true)
    }

    private fun stopMicSender() {
        val intent = Intent(this, MicSenderService::class.java).apply {
            action = MicSenderService.ACTION_STOP
        }
        startService(intent)

        updateSenderIndicator(
            getString(R.string.status_tx_stopped),
            getString(R.string.status_tx_detail_idle),
            COLOR_STOPPED
        )
        setGlobalStatus(getString(R.string.status_mic_stopped))
        updateToggleButtons(receiverRunning = isServiceRunning(UdpAudioService::class.java), senderRunning = false)
    }

    private fun refreshServiceStatus() {
        val receiverRunning = isServiceRunning(UdpAudioService::class.java)
        val senderRunning = isServiceRunning(MicSenderService::class.java)

        if (receiverRunning) {
            val detail = getString(
                R.string.status_rx_detail_fmt,
                rxPortInput.text.toString().toIntOrNull() ?: 50000,
                rxJitterInput.text.toString().toIntOrNull() ?: 20,
                normalizeTransport(rxTransportInput.text.toString())
            )
            updateReceiverIndicator(getString(R.string.status_rx_running), detail, COLOR_OK)
        } else {
            updateReceiverIndicator(
                getString(R.string.status_rx_stopped),
                getString(R.string.status_rx_detail_idle),
                COLOR_STOPPED
            )
        }

        if (senderRunning) {
            val detail = getString(
                R.string.status_tx_detail_fmt,
                targetIpInput.text.toString().trim().ifBlank { "-" },
                micPortInput.text.toString().toIntOrNull() ?: 50010,
                micFrameInput.text.toString().toIntOrNull() ?: 5,
                normalizeTransport(micTransportInput.text.toString()),
                normalizeInputMode(micSourceInput.text.toString())
            )
            updateSenderIndicator(getString(R.string.status_tx_running), detail, COLOR_OK)
        } else {
            updateSenderIndicator(
                getString(R.string.status_tx_stopped),
                getString(R.string.status_tx_detail_idle),
                COLOR_STOPPED
            )
        }
        updateToggleButtons(receiverRunning, senderRunning)
    }

    private fun showTab(index: Int) {
        rxContainer.visibility = if (index == 0) View.VISIBLE else View.GONE
        txContainer.visibility = if (index == 1) View.VISIBLE else View.GONE
    }

    private fun setupDropdown(view: AutoCompleteTextView, options: List<String>, defaultValue: String) {
        val adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, options)
        view.setAdapter(adapter)
        if (view.text.isNullOrBlank()) {
            view.setText(defaultValue, false)
        }
    }

    private fun setDefaultIfEmpty(view: EditText, defaultValue: String) {
        if (view.text.isNullOrBlank()) {
            view.setText(defaultValue)
        }
    }

    private fun updateToggleButtons(receiverRunning: Boolean, senderRunning: Boolean) {
        rxToggleButton.text = if (receiverRunning) {
            getString(R.string.stop_rx)
        } else {
            getString(R.string.start_rx)
        }
        txToggleButton.text = if (senderRunning) {
            getString(R.string.stop_tx)
        } else {
            getString(R.string.start_tx)
        }
    }

    private fun updateReceiverIndicator(title: String, detail: String, color: Int) {
        rxStatusChip.text = title
        rxStatusChip.chipBackgroundColor = ColorStateList.valueOf(color)
        rxStatusDetail.text = detail
    }

    private fun updateSenderIndicator(title: String, detail: String, color: Int) {
        txStatusChip.text = title
        txStatusChip.chipBackgroundColor = ColorStateList.valueOf(color)
        txStatusDetail.text = detail
    }

    private fun setGlobalStatus(text: String) {
        statusText.text = text
    }

    private fun normalizeInputMode(raw: String): String {
        return when (raw.trim().lowercase()) {
            MicSenderService.INPUT_MODE_BLUETOOTH -> MicSenderService.INPUT_MODE_BLUETOOTH
            MicSenderService.INPUT_MODE_PHONE -> MicSenderService.INPUT_MODE_PHONE
            else -> MicSenderService.INPUT_MODE_AUTO
        }
    }

    private fun normalizeTransport(raw: String): String {
        return if (raw.trim().lowercase() == UdpAudioService.TRANSPORT_TCP) {
            UdpAudioService.TRANSPORT_TCP
        } else {
            UdpAudioService.TRANSPORT_UDP
        }
    }

    private fun canStartMicForInputMode(inputMode: String): Boolean {
        if (!hasRecordAudioPermission()) return false
        if (inputMode == MicSenderService.INPUT_MODE_BLUETOOTH && !hasBluetoothConnectPermission()) {
            return false
        }
        return true
    }

    private fun hasRecordAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasBluetoothConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.BLUETOOTH_CONNECT
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun isServiceRunning(serviceClass: Class<out Service>): Boolean {
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        @Suppress("DEPRECATION")
        return manager.getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == serviceClass.name }
    }

    companion object {
        private const val REQ_RECORD_AUDIO = 1001
        private val COLOR_OK = Color.parseColor("#2E7D32")
        private val COLOR_WARNING = Color.parseColor("#B26A00")
        private val COLOR_STOPPED = Color.parseColor("#616161")
    }
}
