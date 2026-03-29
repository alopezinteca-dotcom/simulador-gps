import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart'; // NUEVO: Para leer el GPS Real
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
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E293B),
          primary: const Color(0xFF2563EB),
        ),
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

/// MÓDULO 3: Buscador Avanzado Libre (Con limpieza inteligente de query)
class GeocodingService {
  Future<List<Map<String, dynamic>>> searchAddress(String query) async {
    if (query.isEmpty) return [];
    
    // MEJORA 5: Limpieza de query (quita sa y sl para que no falle Photon)
    final String cleanQuery = query.toLowerCase()
        .replaceAll(RegExp(r'\b(sa|s\.a\.|sl|s\.l\.)\b'), '')
        .trim();
    
    final Uri photonUrl = Uri.parse('https://photon.komoot.io/api/?q=$cleanQuery&limit=5&lang=es');
    
    try {
      final response = await http.get(photonUrl).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final List<dynamic> features = data['features'];
        
        if (features.isNotEmpty) {
          List<Map<String, dynamic>> results = [];
          for (var f in features) {
            final coords = f['geometry']['coordinates'];
            final props = f['properties'];
            String displayName = props['name'] ?? '';
            if (props['street'] != null && displayName != props['street']) displayName += ' - ${props['street']}';
            if (props['city'] != null) displayName += ', ${props['city']}';
            if (displayName.isEmpty) displayName = 'Ubicación desconocida';

            results.add({
              'name': displayName,
              'lat': double.parse(coords[1].toString()),
              'lng': double.parse(coords[0].toString()),
            });
          }
          return results;
        }
      }
    } catch (e) {
      debugPrint("Fallo Photon, activando Fallback Nominatim: $e");
    }

    final Uri nominatimUrl = Uri.parse('https://nominatim.openstreetmap.org/search?q=$cleanQuery&format=json&limit=3&countrycodes=es');
    try {
      final response = await http.get(nominatimUrl, headers: {'User-Agent': 'MockGpsPro/2.0'});
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        List<Map<String, dynamic>> results = [];
        for (var item in data) {
          results.add({
            'name': item['display_name'].toString().split(',').first + ' (Alternativa)',
            'lat': double.parse(item['lat'].toString()),
            'lng': double.parse(item['lon'].toString()),
          });
        }
        return results;
      }
    } catch (e) {
      debugPrint("Error crítico en búsqueda: $e");
    }
    
    return [];
  }
}

/// MÓDULO 4: Matemáticas PRO y Ajustes del Sistema
class CoordinateFormatter {
  static final Random _random = Random();

  static double _nextGaussian() {
    double u = 0, v = 0;
    while (u == 0) u = _random.nextDouble(); 
    while (v == 0) v = _random.nextDouble();
    return sqrt(-2.0 * log(u)) * cos(2.0 * pi * v);
  }

  static double generateInjectedCoordinate(double value, int decimals) {
    if (decimals >= 7) return value;
    final double factor = pow(10, decimals).toDouble();
    final double roundedValue = (value * factor).round() / factor;
    final double precisionLimit = pow(10, -decimals).toDouble();
    final double noise = _nextGaussian() * (precisionLimit / 3);
    return roundedValue + noise;
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

/// MÓDULO 5: Pantalla Principal y Estado
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
  
  // PETICIÓN USUARIO: Decimales independientes, por defecto 7
  int _selectedDecimalsLat = 7; 
  int _selectedDecimalsLng = 7; 
  
  List<Map<String, dynamic>> _favorites = [];

  @override
  void initState() {
    super.initState();
    _requestModernPermissions();
    _loadFavorites(); 
    _loadLastLocation(); 
    
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
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

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final String? favsJson = prefs.getString('saved_locations');
    if (favsJson != null) {
      final List<dynamic> decoded = json.decode(favsJson);
      setState(() {
        _favorites = decoded.cast<Map<String, dynamic>>();
        // MEJORA 2: Ordenar favoritos por fecha robustamente al cargar
        _favorites.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
      });
    }
  }

  Future<void> _saveFavoritesToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    // MEJORA 2: Ordenar antes de guardar por si acaso
    _favorites.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
    await prefs.setString('saved_locations', json.encode(_favorites));
  }

