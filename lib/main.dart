import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:exif/exif.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:permission_handler/permission_handler.dart'; 
import 'advanced_coordinate_picker.dart';

void main() {
  runApp(const MockLocationApp());
}

/// MÓDULO 1: Aplicación Principal
class MockLocationApp extends StatelessWidget {
  const MockLocationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Simulador GPS Pro 2.0',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E293B), primary: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: const MapScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// MÓDULO 2: Servicio de Comunicación Nativa
class LocationService {
  static const MethodChannel _channel = MethodChannel('mock_location_channel');
  Future<String> startMocking(double lat, double lng) async {
    try {
      await _channel.invokeMethod('startMocking', {'lat': lat, 'lng': lng});
      return "SUCCESS";
    } on PlatformException catch (e) {
      if (e.code == "PERMISSION_DENIED") return "DENIED";
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

/// MÓDULO 3: Buscador Avanzado (Sin filtro de distancia, mostrando dirección completa)
class GeocodingService {
  Future<List<Map<String, dynamic>>> searchAddress(String query, LatLng currentCenter) async {
    if (query.isEmpty) return [];
    
    final String cleanQuery = query.toLowerCase().replaceAll(RegExp(r'\b(sa|s\.a\.|sl|s\.l\.)\b'), '').trim();
    final Uri nominatimUrl = Uri.parse('https://nominatim.openstreetmap.org/search?q=$cleanQuery&format=json&limit=15&addressdetails=1&countrycodes=es');
    
    List<Map<String, dynamic>> finalResults = [];

    try {
      final response = await http.get(nominatimUrl, headers: {'User-Agent': 'MockGpsPro/2.2'}).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        for (var item in data) {
          final String fullDisplayName = item['display_name'].toString();
          final List<String> parts = fullDisplayName.split(',');
          final String title = parts.isNotEmpty ? parts[0].trim() : 'Ubicación';
          final String subtitle = parts.length > 1 ? parts.skip(1).join(', ').trim() : 'Sin detalles';
          
          final double lat = double.parse(item['lat'].toString());
          final double lng = double.parse(item['lon'].toString());
          final double distance = Geolocator.distanceBetween(currentCenter.latitude, currentCenter.longitude, lat, lng);

          finalResults.add({
            'title': title,
            'subtitle': subtitle,
            'lat': lat,
            'lng': lng,
            'distance': distance,
          });
        }
      }
    } catch (e) {
      debugPrint("Fallo Nominatim: $e");
    }

    if (finalResults.isEmpty) {
      final Uri photonUrl = Uri.parse('https://photon.komoot.io/api/?q=$cleanQuery&limit=10&lang=es');
      try {
        final response = await http.get(photonUrl);
        if (response.statusCode == 200) {
          final Map<String, dynamic> data = json.decode(response.body);
          final List<dynamic> features = data['features'];
          for (var f in features) {
            final coords = f['geometry']['coordinates'];
            final props = f['properties'];
            String name = props['name'] ?? 'Ubicación';
            String contextDetails = '';
            if (props['street'] != null) contextDetails += '${props['street']}, ';
            if (props['city'] != null) contextDetails += '${props['city']}, ';
            if (props['state'] != null) contextDetails += '${props['state']}, ';
            if (props['country'] != null) contextDetails += '${props['country']}';

            final double lat = double.parse(coords[1].toString());
            final double lng = double.parse(coords[0].toString());
            final double distance = Geolocator.distanceBetween(currentCenter.latitude, currentCenter.longitude, lat, lng);

            finalResults.add({
              'title': name,
              'subtitle': contextDetails.isNotEmpty ? contextDetails : 'Sin datos extra',
              'lat': lat,
              'lng': lng,
              'distance': distance,
            });
          }
        }
      } catch (e) {
        debugPrint("Error búsqueda Photon: $e");
      }
    }

    finalResults.sort((a, b) => (a['distance'] as double).compareTo(b['distance'] as double));

    return finalResults;
  }
}

/// MÓDULO 4: Matemáticas, Formateo y Ajustes (BLINDAJE DE PRECISIÓN ABSOLUTA)
class CoordinateFormatter {
  static final Random _random = Random();
  
  static double _nextGaussian() {
    double u = 0, v = 0;
    while (u == 0) u = _random.nextDouble(); 
    while (v == 0) v = _random.nextDouble();
    return sqrt(-2.0 * log(u)) * cos(2.0 * pi * v);
  }

  // LA TIJERA FINAL: Elimina la cola binaria de la clase double de Dart
  static double _safeRound(double value, int decimals) {
    return double.parse(value.toStringAsFixed(decimals));
  }

  static double generateInjectedCoordinate(double value, int decimals) {
    final double factor = pow(10, decimals).toDouble();
    final double roundedValue = (value * factor).round() / factor;

    // MEJORA PRO: Si el inspector elige 7 u 8 decimales, quiere precisión militar.
    // Nada de ruido humano, devolvemos el valor cortado a láser.
    if (decimals >= 7) {
      return _safeRound(roundedValue, decimals);
    }

    // Si son menos de 7 decimales, inyectamos el ruido humano (comportamiento orgánico)
    final double precisionLimit = pow(10, -decimals).toDouble();
    final double noise = _nextGaussian() * (precisionLimit / 3);
    
    final double result = roundedValue + noise;

    // Redondeo seguro final para destruir los microerrores del procesador
    return _safeRound(result, decimals);
  }
}

class SystemSettingsService {
  static const MethodChannel _channel = MethodChannel('mock_location_channel');
  Future<bool> openTimeSettings() async {
    try {
      await _channel.invokeMethod('openTimeSettings');
      return true;
    } catch (e) { return false; }
  }
}

/// MÓDULO 5: Pantalla Principal
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final LocationService _locationService = LocationService();
  final GeocodingService _geocodingService = GeocodingService();
  final SystemSettingsService _systemSettingsService = SystemSettingsService(); 
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _favNameController = TextEditingController(); 

  late AnimationController _blinkController; 
  LatLng _mapCenter = const LatLng(36.7213, -4.4214);
  double? _injectedLat;
  double? _injectedLng;
  bool _isMocking = false;
  bool _isLoadingSearch = false;
  
  int _selectedDecimalsLat = 7; 
  int _selectedDecimalsLng = 7; 
  
  List<Map<String, dynamic>> _favorites = [];

  @override
  void initState() {
    super.initState();
    _requestModernPermissions();
    _loadFavorites(); 
    _loadLastLocation(); 
    _blinkController = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _blinkController.dispose();
    _searchController.dispose();
    _favNameController.dispose();
    super.dispose();
  }

  Future<void> _requestModernPermissions() async {
    await [Permission.locationWhenInUse, Permission.locationAlways].request();
  }

  // --- LA CAJA NEGRA (AUTO CHECKPOINT SILENCIOSO) ---
  Future<void> _autoCheckpoint(LatLng loc, {double accuracy = 0.0, String source = 'Manual'}) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> history = prefs.getStringList('gps_history') ?? [];

    history.add(json.encode({
      'lat': loc.latitude,
      'lng': loc.longitude,
      'accuracy': accuracy,
      'source': source,
      'timestamp': DateTime.now().toIso8601String()
    }));

    if (history.length > 50) {
      history = history.sublist(history.length - 50);
    }
    await prefs.setStringList('gps_history', history);
  }

