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
import 'package:geolocator/geolocator.dart'; 
import 'package:crypto/crypto.dart'; 

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
      return e.message ?? "ERROR";
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
      return "⚠️ Salto de ${distanceMeters.toStringAsFixed(0)}m.\nVelocidad: ${speedKmh.toStringAsFixed(0)} km/h.";
    }
    return null;
  }

  static String? checkSpainBounds(LatLng pos) {
    if (pos.latitude < 35.0 || pos.latitude > 44.0 || pos.longitude < -10.0 || pos.longitude > 5.0) {
      return "⚠️ Coordenada fuera de España.";
    }
    return null;
  }
}

/// ============================================================================
/// MÓDULO 3: CEREBRO DE CONVERSIÓN Y EXTRACCIÓN DE DIRECCIONES
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

    final urlMatch = RegExp(r'(https?://[^\s]+)').firstMatch(query);
    if (urlMatch != null) {
      String finalUrl = urlMatch.group(0)!;
      try {
        // PARCHE EU: Leer redirecciones manualmente para saltar el Muro de Cookies de Google
        int redirects = 0;
        while (redirects < 3) {
          final request = http.Request('GET', Uri.parse(finalUrl))..followRedirects = false;
          final response = await http.Client().send(request);
          if (response.statusCode >= 300 && response.statusCode < 400) {
            finalUrl = response.headers['location'] ?? finalUrl;
            redirects++;
          } else {
            break;
          }
        }
        
        finalUrl = Uri.decodeFull(finalUrl); // Convertir %2C a comas

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
  
  bool _checkSpeed = true;
  bool _checkBounds = false;
  LatLng? _lastInjectedPos;
  DateTime? _lastInjectedTime;

  List<Map<String, dynamic>> _photos = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
    _loadAndCleanPhotos();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkSharedLinks(); 
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Procesando enlace...')));
      
      final LatLng? result = await _geocodingService.searchAddress(sharedText);
      if (result != null) {
        _updateMapCenterFromExtracted(result.latitude.toString(), result.longitude.toString());
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo extraer la coordenada.'), backgroundColor: Colors.red));
      }
    }
  }

  void _updateMapCenterFromExtracted(String latStr, String lngStr) {
    double lat = double.parse(latStr);
    double lng = double.parse(lngStr);
    setState(() {
      _center = LatLng(double.parse(lat.toStringAsFixed(7)), double.parse(lng.toStringAsFixed(7)));
      _mapController.move(_center, 17.0);
    });
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ubicación capturada con éxito.'), backgroundColor: Colors.green));
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.locationWhenInUse, 
      Permission.locationAlways,
      Permission.notification
    ].request();
  }

  Future<void> _goToRealLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Activa el GPS físico.')));
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Permiso denegado.')));
        return;
      }
    }

    Position? lastPos = await Geolocator.getLastKnownPosition();
    if (lastPos != null) {
      setState(() {
        _center = LatLng(double.parse(lastPos.latitude.toStringAsFixed(7)), double.parse(lastPos.longitude.toStringAsFixed(7)));
        _mapController.move(_center, 17.0);
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Afinando precisión GPS...')));
    } else {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Buscando satélites...')));
    }

    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 8), 
      );
      
      setState(() {
        _center = LatLng(double.parse(position.latitude.toStringAsFixed(7)), double.parse(position.longitude.toStringAsFixed(7)));
        _mapController.move(_center, 17.0);
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Precisión GPS máxima obtenida.')));
    } catch (e) {
      if (lastPos == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Señal débil. Asegúrate de no estar bajo un techo.')));
      }
    }
  }

  void _microAdjust(double latOffset, double lngOffset) {
    if (_isMocking) return;
    setState(() {
      double newLat = _center.latitude + latOffset;
      double newLng = _center.longitude + lngOffset;
      _center = LatLng(double.parse(newLat.toStringAsFixed(7)), double.parse(newLng.toStringAsFixed(7)));
      _mapController.move(_center, _mapController.camera.zoom);
    });
  }

  // --- GESTIÓN FORENSE DE FOTOS ---
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
    
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generando evidencia y Hash SHA256...')));

    final File imgFile = File(image.path);
    final String latStr = _center.latitude.toStringAsFixed(7);
    final String lngStr = _center.longitude.toStringAsFixed(7);
    final String dateStr = DateFormat('dd/MM/yyyy HH:mm:ss').format(DateTime.now());

    try {
      final bytes = await imgFile.readAsBytes();
      
      final digest = sha256.convert(bytes);
      final String hashStr = digest.toString().substring(0, 16).toUpperCase(); 

      img.Image? decodedImg = img.decodeImage(bytes);
      
      if (decodedImg != null) {
        int rectHeight = 85;
        img.fillRect(decodedImg, 
            x1: 0, y1: decodedImg.height - rectHeight, 
            x2: decodedImg.width, y2: decodedImg.height, 
            color: img.ColorRgba8(0, 0, 0, 160));
        
        final String watermarkLine1 = "INSPECCION TECNICA | LAT: $latStr | LNG: $lngStr";
        final String watermarkLine2 = "ALT: 10.0m | ACC: 1.0m | DATE: $dateStr";
        final String watermarkLine3 = "SHA256: $hashStr";
        
        img.drawString(decodedImg, watermarkLine1, font: img.arial24, x: 20, y: decodedImg.height - 75, color: img.ColorRgb8(255, 255, 255));
        img.drawString(decodedImg, watermarkLine2, font: img.arial24, x: 20, y: decodedImg.height - 50, color: img.ColorRgb8(255, 255, 255));
        img.drawString(decodedImg, watermarkLine3, font: img.arial24, x: 20, y: decodedImg.height - 25, color: img.ColorRgb8(255, 200, 0));
        
        await imgFile.writeAsBytes(img.encodeJpg(decodedImg, quality: 90));
      }
    } catch (e) {
      debugPrint("Error img: $e");
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
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Evidencia Asegurada.'), backgroundColor: Colors.green));
  }

  void _showPhotoGallery() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        if (_photos.isEmpty) return const Padding(padding: EdgeInsets.all(24.0), child: Text('No hay fotos recientes.', textAlign: TextAlign.center));
        return ListView.builder(
          itemCount: _photos.length,
          itemBuilder: (context, index) {
            final f = _photos[index];
            final DateTime date = DateTime.parse(f['timestamp']);
            final String timeString = DateFormat('dd/MM/yyyy HH:mm').format(date);
            
            Widget leadingIcon = const Icon(Icons.broken_image);
            if (f.containsKey('photo_path') && f['photo_path'] != null) {
              final file = File(f['photo_path']);
              if (file.existsSync()) leadingIcon = ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.file(file, width: 50, height: 50, fit: BoxFit.cover));
            }
            
            return ListTile(
              leading: leadingIcon,
              title: Text(timeString, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Lat: ${f['lat'].toStringAsFixed(7)}, Lng: ${f['lng'].toStringAsFixed(7)}'),
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
                Future.delayed(const Duration(milliseconds: 400), () {
                  final newPos = LatLng(double.parse(f['lat'].toString()), double.parse(f['lng'].toString()));
                  _mapController.move(newPos, 17.0);
                  setState(() => _center = newPos);
                });
              },
            );
          },
        );
      }
    );
  }

  void _showCoordinateInputDialog() {
    final TextEditingController decLatCtrl = TextEditingController();
    final TextEditingController decLngCtrl = TextEditingController();
    
    final TextEditingController utmZoneCtrl = TextEditingController();
    final TextEditingController utmEastCtrl = TextEditingController();
    final TextEditingController utmNorthCtrl = TextEditingController();
    
    final TextEditingController addressCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return DefaultTabController(
          length: 4, 
          child: Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Container(
              padding: const EdgeInsets.all(16),
              height: 450,
              child: Column(
                children: [
                  const Text("🎯 LOCALIZAR UBICACIÓN", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 10),
                  const TabBar(
                    labelColor: Colors.blue,
                    unselectedLabelColor: Colors.grey,
                    isScrollable: true,
                    tabs: [Tab(text: "Decimal"), Tab(text: "UTM"), Tab(text: "DMS"), Tab(text: "Dirección / Link")]
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextField(controller: decLatCtrl, decoration: const InputDecoration(labelText: 'Latitud (Ej: 36.430771)'), keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true)),
                            const SizedBox(height: 10),
                            TextField(controller: decLngCtrl, decoration: const InputDecoration(labelText: 'Longitud (Ej: -5.167703)'), keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true)),
                          ],
                        ),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextField(controller: utmZoneCtrl, decoration: const InputDecoration(labelText: 'Zona (Ej: 30S)'), textCapitalization: TextCapitalization.characters),
                            TextField(controller: utmEastCtrl, decoration: const InputDecoration(labelText: 'Easting (X)'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                            TextField(controller: utmNorthCtrl, decoration: const InputDecoration(labelText: 'Northing (Y)'), keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                          ],
                        ),
                        const Center(child: Text("Utilice el formato Decimal o busque la Dirección directamente.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text("Escribe una calle o pega un link de Maps:", style: TextStyle(fontSize: 12, color: Colors.grey)),
                            const SizedBox(height: 10),
                            TextField(
                              controller: addressCtrl, 
                              decoration: const InputDecoration(hintText: 'Ej: Gran Via, Madrid', border: OutlineInputBorder()), 
                              maxLines: 2,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[900], foregroundColor: Colors.white),
                      onPressed: () async {
                        LatLng? parsed;
                        
                        if (addressCtrl.text.isNotEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Buscando...')));
                          parsed = await _geocodingService.searchAddress(addressCtrl.text);
                        } 
                        else if (decLatCtrl.text.isNotEmpty && decLngCtrl.text.isNotEmpty) {
                          try {
                            parsed = LatLng(double.parse(decLatCtrl.text.replaceAll(',', '.')), double.parse(decLngCtrl.text.replaceAll(',', '.')));
                          } catch (_) {}
                        } 
                        else if (utmZoneCtrl.text.isNotEmpty && utmEastCtrl.text.isNotEmpty && utmNorthCtrl.text.isNotEmpty) {
                          try {
                            String zone = utmZoneCtrl.text.trim().toUpperCase();
                            int zNum = int.parse(zone.replaceAll(RegExp(r'[A-Z]'), ''));
                            String zLet = zone.replaceAll(RegExp(r'[0-9]'), '');
                            final latlon = UTM.fromUtm(easting: double.parse(utmEastCtrl.text), northing: double.parse(utmNorthCtrl.text), zoneNumber: zNum, zoneLetter: zLet);
                            parsed = LatLng(latlon.lat, latlon.lon);
                          } catch (_) {}
                        }

                        if (parsed != null) {
                          setState(() {
                            // BLINDAJE DECIMAL AL IMPORTAR
                            _center = LatLng(double.parse(parsed!.latitude.toStringAsFixed(7)), double.parse(parsed.longitude.toStringAsFixed(7)));
                            _mapController.move(_center, 17.0);
                          });
                          if (mounted) Navigator.pop(context);
                        } else {
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se pudo encontrar la ubicación.')));
                        }
                      },
                      child: const Text("ENVIAR AL MAPA"),
                    ),
                  )
                ],
              ),
            ),
          ),
        );
      }
    );
  }

  Future<void> _toggleMock() async {
    if (_isMocking) {
      await _locationService.stopMocking();
      setState(() => _isMocking = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Simulación Detenida. Caché de Google Maps limpiada.')));
    } else {
      var status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) {
        await _requestPermissions();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Debes otorgar permisos de ubicación primero.')));
        return;
      }
      
      if (_checkBounds) {
        final String? boundsWarning = ValidationService.checkSpainBounds(_center);
        if (boundsWarning != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(boundsWarning), backgroundColor: Colors.orange));
      }

      if (_checkSpeed && _lastInjectedPos != null && _lastInjectedTime != null) {
        final String? speedWarning = ValidationService.checkJumpConsistency(_lastInjectedPos!, _lastInjectedTime!, _center);
        if (speedWarning != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(speedWarning), backgroundColor: Colors.orange));
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
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: Selecciona esta app en "Opciones de Desarrollador"'), backgroundColor: Colors.red, duration: const Duration(seconds: 4)));
      }
    }
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
                  const Text('⚙️ Ajustes de Auditoría', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Divider(),
                  SwitchListTile(
                    title: const Text('Alerta de Velocidad (>120km/h)'),
                    value: _checkSpeed,
                    onChanged: (bool value) {
                      setModalState(() => _checkSpeed = value);
                      setState(() => _checkSpeed = value);
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Límite Geográfico (España)'),
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
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 17.0,
              onPositionChanged: (pos, hasGesture) {
                // PARCHE DEL LÁDRON DE DECIMALES: 
                // Solo se actualiza la coordenada visual si arrastras el mapa (hasGesture == true).
                if (pos.center != null && !_isMocking && hasGesture) {
                  setState(() => _center = pos.center!);
                }
              },
              interactionOptions: InteractionOptions(flags: _isMocking ? InteractiveFlag.none : InteractiveFlag.all)
            ),
            children: [
              TileLayer(
                urlTemplate: _isSatellite ? 'https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}' : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
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
          
          Center(child: Icon(_isMocking ? Icons.gps_fixed : Icons.add_circle_outline, color: _isMocking ? Colors.green : Colors.red, size: 44)),

          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.blueGrey[900]?.withOpacity(0.9), borderRadius: BorderRadius.circular(12), boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)]),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(icon: const Icon(Icons.my_location, color: Colors.white), onPressed: _goToRealLocation, tooltip: 'Mi Ubicación Física'),
                      Container(width: 1, height: 30, color: Colors.grey),
                      IconButton(icon: Icon(_isSatellite ? Icons.map : Icons.satellite_alt, color: Colors.white), onPressed: () => setState(() => _isSatellite = !_isSatellite), tooltip: 'Cambiar Vista'),
                      Container(width: 1, height: 30, color: Colors.grey),
                      IconButton(icon: const Icon(Icons.camera_alt, color: Colors.white), onPressed: _takeForensicPhoto, tooltip: 'Foto Técnica'),
                      Container(width: 1, height: 30, color: Colors.grey),
                      IconButton(icon: const Icon(Icons.photo_library, color: Colors.white), onPressed: _showPhotoGallery, tooltip: 'Historial'),
                      Container(width: 1, height: 30, color: Colors.grey),
                      IconButton(icon: const Icon(Icons.settings, color: Colors.white), onPressed: _showSettings, tooltip: 'Ajustes'),
                    ],
                  ),
                ),
              ),
            ),
          ),

          if (!_isMocking)
            Positioned(
              right: 16,
              top: MediaQuery.of(context).size.height / 2 - 60,
              child: Container(
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), borderRadius: BorderRadius.circular(40), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]),
                child: Column(
                  children: [
                    IconButton(icon: const Icon(Icons.arrow_drop_up), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 40, minHeight: 40), onPressed: () => _microAdjust(0.000009, 0)),
                    Row(
                      children: [
                        IconButton(icon: const Icon(Icons.arrow_left), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 40, minHeight: 40), onPressed: () => _microAdjust(0, -0.000009 / cos(_center.latitude * pi / 180))),
                        const SizedBox(width: 20),
                        IconButton(icon: const Icon(Icons.arrow_right), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 40, minHeight: 40), onPressed: () => _microAdjust(0, 0.000009 / cos(_center.latitude * pi / 180))),
                      ],
                    ),
                    IconButton(icon: const Icon(Icons.arrow_drop_down), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 40, minHeight: 40), onPressed: () => _microAdjust(-0.000009, 0)),
                  ],
                ),
              ),
            ),

          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Container(
                  width: 500,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, spreadRadius: 2)]),
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text("OBJETIVO (WGS84 - 7 Dec)", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                                Text("Lat: ${_center.latitude.toStringAsFixed(7)}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                                Text("Lng: ${_center.longitude.toStringAsFixed(7)}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                              ],
                            ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey[100], foregroundColor: Colors.black87),
                              icon: const Icon(Icons.edit_location_alt, size: 18),
                              label: const Text("PLANTILLA"),
                              onPressed: _showCoordinateInputDialog,
                            )
                          ],
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _toggleMock,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isMocking ? Colors.red[700] : Colors.green[700],
                            minimumSize: const Size(double.infinity, 60),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                          ),
                          child: Text(
                            _isMocking ? "🛑 DETENER SIMULACIÓN" : "🚀 INICIAR SIMULACIÓN BLINDADA",
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