  Future<void> _loadLastLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final double? lat = prefs.getDouble('last_lat');
    final double? lng = prefs.getDouble('last_lng');
    if (lat != null && lng != null) {
      setState(() {
        _mapCenter = LatLng(lat, lng);
      });
      Future.delayed(const Duration(milliseconds: 500), () {
        _mapController.move(_mapCenter, 16.0);
      });
    }
  }

  Future<void> _saveLastLocation() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_lat', _mapCenter.latitude);
    await prefs.setDouble('last_lng', _mapCenter.longitude);
  }

  void _showSaveFavoriteDialog() {
    _favNameController.text = ''; 
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Guardar Inspección', style: TextStyle(fontWeight: FontWeight.bold)),
          content: TextField(
            controller: _favNameController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Ej: Nave Industrial X',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.edit),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCELAR', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
              onPressed: () {
                _saveFavoriteWithName(_favNameController.text.trim());
                Navigator.pop(context);
              },
              child: const Text('GUARDAR'),
            ),
          ],
        );
      }
    );
  }

  void _saveFavoriteWithName(String name) {
    setState(() {
      _favorites.add({ 
        'name': name.isEmpty ? 'Inspección (${_mapCenter.latitude.toStringAsFixed(4)})' : name,
        'lat': _mapCenter.latitude,
        'lng': _mapCenter.longitude,
        'timestamp': DateTime.now().toIso8601String(), 
      });
      _favorites.sort((a, b) => (b['timestamp'] as String).compareTo(a['timestamp'] as String));
    });
    _saveFavoritesToDisk();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Inspección guardada con éxito.')));
  }

  // MEJORA 1: Bloqueo inteligente del centro del mapa
  void _onMapPositionChanged(MapPosition position, bool hasGesture) {
    if (position.center != null && !_isMocking) {
      setState(() {
        _mapCenter = position.center!;
      });
    }
  }

  Future<void> _performSearch() async {
    final String query = _searchController.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();

    setState(() => _isLoadingSearch = true);
    final List<Map<String, dynamic>> results = await _geocodingService.searchAddress(query);
    setState(() => _isLoadingSearch = false);

    if (results.isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('No encontrado', style: TextStyle(fontWeight: FontWeight.bold)),
            content: const Text('La empresa no está registrada en los mapas públicos.\n\nPrueba a buscar el nombre de la calle, o usa la opción "Convertidor" en el MENÚ.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('ENTENDIDO'))
            ],
          )
        );
      }
      return;
    }

    if (results.length == 1) {
      _goToLocation(LatLng(results[0]['lat'], results[0]['lng']));
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
                return ListTile(
                  leading: const Icon(Icons.place, color: Colors.blueAccent),
                  title: Text(results[index]['name']),
                  onTap: () {
                    Navigator.pop(context);
                    _goToLocation(LatLng(results[index]['lat'], results[index]['lng']));
                  },
                );
              },
            );
          }
        );
      }
    }
  }

  void _goToLocation(LatLng loc) {
    _mapController.move(loc, 16.0);
    setState(() {
      _mapCenter = loc;
    });
    _saveLastLocation(); 
  }

  // MEJORA 3: Botón Ir a Mi Ubicación Real
  Future<void> _goToRealLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Por favor, activa el GPS físico de la tablet.')));
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Buscando satélites reales...')));

    Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    _goToLocation(LatLng(position.latitude, position.longitude));
  }

  void _showFavorites() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        if (_favorites.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24.0),
            child: Text('Aún no has guardado ninguna inspección.', textAlign: TextAlign.center),
          );
        }
        return ListView.builder(
          itemCount: _favorites.length,
          itemBuilder: (context, index) {
            final f = _favorites[index];
            return ListTile(
              leading: const Icon(Icons.push_pin, color: Colors.amber),
              title: Text(f['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('Lat: ${f['lat'].toStringAsFixed(5)} | Lng: ${f['lng'].toStringAsFixed(5)}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.redAccent),
                onPressed: () {
                  setState(() {
                    _favorites.removeAt(index);
                    _saveFavoritesToDisk();
                  });
                  Navigator.pop(context); 
                  _showFavorites(); 
                },
              ),
              onTap: () {
                Navigator.pop(context);
                _goToLocation(LatLng(f['lat'], f['lng']));
              },
            );
          },
        );
      }
    );
  }

  Future<void> _toggleMockLocation() async {
    if (_isMocking) {
      final bool success = await _locationService.stopMocking();
      if (success) {
        setState(() {
          _isMocking = false;
          _injectedLat = null;
          _injectedLng = null;
        });
      }
    } else {
      var status = await Permission.locationWhenInUse.status;
      if (!status.isGranted) {
        await _requestModernPermissions();
        return;
      }

      final double finalLat = CoordinateFormatter.generateInjectedCoordinate(_mapCenter.latitude, _selectedDecimalsLat);
      final double finalLng = CoordinateFormatter.generateInjectedCoordinate(_mapCenter.longitude, _selectedDecimalsLng);

      final String result = await _locationService.startMocking(finalLat, finalLng);
      
      if (result == "SUCCESS") {
        setState(() {
          _isMocking = true;
          _injectedLat = finalLat;
          _injectedLng = finalLng;
        });
        _saveLastLocation(); 
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ Error al inyectar.')));
      }
    }
  }

  void _copyCoordinates() {
    // MEJORA 6: Bug potencial solucionado (Manejo robusto de nulos)
    final double displayLat = (_isMocking && _injectedLat != null) ? _injectedLat! : _mapCenter.latitude;
    final double displayLng = (_isMocking && _injectedLng != null) ? _injectedLng! : _mapCenter.longitude;
    
    final String textToCopy = '${displayLat.toStringAsFixed(_selectedDecimalsLat)}, ${displayLng.toStringAsFixed(_selectedDecimalsLng)}';
    
    Clipboard.setData(ClipboardData(text: textToCopy));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Coordenadas copiadas al portapapeles'),
        backgroundColor: Colors.blueGrey,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  double _getRadiusMeters(int decimals) {
    if (decimals >= 7) return 0.0;
    if (decimals == 6) return 0.11;
    if (decimals == 5) return 1.1;
    if (decimals == 4) return 11.0;
    if (decimals == 3) return 110.0;
    if (decimals == 2) return 1100.0;
    return 11000.0;
  }

  @override
  Widget build(BuildContext context) {
    // MEJORA 6: Manejo robusto de nulos en render
    final double displayLat = (_isMocking && _injectedLat != null) ? _injectedLat! : _mapCenter.latitude;
    final double displayLng = (_isMocking && _injectedLng != null) ? _injectedLng! : _mapCenter.longitude;
    
    // MEJORA 4: Precisión visual fina por latitud usando el valor que genera más error
    final int minDecimals = min(_selectedDecimalsLat, _selectedDecimalsLng);
    final double baseRadiusMeters = _getRadiusMeters(minDecimals);
    final double latFactor = cos(_mapCenter.latitude * pi / 180);
    final double adjustedRadius = baseRadiusMeters * latFactor;
    
    final String errorText = baseRadiusMeters == 0.0 ? "Exacto (± 0.0m)" : "± ${adjustedRadius.toStringAsFixed(1)} m";

    return Scaffold(
      extendBodyBehindAppBar: true, 
      appBar: AppBar(
        title: const Text('Inspección Pro v2', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18)),
        backgroundColor: Colors.black87, 
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu, color: Colors.white, size: 30),
            tooltip: 'Opciones y Herramientas',
            onSelected: (String result) async {
              if (result == 'favoritos') {
                _showFavorites();
              } else if (result == 'convertidor') {
                final LatLng? newPos = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => AdvancedCoordinatePicker(initialPosition: _mapCenter)),
                );
                if (newPos != null) _goToLocation(newPos);
              } else if (result == 'hora') {
                _systemSettingsService.openTimeSettings();
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'favoritos',
                child: ListTile(
                  leading: Icon(Icons.save_as, color: Colors.amber),
                  title: Text('Mis Inspecciones Guardadas'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem<String>(
                value: 'convertidor',
                child: ListTile(
                  leading: Icon(Icons.edit_location_alt, color: Colors.blueAccent),
                  title: Text('Convertidor (UTM/Grados)'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem<String>(
                value: 'hora',
                child: ListTile(
                  leading: Icon(Icons.access_time, color: Colors.black87),
                  title: Text('Ajustar Hora del Sistema'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _mapCenter,
              initialZoom: 16.0,
              onPositionChanged: _onMapPositionChanged, 
              // MEJORA 1: Bloqueamos la interacción visualmente si inyecta para no confundir
              interactionOptions: InteractionOptions(
                flags: _isMocking ? InteractiveFlag.none : InteractiveFlag.all,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mockgps',
              ),
              if (_isMocking && _injectedLat != null && _injectedLng != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(_injectedLat!, _injectedLng!),
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.location_on, color: Colors.green, size: 40),
                    )
                  ],
                ),
              if (adjustedRadius > 0)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: _isMocking ? LatLng(_injectedLat!, _injectedLng!) : _mapCenter,
                      radius: adjustedRadius,
                      useRadiusInMeter: true,
                      color: Colors.blue.withOpacity(0.15),
                      borderColor: Colors.blueAccent,
                      borderStrokeWidth: 2,
                    ),
                  ],
                ),
            ],
          ),
          
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isMocking ? Icons.gps_fixed : Icons.add, 
                  color: _isMocking ? Colors.green.withOpacity(0.5) : Colors.redAccent, 
                  size: 30.0
                ),
              ],
            ),
          ),

          // MEJORA 3: Botón flotante para la ubicación real (se oculta si estás inyectando)
          if (!_isMocking)
            Positioned(
              right: 16,
              bottom: 350, // Lo situamos justo por encima del panel de control
              child: FloatingActionButton(
                heroTag: 'realLocationBtn',
                onPressed: _goToRealLocation,
                backgroundColor: Colors.white,
                foregroundColor: Colors.blueAccent,
                child: const Icon(Icons.my_location),
              ),
            ),

          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.only(left: 12, right: 12, bottom: 20),
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20.0),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 20.0, offset: const Offset(0, 10))],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: 'Buscar empresa, polígono...',
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, size: 20),
                            filled: true,
                            fillColor: Colors.grey[100],
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                          ),
                          onSubmitted: (_) => _performSearch(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        style: IconButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
                        icon: _isLoadingSearch ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.send),
                        onPressed: _performSearch,
                      ),
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
                          IconButton(
                            icon: const Icon(Icons.copy, color: Colors.blueGrey),
                            onPressed: _copyCoordinates,
                            tooltip: 'Copiar Coordenadas',
                          ),
                          IconButton(
                            icon: const Icon(Icons.bookmark_add, color: Colors.blueAccent),
                            onPressed: _showSaveFavoriteDialog, 
                            tooltip: 'Guardar Inspección',
                          ),
                        ],
                      )
                    ],
                  ),
                  
                  // CONTROLES INDEPENDIENTES DE DECIMALES (Petición del usuario)
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Text('Latitud:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                      Expanded(
                        child: Slider(
                          value: _selectedDecimalsLat.toDouble(),
                          min: 1, max: 7, divisions: 6,
                          activeColor: Colors.blueAccent,
                          label: '$_selectedDecimalsLat dec.',
                          onChanged: _isMocking ? null : (double value) {
                            setState(() => _selectedDecimalsLat = value.toInt());
                          },
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('Longitud:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                      Expanded(
                        child: Slider(
                          value: _selectedDecimalsLng.toDouble(),
                          min: 1, max: 7, divisions: 6,
                          activeColor: Colors.teal,
                          label: '$_selectedDecimalsLng dec.',
                          onChanged: _isMocking ? null : (double value) {
                            setState(() => _selectedDecimalsLng = value.toInt());
                          },
                        ),
                      ),
                    ],
                  ),
                  
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            if (_isMocking)
                              FadeTransition(
                                opacity: _blinkController,
                                child: const Icon(Icons.circle, color: Colors.redAccent, size: 10),
                              ),
                            if (_isMocking) const SizedBox(width: 6),
                            Text(_isMocking ? 'INYECCIÓN ACTIVA' : '📡 Señal:', style: TextStyle(fontSize: 12, color: _isMocking ? Colors.redAccent : Colors.grey, fontWeight: _isMocking ? FontWeight.bold : FontWeight.normal)),
                          ],
                        ),
                        Text('GPS + WiFi (Error: $errorText)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87)),
                      ],
                    ),
                  ),

                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isMocking ? Colors.redAccent : Colors.green[600],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: Icon(_isMocking ? Icons.stop_circle : Icons.cell_tower, size: 24),
                    label: Text(
                      _isMocking ? 'DETENER SIMULACIÓN' : 'INICIAR INYECCIÓN',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
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
