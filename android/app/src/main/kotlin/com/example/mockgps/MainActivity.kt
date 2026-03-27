package com.example.mockgps

import android.content.Context
import android.content.Intent
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.SystemClock
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Timer
import java.util.TimerTask

class MainActivity: FlutterActivity() {
    
    private val CHANNEL = "mock_location_channel"
    private var locationManager: LocationManager? = null
    private var mockTimer: Timer? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        
        super.configureFlutterEngine(flutterEngine)
        
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            
            when (call.method) {
                
                "startMocking" -> {
                    val lat = call.argument<Double>("lat")
                    val lng = call.argument<Double>("lng")
                    
                    if (lat != null && lng != null) {
                        startMockLocation(lat, lng)
                        result.success(null)
                    } else {
                        result.error("INVALID_ARGS", "Lat o Lng es nulo", null)
                    }
                }
                
                "stopMocking" -> {
                    stopMockLocation()
                    result.success(null)
                }
                
                "openTimeSettings" -> {
                    try {
                        val intent = Intent(android.provider.Settings.ACTION_DATE_SETTINGS)
                        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INTENT_ERROR", "No se pudo abrir la configuración", null)
                    }
                }
                
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun startMockLocation(lat: Double, lng: Double) {
        
        stopMockLocation() 

        try {
            locationManager?.addTestProvider(
                LocationManager.GPS_PROVIDER,
                false, 
                false, 
                false, 
                false, 
                true, 
                true, 
                true, 
                0, 
                5
            )
            locationManager?.setTestProviderEnabled(LocationManager.GPS_PROVIDER, true)
        } catch (e: SecurityException) {
            e.printStackTrace()
            return
        } catch (e: IllegalArgumentException) {
            // El proveedor ya existe
        }

        mockTimer = Timer()
        mockTimer?.scheduleAtFixedRate(object : TimerTask() {
            override fun run() {
                try {
                    val mockLocation = Location(LocationManager.GPS_PROVIDER)
                    mockLocation.latitude = lat
                    mockLocation.longitude = lng
                    mockLocation.altitude = 10.0
                    mockLocation.time = System.currentTimeMillis()
                    mockLocation.accuracy = 1.0f
                    
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
                        mockLocation.elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
                    }
                    
                    locationManager?.setTestProviderLocation(LocationManager.GPS_PROVIDER, mockLocation)
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }, 0, 1000)
    }

    private fun stopMockLocation() {
        
        if (mockTimer != null) {
            mockTimer?.cancel()
            mockTimer = null
        }
        
        try {
            locationManager?.removeTestProvider(LocationManager.GPS_PROVIDER)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
    
    override fun onDestroy() {
        
        stopMockLocation()
        super.onDestroy()
        
    }
}