  void _showBlackBoxHistory() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> history = prefs.getStringList('gps_history') ?? [];
    
    if (!mounted) return;

    if (history.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('La caja negra está vacía.')));
      return;
    }

    List<Map<String, dynamic>> parsedHistory = history.map((e) => json.decode(e) as Map<String, dynamic>).toList();
    parsedHistory.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black87,
              width: double.infinity,
              child: const Text('Caja Negra (Últimos 50 saltos)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: parsedHistory.length,
                itemBuilder: (context, index) {
                  final h = parsedHistory[index];
                  final DateTime date = DateTime.parse(h['timestamp']);
                  final String timeString = "${date.day}/${date.month} ${date.hour}:${date.minute.toString().padLeft(2, '0')}";
                  final String accText = h['accuracy'] > 0.0 ? '±${h['accuracy'].toStringAsFixed(1)}m' : 'Simulada/Buscada';
                  
                  return ListTile(
                    leading: const Icon(Icons.history, color: Colors.grey),
                    title: Text('${h['source']} - $timeString', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    subtitle: Text('Lat: ${h['lat'].toStringAsFixed(5)} | Lng: ${h['lng'].toStringAsFixed(5)}\nPrecisión: $accText'),
                    isThreeLine: true,
                    onTap: () {
                      Navigator.pop(context);
                      _goToLocation(LatLng(h['lat'], h['lng']), source: 'Restaurado de Caja Negra');
                    },
                  );
                },
              ),
            ),
          ],
        );
      }
    );
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final String? favsJson = prefs.getString('saved_locations');
    if (favsJson != null) {
      List<dynamic> decoded = json.decode(favsJson);
      List<Map<String, dynamic>> loadedFavs = decoded.cast<Map<String, dynamic>>();
      
      loadedFavs.removeWhere((f) {
        try {
          final date = DateTime.parse(f['timestamp']);
          return DateTime.now().difference(date).inDays > 7;
        } catch (e) { return false; }
      });

      setState(() {
        _favorites = loadedFavs;
        _favorites.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
      });
      _saveFavoritesToDisk(); 
    }
  }

  Future<void> _saveFavoritesToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    _favorites.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
    await prefs.setString('saved_locations', json.encode(_favorites));
  }

  Future<void> _loadLastLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final double? lat = prefs.getDouble('last_lat');
    final double? lng = prefs.getDouble('last_lng');
    if (lat != null && lng != null) {
      setState(() => _mapCenter = LatLng(lat, lng));
      Future.delayed(const Duration(milliseconds: 500), () => _mapController.move(_mapCenter, 16.0));
    }
  }

  Future<void> _saveLastLocation() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_lat', _mapCenter.latitude);
    await prefs.setDouble('last_lng', _mapCenter.longitude);
  }

  Future<void> _takePhotoCheckpoint() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.camera);
    if (image == null) return;
    _showSaveFavoriteDialog(defaultName: '📸 Checkpoint Visual', photoPath: image.path);
  }

  Future<void> _extractGpsFromGalleryPhoto() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Analizando metadatos EXIF...')));

    try {
      final bytes = await File(image.path).readAsBytes();
      final tags = await readExifFromBytes(bytes);

      if (tags.containsKey('GPS GPSLatitude') && tags.containsKey('GPS GPSLongitude')) {
        final latValue = tags['GPS GPSLatitude']!.values.toList();
        final lngValue = tags['GPS GPSLongitude']!.values.toList();
        final latRef = tags['GPS GPSLatitudeRef']?.printable ?? 'N';
        final lngRef = tags['GPS GPSLongitudeRef']?.printable ?? 'W';

        double lat = _exifRatioToDouble(latValue);
        double lng = _exifRatioToDouble(lngValue);
        if (latRef == 'S') lat = -lat;
        if (lngRef == 'W') lng = -lng;

        _goToLocation(LatLng(lat, lng), source: 'Foto EXIF');
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ubicación extraída con éxito.'), backgroundColor: Colors.green));
          _showSaveFavoriteDialog(defaultName: 'Ubicación extraída de Foto', photoPath: image.path);
        }
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Esta foto no contiene metadatos de ubicación (GPS).'), backgroundColor: Colors.orange));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al leer el archivo de la foto.')));
    }
  }

  double _exifRatioToDouble(List<dynamic> values) {
    double result = 0.0;
    try {
      if (values.isNotEmpty) result += (values[0].numerator / values[0].denominator);
      if (values.length > 1) result += (values[1].numerator / values[1].denominator) / 60.0;
      if (values.length > 2) result += (values[2].numerator / values[2].denominator) / 3600.0;
    } catch (e) {}
    return result;
  }

  void _showSaveFavoriteDialog({String defaultName = '', String? photoPath}) {
    _favNameController.text = defaultName; 
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Guardar Inspección', style: TextStyle(fontWeight: FontWeight.bold)),
          content: TextField(
            controller: _favNameController,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Ej: Balsa de Riego Norte', border: OutlineInputBorder(), prefixIcon: Icon(Icons.edit)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCELAR')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
              onPressed: () {
                _saveFavoriteWithName(_favNameController.text.trim(), photoPath: photoPath);
                Navigator.pop(context);
              },
              child: const Text('GUARDAR'),
            ),
          ],
        );
      }
    );
  }

  void _saveFavoriteWithName(String name, {String? photoPath}) {
    setState(() {
      _favorites.add({ 
        'name': name.isEmpty ? 'Inspección (${_mapCenter.latitude.toStringAsFixed(4)})' : name,
        'lat': _mapCenter.latitude,
        'lng': _mapCenter.longitude,
        'timestamp': DateTime.now().toIso8601String(), 
        if (photoPath != null) 'photo_path': photoPath,
      });
      _favorites.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
    });
    _saveFavoritesToDisk();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Guardado correctamente. (Auto-borrado en 7 días)')));
  }

  void _onMapPositionChanged(MapPosition position, bool hasGesture) {
    if (position.center != null && !_isMocking) setState(() => _mapCenter = position.center!);
  }

  Future<void> _performSearch() async {
    final String query = _searchController.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();

    setState(() => _isLoadingSearch = true);
    final List<Map<String, dynamic>> results = await _geocodingService.searchAddress(query, _mapCenter);
    setState(() => _isLoadingSearch = false);

    if (results.isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('No encontrado', style: TextStyle(fontWeight: FontWeight.bold)),
            content: const Text('Comprueba que no haya faltas de ortografía o usa la opción "Convertidor" en el menú.'),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('ENTENDIDO'))],
          )
        );
      }
      return;
    }

    if (results.length == 1) {
      _goToLocation(LatLng(results[0]['lat'], results[0]['lng']), source: 'Buscador');
    } else {
      if (mounted) {
        showModalBottomSheet(
          context: context,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          builder: (context) {
            return ListView.builder(
              shrinkWrap: true,
              itemCount: results.length,
              itemBuilder: (context, index) {
                final double dist = results[index]['distance'];
                final String distText = dist > 1000 ? '${(dist / 1000).toStringAsFixed(1)} km' : '${dist.toStringAsFixed(0)} m';
                
                return ListTile(
                  leading: const Icon(Icons.place, color: Colors.blueAccent),
                  title: Text(results[index]['title'], style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    '${results[index]['subtitle']}\n(Coordenadas: ${results[index]['lat'].toStringAsFixed(4)}, ${results[index]['lng'].toStringAsFixed(4)})\nA $distText de ti',
                    maxLines: 4, 
                    overflow: TextOverflow.ellipsis, 
                    style: const TextStyle(fontSize: 12)
                  ),
                  isThreeLine: true,
                  onTap: () {
                    Navigator.pop(context);
                    _goToLocation(LatLng(results[index]['lat'], results[index]['lng']), source: 'Buscador');
                  },
                );
              },
            );
          }
        );
      }
    }
  }

  void _goToLocation(LatLng loc, {String source = 'Manual'}) {
    _mapController.move(loc, 16.0);
    setState(() => _mapCenter = loc);
    _saveLastLocation(); 
    _autoCheckpoint(loc, source: source); 
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
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;
    
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Buscando señal real...')));
    
    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.bestForNavigation);
    _goToLocation(LatLng(position.latitude, position.longitude), source: 'GPS Real');
    _autoCheckpoint(LatLng(position.latitude, position.longitude), accuracy: position.accuracy, source: 'GPS Real');
  }

  void _showFavorites() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        if (_favorites.isEmpty) {
          return const Padding(padding: EdgeInsets.all(24.0), child: Text('No hay inspecciones guardadas.', textAlign: TextAlign.center));
        }
        return ListView.builder(
          itemCount: _favorites.length,
          itemBuilder: (context, index) {
            final f = _favorites[index];
            final int daysOld = DateTime.now().difference(DateTime.parse(f['timestamp'])).inDays;
            final int daysLeft = 7 - daysOld;
            
            Widget leadingIcon = const Icon(Icons.push_pin, color: Colors.amber);
            if (f.containsKey('photo_path') && f['photo_path'] != null) {
              final file = File(f['photo_path']);
              if (file.existsSync()) {
                leadingIcon = ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(file, width: 40, height: 40, fit: BoxFit.cover),
                );
              } else {
                leadingIcon = const Icon(Icons.broken_image, color: Colors.grey);
              }
            }
            
            return ListTile(
              leading: leadingIcon,
              title: Text(f['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Expira en $daysLeft días\nLat: ${f['lat'].toStringAsFixed(5)} | Lng: ${f['lng'].toStringAsFixed(5)}'),
              isThreeLine: true,
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.redAccent),
                onPressed: () {
                  setState(() { _favorites.removeAt(index); _saveFavoritesToDisk(); });
                  Navigator.pop(context); _showFavorites(); 
                },
              ),
              onTap: () {
                Navigator.pop(context);
                _goToLocation(LatLng(f['lat'], f['lng']), source: 'Favorito Guardado');
              },
            );
          },
        );
      }
    );
  }

  Future<void> _toggleMockLocation() async {
    if (_isMocking) {
      await _locationService.stopMocking();
      setState(() { _isMocking = false; _injectedLat = null; _injectedLng = null; });
    } else {
      var status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) { await _requestModernPermissions(); return; }

      final double finalLat = CoordinateFormatter.generateInjectedCoordinate(_mapCenter.latitude, _selectedDecimalsLat);
      final double finalLng = CoordinateFormatter.generateInjectedCoordinate(_mapCenter.longitude, _selectedDecimalsLng);

      final String result = await _locationService.startMocking(finalLat, finalLng);
      if (result == "SUCCESS") {
        setState(() { _isMocking = true; _injectedLat = finalLat; _injectedLng = finalLng; });
        _saveLastLocation(); 
        _autoCheckpoint(LatLng(finalLat, finalLng), source: 'Inyección Mock');
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ Error al inyectar.')));
      }
    }
  }

  void _copyCoordinates() {
    final double displayLat = (_isMocking && _injectedLat != null) ? _injectedLat! : _mapCenter.latitude;
    final double displayLng = (_isMocking && _injectedLng != null) ? _injectedLng! : _mapCenter.longitude;
    final String textToCopy = '${displayLat.toStringAsFixed(_selectedDecimalsLat)}, ${displayLng.toStringAsFixed(_selectedDecimalsLng)}';
    Clipboard.setData(ClipboardData(text: textToCopy));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Coordenadas copiadas'), backgroundColor: Colors.blueGrey, behavior: SnackBarBehavior.floating));
  }

  double _getRadiusMeters(int decimals) {
    if (decimals >= 8) return 0.0;
    if (decimals == 7) return 0.01;
    if (decimals == 6) return 0.11;
    if (decimals == 5) return 1.1;
    if (decimals == 4) return 11.0;
    if (decimals == 3) return 110.0;
    if (decimals == 2) return 1100.0;
    return 11000.0;
  }

  @override
  Widget build(BuildContext context) {
    final double displayLat = (_isMocking && _injectedLat != null) ? _injectedLat! : _mapCenter.latitude;
    final double displayLng = (_isMocking && _injectedLng != null) ? _injectedLng! : _mapCenter.longitude;
    
    final int minDecimals = min(_selectedDecimalsLat, _selectedDecimalsLng);
    final double baseRadiusMeters = _getRadiusMeters(minDecimals);
    final double latFactor = cos(_mapCenter.latitude * pi / 180);
    final double adjustedRadius = baseRadiusMeters * latFactor;
    final String errorText = baseRadiusMeters <= 0.01 ? "Exacto (± 1cm)" : "± ${adjustedRadius.toStringAsFixed(1)} m";

    final Color stateColor = _isMocking ? Colors.green : Colors.blueAccent;

    return Scaffold(
      extendBodyBehindAppBar: true, 
      appBar: AppBar(
        title: const Text('Inspección Pro v2', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18)),
        backgroundColor: Colors.black87, 
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu, color: Colors.white, size: 30),
            tooltip: 'Opciones',
            onSelected: (String result) async {
              if (result == 'favoritos') _showFavorites();
              else if (result == 'cajanegra') _showBlackBoxHistory();
              else if (result == 'convertidor') {
                final LatLng? newPos = await Navigator.push(context, MaterialPageRoute(builder: (context) => AdvancedCoordinatePicker(initialPosition: _mapCenter)));
                if (newPos != null) _goToLocation(newPos, source: 'Convertidor UTM');
              } else if (result == 'hora') {
                _systemSettingsService.openTimeSettings();
              } else if (result == 'foto_camara') {
                _takePhotoCheckpoint();
              } else if (result == 'foto_galeria') {
                _extractGpsFromGalleryPhoto();
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(value: 'favoritos', child: ListTile(leading: Icon(Icons.save_as, color: Colors.amber), title: Text('Mis Inspecciones'), contentPadding: EdgeInsets.zero)),
              const PopupMenuItem<String>(value: 'cajanegra', child: ListTile(leading: Icon(Icons.history, color: Colors.grey), title: Text('Caja Negra (Historial)'), contentPadding: EdgeInsets.zero)),
              const PopupMenuItem<String>(value: 'foto_camara', child: ListTile(leading: Icon(Icons.camera_alt, color: Colors.blueAccent), title: Text('Tomar Foto Checkpoint'), contentPadding: EdgeInsets.zero)),
              const PopupMenuItem<String>(value: 'foto_galeria', child: ListTile(leading: Icon(Icons.image_search, color: Colors.purple), title: Text('Extraer GPS de Galería'), contentPadding: EdgeInsets.zero)),
              const PopupMenuItem<String>(value: 'convertidor', child: ListTile(leading: Icon(Icons.edit_location_alt, color: Colors.blueAccent), title: Text('Convertidor UTM/Grados'), contentPadding: EdgeInsets.zero)),
              const PopupMenuItem<String>(value: 'hora', child: ListTile(leading: Icon(Icons.access_time, color: Colors.black87), title: Text('Ajustar Hora'), contentPadding: EdgeInsets.zero)),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: _mapCenter, initialZoom: 16.0, onPositionChanged: _onMapPositionChanged, interactionOptions: InteractionOptions(flags: _isMocking ? InteractiveFlag.none : InteractiveFlag.all)),
            children: [
              TileLayer(urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png', userAgentPackageName: 'com.example.mockgps'),
              if (_isMocking && _injectedLat != null && _injectedLng != null) MarkerLayer(markers: [Marker(point: LatLng(_injectedLat!, _injectedLng!), width: 40, height: 40, child: const Icon(Icons.location_on, color: Colors.green, size: 40))]),
              if (adjustedRadius > 0.01) CircleLayer(circles: [CircleMarker(point: _isMocking ? LatLng(_injectedLat!, _injectedLng!) : _mapCenter, radius: adjustedRadius, useRadiusInMeter: true, color: stateColor.withOpacity(0.15), borderColor: stateColor, borderStrokeWidth: 2)]),
            ],
          ),
          
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(_isMocking ? Icons.gps_fixed : Icons.add, color: _isMocking ? Colors.green.withOpacity(0.5) : Colors.blueAccent, size: 30.0)])),

          if (!_isMocking)
            Positioned(
              right: 16, bottom: 350,
              child: FloatingActionButton(heroTag: 'realLoc', onPressed: _goToRealLocation, backgroundColor: Colors.white, foregroundColor: Colors.blueAccent, child: const Icon(Icons.my_location)),
            ),

          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.only(left: 12, right: 12, bottom: 20),
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20.0), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20.0, offset: const Offset(0, 10))]),
              child: Column(
                mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: TextField(controller: _searchController, decoration: InputDecoration(hintText: 'Buscar calle, polígono, empresa...', isDense: true, prefixIcon: const Icon(Icons.search, size: 20), filled: true, fillColor: Colors.grey[100], border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)), onSubmitted: (_) => _performSearch())),
                      const SizedBox(width: 8),
                      IconButton(style: IconButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white), icon: _isLoadingSearch ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.send), onPressed: _performSearch),
                    ],
                  ),
                  const Divider(height: 12),
                  
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('LAT: ${displayLat.toStringAsFixed(_selectedDecimalsLat)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                          Text('LNG: ${displayLng.toStringAsFixed(_selectedDecimalsLng)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                        ],
                      ),
                      Row(
                        children: [
                          IconButton(icon: const Icon(Icons.copy, color: Colors.blueGrey), onPressed: _copyCoordinates, tooltip: 'Copiar'),
                          IconButton(icon: const Icon(Icons.bookmark_add, color: Colors.blueAccent), onPressed: _showSaveFavoriteDialog, tooltip: 'Guardar'),
                        ],
                      )
                    ],
                  ),
                  
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Text('Lat:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                      Expanded(
                        child: Slider(value: _selectedDecimalsLat.toDouble(), min: 1, max: 8, divisions: 7, activeColor: Colors.blueAccent, label: '$_selectedDecimalsLat dec.', onChanged: _isMocking ? null : (double value) { setState(() => _selectedDecimalsLat = value.toInt()); }),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('Lng:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                      Expanded(
                        child: Slider(value: _selectedDecimalsLng.toDouble(), min: 1, max: 8, divisions: 7, activeColor: Colors.teal, label: '$_selectedDecimalsLng dec.', onChanged: _isMocking ? null : (double value) { setState(() => _selectedDecimalsLng = value.toInt()); }),
                      ),
                    ],
                  ),
                  
                  Container(
                    margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            if (_isMocking) FadeTransition(opacity: _blinkController, child: const Icon(Icons.circle, color: Colors.green, size: 10)),
                            if (_isMocking) const SizedBox(width: 6),
                            Text(_isMocking ? 'INYECCIÓN ACTIVA' : '📡 Señal:', style: TextStyle(fontSize: 12, color: _isMocking ? Colors.green : Colors.grey, fontWeight: _isMocking ? FontWeight.bold : FontWeight.normal)),
                          ],
                        ),
                        Text('GPS + WiFi ($errorText)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87)),
                      ],
                    ),
                  ),

                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: _isMocking ? Colors.redAccent : Colors.green[600], foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    icon: Icon(_isMocking ? Icons.stop_circle : Icons.cell_tower, size: 24),
                    label: Text(_isMocking ? 'DETENER SIMULACIÓN' : 'INICIAR INYECCIÓN', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    onPressed: _toggleMockLocation,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
