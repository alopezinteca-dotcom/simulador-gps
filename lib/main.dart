import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:utm/utm.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InspectorProApp());
}

/// ============================================================================
/// MÓDULO 1: LA APLICACIÓN BASE
/// ============================================================================
class InspectorProApp extends StatelessWidget {
  const InspectorProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'INSPECTOR PRO 3',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF263238), primary: const Color(0xFF1976D2)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: const MapScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// ============================================================================
/// MÓDULO 2: SERVICIOS NATIVOS Y DE VALIDACIÓN
/// ============================================================================
class LocationService {
  static const MethodChannel _channel = MethodChannel('mock_location_channel');
  
  Future<String?> getSharedText() async {
    try {
      final String? result = await _channel.invokeMethod('getSharedText');
      return result;
    } catch (e) {
      return null;
    }
  }

  Future<String> startMocking(String latStr, String lngStr) async {
    try {
      await _channel.invokeMethod('startMocking', {'lat': latStr, 'lng': lngStr});
      return "SUCCESS";
    } on PlatformException catch (e) {
      return "ERROR";
    } catch (e) {
      return "ERROR";
    }
  }
  
  Future<bool> stopMocking() async {
    try {
      await _channel.invokeMethod('stopMocking');
      return true;
    } catch (e) {
      return false;
    }
  }
}

class SystemSettingsService {
  static const MethodChannel _channel = MethodChannel('mock_location_channel');
  Future<bool> openTimeSettings() async {
    try {
      await _channel.invokeMethod('openTimeSettings');
      return true;
    } catch (e) {
      return false;
    }
  }
}

class ValidationService {
  static const double maxSpeedKmh = 120.0;
  
