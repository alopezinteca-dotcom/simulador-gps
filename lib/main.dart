import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
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
          seedColor: const Color(0xFF1E293B), // Tono oscuro técnico (Slate)
          primary: const Color(0xFF2563EB), // Azul eléctrico corporativo
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

/// MÓDULO 3: Buscador Avanzado (Photon API con Lista de Resultados y foco en España)
class GeocodingService {
  Future<List<Map<String, dynamic>>> searchAddress(String query) async {
    if (query.isEmpty) return [];
    
    // Mejora PRO: lang=es, limit=5, y bias geográfico en Málaga (36.72, -4.42)
    final Uri url = Uri.parse('https://photon.komoot.io/api/?q=$query&limit=5&lang=es&lat=36.72&lon=-4.42');
    
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        final List<dynamic> features = data['features'];
        
        List<Map<String, dynamic>> results = [];
        for (var f in features) {
          final coords = f['geometry']['coordinates'];
          final props = f['properties'];
          
          String name = props['name'] ?? '';
          String street = props['street'] ?? '';
          String city = props['city'] ?? '';
          
          String displayName = name;
          if (street.isNotEmpty && name != street) displayName += ' - $street';
          if (city.isNotEmpty) displayName += ', $city';
          if (displayName.isEmpty) displayName = 'Ubicación desconocida';

          results.add({
            'name': displayName,
            'lat': double.parse(coords[1].toString()),
            'lng': double.parse(coords[0].toString()),
          });
        }
        return results;
      }
    } catch (e) {
      debugPrint("Error búsqueda: $e");
    }
    return [];
  }
}

/// MÓDULO 4: Matemáticas PRO (Ruido Gaussiano y Fijación de Variables)
class CoordinateFormatter {
  static final Random _random = Random();

  // Algoritmo de Box-Muller para generar una campana de Gauss (Nivel PRO)
  static double _nextGaussian() {
    double u = 0, v = 0;
    while (u == 0) u = _random.nextDouble(); 
    while (v == 0) v = _random.nextDouble();
    return sqrt(-2.0 * log(u)) * cos(2.0 * pi * v);
  }

  static double generateInjectedCoordinate(double value, int decimals) {
    if (decimals >= 7) return value; // Máxima precisión, sin ruido

    final double factor = pow(10, decimals).toDouble();
    final double roundedValue = (value * factor).round() / factor;

    // Lógica PRO sugerida: distribución Gaussiana dividida por 3 para simular chip GPS
    final double precisionLimit = pow(10, -decimals).toDouble();
    final double noise = _nextGaussian() * (precisionLimit / 3);

    return roundedValue + noise;
  }
}

