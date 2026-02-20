package com.audiolink.receiver

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {
    private lateinit var portInput: EditText
    private lateinit var jitterInput: EditText
    private lateinit var statusText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        portInput = findViewById(R.id.portInput)
        jitterInput = findViewById(R.id.jitterInput)
        statusText = findViewById(R.id.statusText)

        findViewById<Button>(R.id.startButton).setOnClickListener {
            val port = portInput.text.toString().toIntOrNull() ?: 50000
            val jitterMs = jitterInput.text.toString().toIntOrNull() ?: 20

            val intent = Intent(this, UdpAudioService::class.java).apply {
                action = UdpAudioService.ACTION_START
                putExtra(UdpAudioService.EXTRA_PORT, port)
                putExtra(UdpAudioService.EXTRA_JITTER_MS, jitterMs)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            statusText.setText(R.string.status_running)
        }

        findViewById<Button>(R.id.stopButton).setOnClickListener {
            val intent = Intent(this, UdpAudioService::class.java).apply {
                action = UdpAudioService.ACTION_STOP
            }
            startService(intent)
            statusText.setText(R.string.status_idle)
        }
    }
}