  static double _calculateDistance(LatLng p1, LatLng p2) {
    const R = 6371e3;
    final phi1 = p1.latitude * pi / 180;
    final phi2 = p2.latitude * pi / 180;
    final deltaPhi = (p2.latitude - p1.latitude) * pi / 180;
    final deltaLambda = (p2.longitude - p1.longitude) * pi / 180;

    final a = sin(deltaPhi / 2) * sin(deltaPhi / 2) +
              cos(phi1) * cos(phi2) *
              sin(deltaLambda / 2) * sin(deltaLambda / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  static String? checkJumpConsistency(LatLng oldPos, DateTime oldTime, LatLng newPos) {
    final double distanceMeters = _calculateDistance(oldPos, newPos);
    final double timeSeconds = DateTime.now().difference(oldTime).inSeconds.toDouble();
    if (timeSeconds <= 0 || distanceMeters < 5) return null; 
    final double speedMs = distanceMeters / timeSeconds;
    final double speedKmh = speedMs * 3.6;
    if (speedKmh > maxSpeedKmh) {
      return "⚠️ Salto de ${distanceMeters.toStringAsFixed(0)}m detectado.\nVelocidad calculada: ${speedKmh.toStringAsFixed(0)} km/h.";
    }
    return null;
  }

  static String? checkSpainBounds(LatLng pos) {
    if (pos.latitude < 35.0 || pos.latitude > 44.0 || pos.longitude < -10.0 || pos.longitude > 5.0) {
      return "⚠️ Coordenada fuera de España. Revisa los datos.";
    }
    return null;
  }
}

/// ============================================================================
/// MÓDULO 3: CEREBRO DE CONVERSIÓN Y EXTRACCIÓN DE GOOGLE MAPS
/// ============================================================================
class CoordinateConverter {
  static LatLng? parseInput(String input) {
    String clean = input.trim().toUpperCase();
    if (clean.isEmpty) return null;

    try {
      if (clean.contains('.') || clean.contains(',')) {
        String numClean = clean.replaceAll('º', '').replaceAll('°', '').replaceAll(' ', '');
        List<String> parts = numClean.split(RegExp(r'[,|;]'));
        if (parts.length >= 2) {
          double lat = double.parse(parts[0]);
          double lng = double.parse(parts[1]);
          return LatLng(double.parse(lat.toStringAsFixed(7)), double.parse(lng.toStringAsFixed(7)));
        }
      }
    } catch (_) {}

    try {
      List<String> parts = clean.split(RegExp(r'\s+'));
      if (parts.length >= 3) {
        String zoneStr = parts[0];
        int zoneNum = int.parse(zoneStr.replaceAll(RegExp(r'[A-Z]'), ''));
        String zoneLetter = zoneStr.replaceAll(RegExp(r'[0-9]'), '');
        double easting = double.parse(parts[1]);
        double northing = double.parse(parts[2]);
        final latlon = UTM.fromUtm(easting: easting, northing: northing, zoneNumber: zoneNum, zoneLetter: zoneLetter);
        return LatLng(double.parse(latlon.lat.toStringAsFixed(7)), double.parse(latlon.lon.toStringAsFixed(7)));
      }
    } catch (_) {}

    return null; 
  }
}

class GeocodingService {
  Future<LatLng?> searchAddress(String query) async {
    final LatLng? parsed = CoordinateConverter.parseInput(query);
    if (parsed != null) return parsed;

    // MEJORA: Regex reforzado para atrapar todas las variantes de Google Maps
    final urlMatch = RegExp(r'(https?://[^\s]+)').firstMatch(query);
    if (urlMatch != null) {
      String url = urlMatch.group(0)!;
      try {
        final getRes = await http.get(Uri.parse(url));
        String finalUrl = getRes.request?.url.toString() ?? url;

        final atMatch = RegExp(r'@(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(finalUrl);
        if (atMatch != null) {
          double lat = double.parse(atMatch.group(1)!);
          double lng = double.parse(atMatch.group(2)!);
          return LatLng(double.parse(lat.toStringAsFixed(7)), double.parse(lng.toStringAsFixed(7)));
        }
        
        final dMatch = RegExp(r'!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)').firstMatch(finalUrl);
        if (dMatch != null) {
          double lat = double.parse(dMatch.group(1)!);
          double lng = double.parse(dMatch.group(2)!);
          return LatLng(double.parse(lat.toStringAsFixed(7)), double.parse(lng.toStringAsFixed(7)));
        }

        final qMatch = RegExp(r'q=(-?\d+\.\d+),(-?\d+\.\d+)').firstMatch(finalUrl);
        if (qMatch != null) {
          double lat = double.parse(qMatch.group(1)!);
          double lng = double.parse(qMatch.group(2)!);
          return LatLng(double.parse(lat.toStringAsFixed(7)), double.parse(lng.toStringAsFixed(7)));
        }
      } catch (e) {
        debugPrint("Error resolviendo URL Maps: $e");
      }
    }

    final Uri nominatimUrl = Uri.parse('https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(query)}&format=json&limit=1');
    try {
      final response = await http.get(nominatimUrl, headers: {'User-Agent': 'InspectorPro3'});
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        if (data.isNotEmpty) {
          final double lat = double.parse(data[0]['lat'].toString());
          final double lon = double.parse(data[0]['lon'].toString());
          return LatLng(double.parse(lat.toStringAsFixed(7)), double.parse(lon.toStringAsFixed(7)));
        }
      }
    } catch (e) {}
    
    return null;
  }
}

/// ============================================================================
/// MÓDULO 4: LA PANTALLA PRINCIPAL
/// ============================================================================
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  final LocationService _locationService = LocationService();
  final GeocodingService _geocodingService = GeocodingService();
  final SystemSettingsService _systemSettingsService = SystemSettingsService();
  
  LatLng _center = const LatLng(36.7213000, -4.4214000); 
  bool _isMocking = false;
  bool _isSatellite = false; 
  bool _isLoadingSearch = false;
  
  bool _checkSpeed = true;
  bool _checkBounds = false;
  LatLng? _lastInjectedPos;
  DateTime? _lastInjectedTime;

  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _photos = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _loadAndCleanPhotos();
    _checkSharedLinks(); 
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSharedLinks();
    }
  }

  Future<void> _checkSharedLinks() async {
    final String? sharedText = await _locationService.getSharedText();
    if (sharedText != null && sharedText.isNotEmpty) {
      _searchController.text = sharedText;
      _processSearch(queryToProcess: sharedText);
    }
  }

  Future<void> _requestPermissions() async {
    await [Permission.locationWhenInUse, Permission.locationAlways].request();
  }

  void _microAdjust(double latOffset, double lngOffset) {
    if (_isMocking) return; // BLINDAJE: La cruceta se desactiva si el mock está encendido
    setState(() {
      double newLat = _center.latitude + latOffset;
      double newLng = _center.longitude + lngOffset;
      _center = LatLng(double.parse(newLat.toStringAsFixed(7)), double.parse(newLng.toStringAsFixed(7)));
      _mapController.move(_center, _mapController.camera.zoom);
    });
  }

  Future<void> _loadAndCleanPhotos() async {
    final prefs = await SharedPreferences.getInstance();
    final String? photosJson = prefs.getString('saved_photos');
    
    if (photosJson != null) {
      List<dynamic> decoded = json.decode(photosJson);
      List<Map<String, dynamic>> loadedPhotos = decoded.cast<Map<String, dynamic>>();
      
      loadedPhotos.removeWhere((f) {
        try {
          final date = DateTime.parse(f['timestamp']);
          if (DateTime.now().difference(date).inDays > 7) {
            if (f.containsKey('photo_path') && f['photo_path'] != null) {
              final file = File(f['photo_path']);
              if (file.existsSync()) file.deleteSync();
            }
            return true; 
          }
          return false;
        } catch (e) {
          return false;
        }
      });

      setState(() {
        _photos = loadedPhotos;
        _photos.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
      });
      _savePhotosToDisk(); 
    }
  }

  Future<void> _savePhotosToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_photos', json.encode(_photos));
  }

  Future<void> _takeForensicPhoto() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.camera, imageQuality: 80); 
    
    if (image == null) return;
    
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Estampando datos forenses...')));

    final File imgFile = File(image.path);
    final String latStr = _center.latitude.toStringAsFixed(7);
    final String lngStr = _center.longitude.toStringAsFixed(7);
    final String dateStr = DateFormat('dd/MM/yyyy HH:mm:ss').format(DateTime.now());

    try {
      final bytes = await imgFile.readAsBytes();
      img.Image? decodedImg = img.decodeImage(bytes);
      
      if (decodedImg != null) {
        int rectHeight = 60;
        img.fillRect(decodedImg, 
            x1: 0, y1: decodedImg.height - rectHeight, 
            x2: decodedImg.width, y2: decodedImg.height, 
            color: img.ColorRgba8(0, 0, 0, 150));
        
        // MEJORA: Texto limpio en mayúsculas ASCII para evitar crasheos de codificación
        final String watermark = "INSPECCION TECNICA | LAT: $latStr | LNG: $lngStr | $dateStr";
        img.drawString(decodedImg, watermark, font: img.arial_24, x: 20, y: decodedImg.height - 45, color: img.ColorRgb8(255, 255, 255));
        
        await imgFile.writeAsBytes(img.encodeJpg(decodedImg, quality: 90));
      }
    } catch (e) {
      debugPrint("Error al quemar marca de agua: $e");
    }
    
    setState(() {
      _photos.add({
        'lat': double.parse(latStr),
        'lng': double.parse(lngStr),
        'timestamp': DateTime.now().toIso8601String(),
        'photo_path': imgFile.path,
      });
      _photos.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
    });
    
    _savePhotosToDisk();
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Evidencia Forense Guardada.'), backgroundColor: Colors.green)
      );
    }
  }

  void _showPhotoGallery() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        if (_photos.isEmpty) {
          return const Padding(padding: EdgeInsets.all(24.0), child: Text('No hay fotos recientes.', style: TextStyle(fontSize: 16), textAlign: TextAlign.center));
        }
        return ListView.builder(
          itemCount: _photos.length,
          itemBuilder: (context, index) {
            final f = _photos[index];
            final DateTime date = DateTime.parse(f['timestamp']);
            final String timeString = DateFormat('dd/MM/yyyy HH:mm').format(date);
            final int daysLeft = 7 - DateTime.now().difference(date).inDays;
            
            Widget leadingIcon = const Icon(Icons.broken_image, color: Colors.grey);
            if (f.containsKey('photo_path') && f['photo_path'] != null) {
              final file = File(f['photo_path']);
              if (file.existsSync()) {
                leadingIcon = ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.file(file, width: 50, height: 50, fit: BoxFit.cover));
              }
            }
            
            return ListTile(
              leading: leadingIcon,
              title: Text(timeString, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Lat: ${f['lat'].toStringAsFixed(7)}\nLng: ${f['lng'].toStringAsFixed(7)}\nQuedan $daysLeft días'),
              isThreeLine: true,
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () {
                  if (f.containsKey('photo_path') && f['photo_path'] != null) {
                    final file = File(f['photo_path']);
                    if (file.existsSync()) file.deleteSync();
                  }
                  setState(() { _photos.removeAt(index); _savePhotosToDisk(); });
                  Navigator.pop(context); _showPhotoGallery();
                },
              ),
              onTap: () {
                Navigator.pop(context);
                final newPos = LatLng(f['lat'], f['lng']);
                _mapController.move(newPos, 16.0);
                setState(() => _center = newPos);
              },
            );
          },
        );
      }
    );
  }

  Future<void> _processSearch({String? queryToProcess}) async {
    final query = queryToProcess ?? _searchController.text;
    if (query.isEmpty) return;

    setState(() => _isLoadingSearch = true);
    FocusScope.of(context).unfocus();

    final LatLng? result = await _geocodingService.searchAddress(query);
    
    setState(() => _isLoadingSearch = false);

    if (result != null) {
      _mapController.move(result, 16.0);
      setState(() => _center = result);
    } else {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo interpretar el dato o URL.')));
    }
  }

  Future<void> _toggleMock() async {
    if (_isMocking) {
      await _locationService.stopMocking();
      setState(() => _isMocking = false);
    } else {
      var status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) {
        await _requestPermissions();
        return;
      }
      
      if (_checkBounds) {
        final String? boundsWarning = ValidationService.checkSpainBounds(_center);
        if (boundsWarning != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(boundsWarning), backgroundColor: Colors.orange));
        }
      }

      if (_checkSpeed && _lastInjectedPos != null && _lastInjectedTime != null) {
        final String? speedWarning = ValidationService.checkJumpConsistency(_lastInjectedPos!, _lastInjectedTime!, _center);
        if (speedWarning != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(speedWarning), backgroundColor: Colors.orange, duration: const Duration(seconds: 4)));
        }
      }

      final String finalLatStr = _center.latitude.toStringAsFixed(7);
      final String finalLngStr = _center.longitude.toStringAsFixed(7);

      final String result = await _locationService.startMocking(finalLatStr, finalLngStr);
      
      if (result == "SUCCESS") {
        setState(() {
          _isMocking = true;
          _lastInjectedPos = _center;
          _lastInjectedTime = DateTime.now();
        });
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error de permisos en Opciones de Desarrollador.')));
      }
    }
  }

  void _copyCoordinates() {
    final String textToCopy = '${_center.latitude.toStringAsFixed(7)}, ${_center.longitude.toStringAsFixed(7)}';
    Clipboard.setData(ClipboardData(text: textToCopy));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Coordenadas copiadas a precisión 7.'), backgroundColor: Colors.blueGrey, behavior: SnackBarBehavior.floating));
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Ajustes de Auditoría', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Divider(),
                  SwitchListTile(
                    title: const Text('Alerta de Velocidad (>120km/h)'),
                    subtitle: const Text('Avisa si hay un salto imposible'),
                    value: _checkSpeed,
                    onChanged: (bool value) {
                      setModalState(() => _checkSpeed = value);
                      setState(() => _checkSpeed = value);
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Límite Geográfico (España)'),
                    subtitle: const Text('Avisa si la coordenada está fuera'),
                    value: _checkBounds,
                    onChanged: (bool value) {
                      setModalState(() => _checkBounds = value);
                      setState(() => _checkBounds = value);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.access_time),
                    title: const Text('Ajustar Hora del Sistema'),
                    onTap: () {
                      Navigator.pop(context);
                      _systemSettingsService.openTimeSettings();
                    },
                  )
                ],
              ),
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        bool isTablet = constraints.maxWidth > 650;

        Widget mapArea = Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _center,
                initialZoom: 17.0,
                onPositionChanged: (pos, hasGesture) {
                  if (pos.center != null && !_isMocking) {
                    setState(() => _center = pos.center!);
                  }
                },
                interactionOptions: InteractionOptions(
                  flags: _isMocking ? InteractiveFlag.none : InteractiveFlag.all
                )
              ),
              children: [
                TileLayer(
                  urlTemplate: _isSatellite 
                    ? 'https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}'
                    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.v4.inspector',
                ),
                CircleLayer(
                  circles: [
                    CircleMarker(point: _center, radius: 15, useRadiusInMeter: true, color: Colors.yellowAccent.withOpacity(0.2), borderColor: Colors.yellow, borderStrokeWidth: 1),
                    CircleMarker(point: _center, radius: 5, useRadiusInMeter: true, color: Colors.greenAccent.withOpacity(0.3), borderColor: Colors.green, borderStrokeWidth: 2),
                  ]
                ),
              ],
            ),
            
            Center(child: Icon(_isMocking ? Icons.gps_fixed : Icons.add_circle_outline, color: _isMocking ? Colors.green : Colors.red, size: 40)),
            
            Positioned(
              top: 20, left: 15, right: 15,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.95), borderRadius: BorderRadius.circular(8), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(hintText: 'Pega enlace de Maps, UTM, DMS o Decimales...', border: InputBorder.none),
                        onSubmitted: (_) => _processSearch(),
                      ),
                    ),
                    _isLoadingSearch 
                      ? const Padding(padding: EdgeInsets.all(12.0), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(icon: const Icon(Icons.search, color: Colors.blue), onPressed: _processSearch),
                  ],
                ),
              ),
            ),
          ],
        );

        Widget controlPanel = Container(
          width: isTablet ? 380 : double.infinity,
          color: Colors.white,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: Colors.blueGrey[900],
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('PANEL TÉCNICO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    Row(
                      children: [
                        IconButton(icon: const Icon(Icons.photo_library, color: Colors.white), onPressed: _showPhotoGallery, tooltip: 'Historial', constraints: const BoxConstraints(), padding: EdgeInsets.zero),
                        const SizedBox(width: 16),
                        IconButton(icon: const Icon(Icons.settings, color: Colors.white), onPressed: _showSettings, tooltip: 'Ajustes', constraints: const BoxConstraints(), padding: EdgeInsets.zero),
                      ],
                    )
                  ],
                ),
              ),
              
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("WGS84 EXACTO (7 Dec)", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                          Text("Lat: ${_center.latitude.toStringAsFixed(7)}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          Text("Lng: ${_center.longitude.toStringAsFixed(7)}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          TextButton.icon(
                            icon: const Icon(Icons.copy, size: 16), label: const Text('Copiar'),
                            onPressed: _copyCoordinates, style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                          )
                        ],
                      ),
                    ),
                    if (!_isMocking)
                      Column(
                        children: [
                          IconButton(icon: const Icon(Icons.arrow_drop_up), padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () => _microAdjust(0.000009, 0)),
                          Row(
                            children: [
                              IconButton(icon: const Icon(Icons.arrow_left), padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () => _microAdjust(0, -0.000009 / cos(_center.latitude * pi / 180))),
                              const SizedBox(width: 24),
                              IconButton(icon: const Icon(Icons.arrow_right), padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () => _microAdjust(0, 0.000009 / cos(_center.latitude * pi / 180))),
                            ],
                          ),
                          IconButton(icon: const Icon(Icons.arrow_drop_down), padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () => _microAdjust(-0.000009, 0)),
                        ],
                      )
                  ],
                ),
              ),
              
              const Divider(height: 1),
              
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[200], foregroundColor: Colors.black87, elevation: 0),
                        icon: Icon(_isSatellite ? Icons.map : Icons.satellite_alt, size: 18),
                        label: Text(_isSatellite ? "Calles" : "Satélite", style: const TextStyle(fontSize: 12)),
                        onPressed: () => setState(() => _isSatellite = !_isSatellite),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[200], foregroundColor: Colors.black87, elevation: 0),
                        icon: const Icon(Icons.camera_alt, size: 18),
                        label: const Text("Evidencia", style: TextStyle(fontSize: 12)),
                        onPressed: _takeForensicPhoto,
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: SrunElevatedButton(
                  onPressed: _toggleMock,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isMocking ? Colors.red[700] : Colors.green[700],
                    minimumSize: const Size(double.infinity, 55),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))
                  ),
                  child: Text(
                    _isMocking ? "🛑 DETENER SIMULACIÓN" : "🚀 INICIAR SIMULACIÓN BLINDADA",
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        );

        return Scaffold(
          body: isTablet 
            ? Row(
                children: [
                  Expanded(child: mapArea),
                  controlPanel,
                ],
              )
            : Column(
                children: [
                  Expanded(child: mapArea),
                  controlPanel,
                ],
              ),
        );
      }
    );
  }
}

class SrunElevatedButton extends StatelessWidget {
  final VoidCallback onPressed;
  final Widget child;
  final ButtonStyle style;

  const SrunElevatedButton({
    super.key,
    required this.onPressed,
    required this.child,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: style,
      child: child,
    );
  }
}