/// MÓDULO 5: Pantalla Principal (Control de Misión)
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final LocationService _locationService = LocationService();
  final GeocodingService _geocodingService = GeocodingService();
  final TextEditingController _searchController = TextEditingController();

  LatLng _mapCenter = const LatLng(36.7213, -4.4214);
  
  // SOLUCIÓN AL BUG 1: Variables fijas para la inyección
  double? _injectedLat;
  double? _injectedLng;
  
  bool _isMocking = false;
  bool _isLoadingSearch = false;
  int _selectedDecimals = 7; 
  
  // Sistema de Favoritos (Memoria de sesión)
  final List<Map<String, dynamic>> _favorites = [];

  @override
  void initState() {
    super.initState();
    _requestModernPermissions();
  }

  // SOLUCIÓN AL PUNTO 5: Permisos modernos
  Future<void> _requestModernPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.locationWhenInUse,
      Permission.locationAlways,
    ].request();
    
    if (statuses[Permission.locationWhenInUse]?.isDenied == true) {
      debugPrint("Permiso denegado");
    }
  }

  void _onMapPositionChanged(MapPosition position, bool hasGesture) {
    if (position.center != null && !_isMocking) {
      setState(() {
        _mapCenter = position.center!;
      });
    }
  }

  // SOLUCIÓN AL PUNTO 2: Lista de resultados del buscador
  Future<void> _performSearch() async {
    final String query = _searchController.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();

    setState(() => _isLoadingSearch = true);
    final List<Map<String, dynamic>> results = await _geocodingService.searchAddress(query);
    setState(() => _isLoadingSearch = false);

    if (results.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No se encontró nada.')));
      }
      return;
    }

    if (results.length == 1) {
      _goToLocation(LatLng(results[0]['lat'], results[0]['lng']));
    } else {
      // Muestra una lista elegante para elegir la empresa correcta
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
                  leading: const Icon(Icons.business, color: Colors.blue),
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
  }

  void _saveFavorite() {
    setState(() {
      _favorites.add({
        'name': 'Punto ${_favorites.length + 1} (${_mapCenter.latitude.toStringAsFixed(4)})',
        'lat': _mapCenter.latitude,
        'lng': _mapCenter.longitude,
      });
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ubicación guardada en sesión')));
  }

  void _showFavorites() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        if (_favorites.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24.0),
            child: Text('No hay ubicaciones guardadas.', textAlign: TextAlign.center),
          );
        }
        return ListView.builder(
          itemCount: _favorites.length,
          itemBuilder: (context, index) {
            return ListTile(
              leading: const Icon(Icons.star, color: Colors.amber),
              title: Text(_favorites[index]['name']),
              onTap: () {
                Navigator.pop(context);
                _goToLocation(LatLng(_favorites[index]['lat'], _favorites[index]['lng']));
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

      // 1. Calculamos y FIJAMOS la coordenada inyectada (Solución Bug Fuzzing doble)
      final double finalLat = CoordinateFormatter.generateInjectedCoordinate(_mapCenter.latitude, _selectedDecimals);
      final double finalLng = CoordinateFormatter.generateInjectedCoordinate(_mapCenter.longitude, _selectedDecimals);

      // 2. Enviamos al canal nativo
      final String result = await _locationService.startMocking(finalLat, finalLng);
      
      if (result == "SUCCESS") {
        setState(() {
          _isMocking = true;
          _injectedLat = finalLat;
          _injectedLng = finalLng;
        });
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ Error al inyectar o permiso denegado en Ajustes.')));
        }
      }
    }
  }

  // Traductor de Precisión Visual
  double _getRadiusMeters() {
    if (_selectedDecimals == 7) return 0.0;
    if (_selectedDecimals == 6) return 0.11;
    if (_selectedDecimals == 5) return 1.1;
    if (_selectedDecimals == 4) return 11.0;
    if (_selectedDecimals == 3) return 110.0;
    if (_selectedDecimals == 2) return 1100.0;
    return 11000.0;
  }

  @override
  Widget build(BuildContext context) {
    // Si estamos simulando, mostramos la coordenada fija inyectada. Si no, el centro del mapa vivo.
    final double displayLat = _isMocking ? _injectedLat! : _mapCenter.latitude;
    final double displayLng = _isMocking ? _injectedLng! : _mapCenter.longitude;

    final double radiusMeters = _getRadiusMeters();
    final String errorText = radiusMeters == 0.0 ? "Exacto (± 0.0m)" : "± ${radiusMeters.toStringAsFixed(1)} m";

    return Scaffold(
      extendBodyBehindAppBar: true, 
      appBar: AppBar(
        title: const Text('Inspección Pro v2', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18)),
        backgroundColor: Colors.black87, 
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.star, color: Colors.amber),
            tooltip: 'Favoritos',
            onPressed: _showFavorites,
          ),
        ],
      ),
      body: Stack(
        children: [
          // 1. MAPA CARTODB VOYAGER (Premium visualmente)
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _mapCenter,
              initialZoom: 16.0,
              onPositionChanged: _onMapPositionChanged, 
            ),
            children: [
              TileLayer(
                // Estilo profesional de mapa (CartoDB)
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.mockgps',
              ),
              // SOLUCIÓN AL PUNTO 3: Círculo de Precisión Real
              if (radiusMeters > 0)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: _mapCenter,
                      radius: radiusMeters,
                      useRadiusInMeter: true,
                      color: Colors.blue.withOpacity(0.15),
                      borderColor: Colors.blueAccent,
                      borderStrokeWidth: 2,
                    ),
                  ],
                ),
            ],
          ),
          
          // 2. DIANA FIJA
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.add, color: Colors.redAccent, size: 30.0),
              ],
            ),
          ),

          // 3. HUD DE CONTROL TÉCNICO
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
                  // Buscador PRO
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
                  const Divider(height: 24),
                  
                  // Coordenadas fijadas y Favoritos
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('LAT: ${displayLat.toStringAsFixed(6)}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                          Text('LNG: ${displayLng.toStringAsFixed(6)}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.bookmark_add, color: Colors.blueGrey),
                        onPressed: _saveFavorite,
                        tooltip: 'Guardar Punto',
                      )
                    ],
                  ),
                  
                  // SOLUCIÓN AL PUNTO 9: Calidad de Señal
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('📡 Señal:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        Text('GPS + WiFi (Error: $errorText)', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87)),
                      ],
                    ),
                  ),

                  // Slider de Precisión (Doble Info)
                  Row(
                    children: [
                      const Icon(Icons.blur_circular, size: 20, color: Colors.blueGrey),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: _selectedDecimals.toDouble(),
                          min: 1, max: 7, divisions: 6,
                          activeColor: Colors.blueAccent,
                          label: '$_selectedDecimals dec.',
                          onChanged: _isMocking ? null : (double value) {
                            setState(() => _selectedDecimals = value.toInt());
                          },
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 8),
                  
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isMocking ? Colors.redAccent : Colors.green[600],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: Icon(_isMocking ? Icons.stop_circle : Icons.cell_tower, size: 24),
                    label: Text(
                      _isMocking ? 'DETENER SIMULACIÓN' : 'INICIAR INYECCIÓN',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
